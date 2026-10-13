# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Ui
    # `/ext/PERSO/operations` : les opérations des comptes visibles (D4),
    # filtrées par compte, période, catégorie et texte ; liste exportable.
    class OperationsHandler < Handler
      PERIODS = %w[month previous_month year previous_year last_12_months all]

      def get
        period = PERIODS.includes?(query("period")) ? query("period") : "month"
        from, to = bounds(period)
        account_id = query("account").to_i64?
        category_id = query("category").to_i64?
        views = Api.operations(actor, Api::OperationQuery.new(account_id: account_id, date_from: from, date_to: to,
          category_id: category_id, limit: Api::MAX_LIMIT * 5))
        columns = [
          Table::Column.new("date", I18n.t("perso_ui.operations.date"), "mono"),
          Table::Column.new("account", I18n.t("perso_ui.operations.account"), secondary: true),
          Table::Column.new("payee", I18n.t("perso_ui.operations.payee")),
          Table::Column.new("category", I18n.t("perso_ui.operations.category")),
          Table::Column.new("member", I18n.t("perso_ui.operations.member"), secondary: true),
          Table::Column.new("amount", I18n.t("perso_ui.operations.amount"), "number"),
        ]
        rows = views.map do |view|
          url = Ui.url("operation", id: view.entry_id)
          label = view.versions > 1 ? I18n.t("perso_ui.operations.corrected", payee: view.payee) : view.payee
          Table::Row.new([
            Present.date(fmt, view.date),
            Table::Cell.new(view.account_label),
            Table::Cell.new(label, url),
            Table::Cell.new(view.kind == "transfer" ? I18n.t("perso_ui.operations.transfer_to", label: view.category_label) : view.category_label),
            Table::Cell.new(view.member_name || ""),
            Present.money(fmt, view.amount),
          ])
        end
        total = views.sum(BigDecimal.new(0), &.amount)
        footer = [Table::Row.new([Table::Cell.new(I18n.t("perso_ui.operations.total")), Table::Cell.new(""), Table::Cell.new(""),
                                  Table::Cell.new(""), Table::Cell.new(""), Present.money(fmt, total)])]
        params = {"period" => period}
        params["account"] = account_id.to_s if account_id
        params["category"] = category_id.to_s if category_id
        table = Table.new(I18n.t("perso.menu.perso_operations"), columns, rows, Ui.url("operations"), params: params,
          empty_message: I18n.t("perso_ui.operations.none"), id: "perso-operations", footer_rows: footer)
        actions = [] of Screen::Action
        actions << link_action("perso_ui.operations.new", Ui.url("operation_new"), "primary", "plus") if can_write?
        actions << link_action("perso_ui.operations.export_all", Ui.url("export", kind: "operations"), "", "download")
        list_page(I18n.t("perso.menu.perso_operations"), table, crumbs({I18n.t("perso.menu.perso_operations"), nil}),
          "perso_ui.operations.csv_name", actions, filters: filters(period, account_id, category_id),
          intro: I18n.t("perso_ui.operations.intro"))
      end

      private def filters(period : String, account_id : Int64?, category_id : Int64?) : Form
        fields = [
          Form::Field.new("period", I18n.t("perso_ui.operations.period"), "select", period,
            options: code_options(PERIODS, "perso_ui.periods")),
          Form::Field.new("account", I18n.t("perso_ui.operations.account"), "select", account_id.to_s,
            options: [option("", I18n.t("perso_ui.operations.all_accounts"))] + account_options(writable_only: false)),
          Form::Field.new("category", I18n.t("perso_ui.operations.category"), "select", category_id.to_s,
            options: [option("", I18n.t("perso_ui.operations.all_categories"))] + category_options(blank: false, postable: false)),
        ]
        search_filters(fields)
      end

      private def bounds(period : String) : {Time?, Time?}
        today = Partiduo::Api::Core.today
        month = Time.utc(today.year, today.month, 1)
        case period
        when "previous_month"
          start = Ui.add_months(month, -1)
          {start, Ui.end_of_month(start)}
        when "year"           then {Time.utc(today.year, 1, 1), Time.utc(today.year, 12, 31)}
        when "previous_year"  then {Time.utc(today.year - 1, 1, 1), Time.utc(today.year - 1, 12, 31)}
        when "last_12_months" then {Ui.add_months(month, -11), today}
        when "all"            then {nil, nil}
        else                       {month, Ui.end_of_month(month)}
        end
      end
    end

    # Formulaire d'une opération (création, correction) : compte, sens,
    # date, montant, catégorie ou ventilation sur plusieurs catégories,
    # compte de destination d'un virement, bénéficiaire, membre, note.
    abstract class OperationScreen < Handler
      SPLITS = 4
      FIELDS = %w[account_id kind date amount category_id to_account_id payee member_id note] +
               (1..SPLITS).flat_map { |index| ["split_category_#{index}", "split_amount_#{index}"] }

      def values_of(view : Api::OperationView) : Hash(String, String)
        values = {
          "account_id" => view.account_id.to_s, "kind" => view.kind, "date" => view.date.to_s("%F"),
          "amount" => fmt.input_number(view.amount.abs), "to_account_id" => view.to_account_id.to_s,
          "payee" => view.payee, "member_id" => view.member_id.to_s, "note" => view.note,
        }
        categorized = view.splits.select(&.category_id)
        if categorized.size == 1
          values["category_id"] = categorized.first.category_id.to_s
        elsif categorized.size > 1
          categorized.first(SPLITS).each_with_index(1) do |split, index|
            values["split_category_#{index}"] = split.category_id.to_s
            values["split_amount_#{index}"] = fmt.input_number(split.amount.abs)
          end
        end
        values
      end

      def operation_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        main = [
          Form::Field.new("account_id", I18n.t("perso_ui.operations.account"), "select", value.call("account_id"),
            options: account_options, required: true),
          Form::Field.new("kind", I18n.t("perso_ui.operations.kind"), "select", value.call("kind").presence || "expense",
            options: code_options(Api::OPERATION_KINDS, "perso.operation_kinds"), required: true),
          Form::Field.new("date", I18n.t("perso_ui.operations.date"), "date", value.call("date"), required: true),
          Form::Field.new("amount", I18n.t("perso_ui.operations.amount"), "number", value.call("amount"), required: true,
            mono: true, help: I18n.t("perso_ui.operations.amount_help")),
          Form::Field.new("category_id", I18n.t("perso_ui.operations.category"), "select", value.call("category_id"),
            options: category_options, help: I18n.t("perso_ui.operations.category_help")),
          Form::Field.new("to_account_id", I18n.t("perso_ui.operations.to_account"), "select", value.call("to_account_id"),
            options: account_options(blank: true), help: I18n.t("perso_ui.operations.to_account_help")),
          Form::Field.new("payee", I18n.t("perso_ui.operations.payee"), value: value.call("payee"), maxlength: 120),
          Form::Field.new("member_id", I18n.t("perso_ui.operations.member"), "select", value.call("member_id"),
            options: member_options),
          Form::Field.new("note", I18n.t("perso_ui.operations.note"), "textarea", value.call("note"), wide: true, maxlength: 4000),
        ]
        splits = (1..SPLITS).flat_map do |index|
          [Form::Field.new("split_category_#{index}", I18n.t("perso_ui.operations.split_category", index: index), "select",
            value.call("split_category_#{index}"), options: category_options),
           Form::Field.new("split_amount_#{index}", I18n.t("perso_ui.operations.split_amount", index: index), "number",
             value.call("split_amount_#{index}"), mono: true)]
        end
        Form.new([Form::Group.new(nil, main), Form::Group.new(I18n.t("perso_ui.operations.splits"), splits)])
      end

      # Saisie lue ; `nil` et des erreurs de formulaire si une date ou un
      # montant est illisible.
      def read_input(form : Form) : Api::OperationInput?
        date = date_value(form, "date", required: true)
        amount = decimal_value(form, "amount", required: true)
        splits = (1..SPLITS).compact_map do |index|
          category = id_field("split_category_#{index}") || next
          part = decimal_value(form, "split_amount_#{index}", required: true) || next
          Api::SplitInput.new(category, part)
        end
        account_id = id_field("account_id")
        form.add_error("account_id", I18n.t("ui.forms.required")) if account_id.nil?
        return if form.invalid || date.nil? || amount.nil? || account_id.nil?
        kind = field("kind").presence || "expense"
        Api::OperationInput.new(account_id: account_id, date: date, amount: amount, kind: kind,
          category_id: kind == "transfer" ? nil : id_field("category_id"), splits: kind == "transfer" ? [] of Api::SplitInput : splits,
          to_account_id: kind == "transfer" ? id_field("to_account_id") : nil, payee: field("payee"),
          member_id: id_field("member_id"), note: field("note", strip: false).strip)
      end

      def add_errors(form : Form, errors : Array(Partiduo::Api::FieldError)) : Nil
        errors.each do |error|
          name = error.field
          if match = name.match(/\Asplits\[(\d+)\]\.(category_id|amount)\z/)
            name = match[2] == "amount" ? "split_amount_#{match[1].to_i + 1}" : "split_category_#{match[1].to_i + 1}"
          elsif name == "splits"
            name = "split_amount_1"
          end
          form.fields.any?(&.name.==(name)) ? form.add_error(name, fmt.message(error)) : form.add_error(Partiduo::Api::FieldError::BASE, fmt.message(error))
        end
      end
    end

    class OperationNewHandler < OperationScreen
      def get
        values = {"date" => Partiduo::Api::Core.today.to_s("%F"), "kind" => query("kind").presence || "expense"}
        query("account").presence.try { |id| values["account_id"] = id }
        show(operation_form(values))
      end

      def post
        form = operation_form(submitted(FIELDS))
        if input = read_input(form)
          result = Api.record_operation(actor, input)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.operation_recorded")
            return go(query("next").presence.try { |url| url.starts_with?("/ext/PERSO/") ? url : nil } || Ui.url("operations"))
          end
          add_errors(form, result.errors)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("perso_ui.operations.new")
        form_page(title, crumbs({I18n.t("perso.menu.perso_operations"), Ui.url("operations")}, {title, nil}), form,
          Ui.url("operation_new"), I18n.t("ui.forms.create"), Ui.url("operations"), intro: I18n.t("perso_ui.operations.form_intro"))
      end
    end

    class OperationEditHandler < OperationScreen
      def get
        detail = Api.operation(actor, id_param)
        show(detail.operation, operation_form(values_of(detail.operation)))
      end

      def post
        detail = Api.operation(actor, id_param)
        form = operation_form(submitted(FIELDS))
        if input = read_input(form)
          result = Api.update_operation(actor, id_param, input)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.operation_corrected")
            return go(Ui.url("operation", id: result.value!.entry_id))
          end
          add_errors(form, result.errors)
        end
        show(detail.operation, form)
      end

      private def show(view : Api::OperationView, form : Form) : Marten::HTTP::Response
        title = I18n.t("perso_ui.operations.edit")
        form_page(title, crumbs({I18n.t("perso.menu.perso_operations"), Ui.url("operations")},
          {view.payee, Ui.url("operation", id: view.entry_id)}, {title, nil}), form, Ui.url("operation_edit", id: view.entry_id),
          I18n.t("ui.forms.save"), Ui.url("operation", id: view.entry_id), intro: I18n.t("perso_ui.operations.edit_intro"))
      end
    end

    # Fiche d'une opération : ses parts, ses versions (D11) et ses
    # justificatifs, avec le dépôt d'un justificatif.
    class OperationHandler < Handler
      def get
        detail = Api.operation(actor, id_param)
        view = detail.operation
        facts = [
          Screen::Item.new(I18n.t("perso_ui.operations.date"), fmt.date(view.date)),
          Screen::Item.new(I18n.t("perso_ui.operations.account"), view.account_label, Ui.url("account", id: view.account_id)),
          Screen::Item.new(I18n.t("perso_ui.operations.kind"), I18n.t(view.kind_key)),
          Screen::Item.new(I18n.t("perso_ui.operations.amount"), fmt.amount(view.amount), mono: true),
          Screen::Item.new(I18n.t("perso_ui.operations.payee"), view.payee),
          Screen::Item.new(I18n.t("perso_ui.operations.member"), view.member_name || ""),
          Screen::Item.new(I18n.t("perso_ui.operations.note"), view.note),
          Screen::Item.new(I18n.t("perso_ui.operations.source"), I18n.t("perso.sources.#{view.source}")),
        ]
        split_table = Table.new(I18n.t("perso_ui.operations.parts"), [
          Table::Column.new("label", I18n.t("perso_ui.operations.category")),
          Table::Column.new("amount", I18n.t("perso_ui.operations.amount"), "number"),
        ], view.splits.map { |split| Table::Row.new([Table::Cell.new(split.label), Present.money(fmt, split.amount)]) },
          Ui.url("operation", id: view.entry_id), id: "perso-parts")
        split_table.exportable = false
        versions = Table.new(I18n.t("perso_ui.operations.versions"), [
          Table::Column.new("date", I18n.t("perso_ui.operations.date"), "mono"),
          Table::Column.new("label", I18n.t("perso_ui.operations.payee")),
          Table::Column.new("amount", I18n.t("perso_ui.operations.amount"), "number"),
          Table::Column.new("status", I18n.t("perso_ui.operations.status")),
          Table::Column.new("author", I18n.t("perso_ui.operations.author")),
          Table::Column.new("created", I18n.t("perso_ui.operations.recorded_at"), "mono"),
        ], detail.versions.map do |version|
          Table::Row.new([Present.date(fmt, version.date), Table::Cell.new(version.label), Present.money(fmt, version.amount),
                          Table::Cell.new(I18n.t(version.status_key)), Table::Cell.new(version.created_by_name || ""),
                          Table::Cell.new(fmt.datetime(version.created_at))])
        end, Ui.url("operation", id: view.entry_id), id: "perso-versions")
        versions.exportable = false
        documents = Table.new(I18n.t("perso_ui.documents.title"), [
          Table::Column.new("label", I18n.t("perso_ui.documents.label")),
          Table::Column.new("kind", I18n.t("perso_ui.documents.kind")),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], detail.documents.map do |document|
          actions = can_write? ? [post_action("perso_ui.documents.delete", Ui.url("document_delete", id: document.id), "perso_ui.documents.confirm_delete", "row-danger", "trash-2")] : [] of Screen::Action
          Table::Row.new([Table::Cell.new(document.label.presence || document.filename, Ui.url("document", id: document.id)),
                          Table::Cell.new(I18n.t(document.kind_key)), Table::Cell.new("", actions: actions)])
        end, Ui.url("operation", id: view.entry_id), empty_message: I18n.t("perso_ui.documents.none"), id: "perso-documents")
        documents.exportable = false
        actions = [] of Screen::Action
        if view.writable && can_write?
          actions << link_action("perso_ui.operations.edit", Ui.url("operation_edit", id: view.entry_id), "primary", "pencil")
          actions << post_action("perso_ui.operations.delete", Ui.url("operation_delete", id: view.entry_id),
            "perso_ui.operations.confirm_delete", "danger", "trash-2")
        end
        show_detail(view.payee, crumbs({I18n.t("perso.menu.perso_operations"), Ui.url("operations")}, {view.payee, nil}), [
          Screen::Section.new(I18n.t("perso_ui.operations.facts"), facts),
          Screen::Section.new(I18n.t("perso_ui.operations.parts"), table: split_table),
          Screen::Section.new(I18n.t("perso_ui.operations.versions"), table: versions, note: I18n.t("perso_ui.operations.versions_help")),
          Screen::Section.new(I18n.t("perso_ui.documents.title"), table: documents),
        ], actions, status_tag: view.versions > 1 ? I18n.t("perso_ui.operations.version_count", count: view.versions) : nil,
          upload_url: can_write? ? Ui.url("operation_document", id: view.entry_id) : nil)
      end
    end

    class OperationDeleteHandler < Handler
      def get
        go(Ui.url("operation", id: id_param))
      end

      def post
        result = Api.delete_operation(actor, id_param)
        return after(result, "perso_ui.flash.operation_deleted", Ui.url("operations")) if result.success?
        after(result, "perso_ui.flash.operation_deleted", Ui.url("operation", id: id_param))
      end
    end

    # Dépôt d'un justificatif sur une opération (D4).
    class OperationDocumentHandler < Handler
      TYPES = {"pdf" => "application/pdf", "png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg",
               "webp" => "image/webp", "heic" => "image/heic", "tif" => "image/tiff", "tiff" => "image/tiff",
               "txt" => "text/plain", "csv" => "text/csv", "xml" => "application/xml"}

      def get
        go(Ui.url("operation", id: id_param))
      end

      def post
        upload = request.data.fetch("file", nil).as?(Marten::HTTP::UploadedFile)
        if upload.nil? || upload.size.zero?
          flash["danger"] = I18n.t("perso_ui.documents.file_missing")
          return go(Ui.url("operation", id: id_param))
        end
        filename = upload.filename.presence || "justificatif"
        extension = File.extname(filename).lchop('.').downcase
        content = upload.io.getb_to_end
        result = Api.attach_document(actor, Api::DocumentInput.new(filename: filename,
          content_type: TYPES[extension]? || "application/octet-stream", content: content,
          kind: Api::DOCUMENT_KINDS.includes?(field("kind")) ? field("kind") : "other", label: field("label"), entry_id: id_param))
        after(result, "perso_ui.flash.document_added", Ui.url("operation", id: id_param))
      end
    end

    class DocumentHandler < Handler
      def get
        filename, content_type, content = Api.document_content(actor, id_param)
        response = Marten::HTTP::Response.new(content: String.new(content), content_type: content_type)
        response["Content-Disposition"] = %(attachment; filename="#{filename.gsub('"', "")}")
        response
      end
    end

    class DocumentDeleteHandler < Handler
      def get
        go(Ui.url("operations"))
      end

      def post
        result = Api.delete_document(actor, id_param)
        back = request.headers["Referer"]?.try { |url| URI.parse(url).path }.try { |path| path.starts_with?("/ext/PERSO/") ? path : nil }
        after(result, "perso_ui.flash.document_deleted", back || Ui.url("operations"))
      end
    end

    # Exports complets en CSV (D11) : opérations, comptes, valorisations.
    class ExportHandler < Handler
      def get
        case params["kind"].to_s
        when "operations" then file_response(Api.export_operations(actor))
        when "accounts"   then file_response(Api.export_accounts(actor))
        when "valuations" then file_response(Api.export_valuations(actor))
        else                   raise Partiduo::Api::NotFound.new("perso_export", params["kind"].to_s)
        end
      end
    end
  end
end
