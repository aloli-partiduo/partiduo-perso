# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Ui
    # `/ext/PERSO/accounts` : les comptes du foyer visibles (D5) — nature,
    # établissement, titulaires, solde de la Comptabilité, valeur au
    # patrimoine.
    class AccountsHandler < Handler
      def get
        columns = [
          Table::Column.new("label", I18n.t("perso_ui.accounts.label")),
          Table::Column.new("nature", I18n.t("perso_ui.accounts.nature")),
          Table::Column.new("institution", I18n.t("perso_ui.accounts.institution"), secondary: true),
          Table::Column.new("holders", I18n.t("perso_ui.accounts.holders"), secondary: true),
          Table::Column.new("balance", I18n.t("perso_ui.accounts.balance"), "number"),
          Table::Column.new("value", I18n.t("perso_ui.accounts.value"), "number"),
        ]
        rows = accounts.map do |view|
          label = view.closed ? I18n.t("perso_ui.accounts.closed_label", label: view.label) : view.label
          Table::Row.new([
            Table::Cell.new(label, Ui.url("account", id: view.id)),
            Table::Cell.new(I18n.t(view.nature_key)),
            Table::Cell.new(view.institution),
            Table::Cell.new(Present.holders(view)),
            Present.money(fmt, view.balance),
            Present.money(fmt, view.value),
          ])
        end
        table = Table.new(I18n.t("perso.menu.perso_accounts"), columns, rows, Ui.url("accounts"),
          empty_message: I18n.t("perso_ui.accounts.none"), id: "perso-accounts")
        actions = [] of Screen::Action
        actions << link_action("perso_ui.accounts.new", Ui.url("account_new"), "primary", "plus") if can_admin?
        actions << link_action("perso_ui.accounts.export", Ui.url("export", kind: "accounts"), "", "download")
        list_page(I18n.t("perso.menu.perso_accounts"), table, crumbs({I18n.t("perso.menu.perso_accounts"), nil}),
          "perso_ui.accounts.csv_name", actions, intro: I18n.t("perso_ui.accounts.intro"))
      end
    end

    abstract class AccountScreen < Handler
      FIELDS = %w[nature label institution asset_kind rate ceiling opened_on holder_ids ledger_id opening_balance position closed]

      def member_choices : Array(Form::Option)
        Api.members(actor).map { |member| option(member.id.to_s, member.display_name) }
      end

      def account_form(values : Hash(String, String), creating : Bool) : Form
        value = ->(name : String) { values[name]? || "" }
        fields = [] of Form::Field
        if creating
          fields << Form::Field.new("nature", I18n.t("perso_ui.accounts.nature"), "select", value.call("nature").presence || "current",
            options: code_options(Api::NATURES, "perso.natures"), required: true)
        end
        fields << Form::Field.new("label", I18n.t("perso_ui.accounts.label"), value: value.call("label"), required: true, maxlength: 120)
        fields << Form::Field.new("institution", I18n.t("perso_ui.accounts.institution"), value: value.call("institution"), maxlength: 120)
        fields << Form::Field.new("asset_kind", I18n.t("perso_ui.accounts.asset_kind"), "select", value.call("asset_kind"),
          options: [blank_option] + code_options(Api::ASSET_KINDS, "perso.asset_kinds"), help: I18n.t("perso_ui.accounts.asset_kind_help"))
        fields << Form::Field.new("rate", I18n.t("perso_ui.accounts.rate"), "number", value.call("rate"), mono: true,
          help: I18n.t("perso_ui.accounts.rate_help"))
        fields << Form::Field.new("ceiling", I18n.t("perso_ui.accounts.ceiling"), "number", value.call("ceiling"), mono: true)
        fields << Form::Field.new("opened_on", I18n.t("perso_ui.accounts.opened_on"), "date", value.call("opened_on"))
        fields << Form::Field.new("holder_ids", I18n.t("perso_ui.accounts.holder"), "select", value.call("holder_ids"),
          options: [option("", I18n.t("perso.labels.household"))] + member_choices, help: I18n.t("perso_ui.accounts.holder_help"))
        fields << Form::Field.new("position", I18n.t("perso_ui.accounts.position"), "number", value.call("position").presence || "100", mono: true)
        if creating
          ledgers = Api.available_ledgers(actor).map { |ledger| option(ledger.id.to_s, "#{ledger.code} · #{ledger.name}") }
          fields << Form::Field.new("ledger_id", I18n.t("perso_ui.accounts.ledger"), "select", value.call("ledger_id"),
            options: [blank_option("perso_ui.accounts.new_ledger")] + ledgers, help: I18n.t("perso_ui.accounts.ledger_help"))
          fields << Form::Field.new("opening_balance", I18n.t("perso_ui.accounts.opening_balance"), "number",
            value.call("opening_balance"), mono: true, help: I18n.t("perso_ui.accounts.opening_balance_help"))
        else
          fields << Form::Field.new("closed", I18n.t("perso_ui.accounts.closed"), "checkbox", value.call("closed"))
        end
        Form.new([Form::Group.new(nil, fields)])
      end

      # Titulaire choisi (un membre), ou aucun : le foyer.
      def holder_list : Array(Int64)
        id_field("holder_ids").try { |id| [id] } || [] of Int64
      end
    end

    class AccountNewHandler < AccountScreen
      def get
        show(account_form({"nature" => query("nature").presence || "current"}, true))
      end

      def post
        form = account_form(submitted(FIELDS), true)
        rate = decimal_value(form, "rate")
        ceiling = decimal_value(form, "ceiling")
        opening = decimal_value(form, "opening_balance")
        opened = date_value(form, "opened_on")
        position = int_value(form, "position") || 100
        unless form.invalid
          input = Api::AccountInput.new(nature: field("nature"), label: field("label"), institution: field("institution"),
            asset_kind: field("asset_kind"), rate: rate, ceiling: ceiling, opened_on: opened, holder_ids: holder_list,
            ledger_id: id_field("ledger_id"), opening_balance: opening, position: position)
          result = Api.create_account(actor, input)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.account_created", label: result.value!.label)
            return go(Ui.url("account", id: result.value!.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("perso_ui.accounts.new")
        form_page(title, crumbs({I18n.t("perso.menu.perso_accounts"), Ui.url("accounts")}, {title, nil}), form,
          Ui.url("account_new"), I18n.t("ui.forms.create"), Ui.url("accounts"), intro: I18n.t("perso_ui.accounts.form_intro"))
      end
    end

    class AccountEditHandler < AccountScreen
      def get
        view = Api.account(actor, id_param)
        values = {"label" => view.label, "institution" => view.institution, "asset_kind" => view.asset_kind,
                  "rate" => view.rate.try { |rate| fmt.input_number(rate) } || "",
                  "ceiling" => view.ceiling.try { |ceiling| fmt.input_number(ceiling) } || "",
                  "opened_on" => view.opened_on.try(&.to_s("%F")) || "", "holder_ids" => view.holders.first?.try(&.id.to_s) || "",
                  "position" => view.position.to_s, "closed" => view.closed ? "1" : ""}
        show(view, account_form(values, false))
      end

      def post
        view = Api.account(actor, id_param)
        form = account_form(submitted(FIELDS), false)
        rate = decimal_value(form, "rate")
        ceiling = decimal_value(form, "ceiling")
        opened = date_value(form, "opened_on")
        position = int_value(form, "position") || 100
        unless form.invalid
          input = Api::AccountUpdateInput.new(label: field("label"), institution: field("institution"),
            asset_kind: field("asset_kind"), rate: rate, ceiling: ceiling, opened_on: opened, holder_ids: holder_list,
            closed: checkbox("closed"), position: position)
          result = Api.update_account(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.saved")
            return go(Ui.url("account", id: view.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::AccountView, form : Form) : Marten::HTTP::Response
        title = I18n.t("perso_ui.accounts.edit")
        form_page(title, crumbs({I18n.t("perso.menu.perso_accounts"), Ui.url("accounts")},
          {view.label, Ui.url("account", id: view.id)}, {title, nil}), form, Ui.url("account_edit", id: view.id),
          I18n.t("ui.forms.save"), Ui.url("account", id: view.id))
      end
    end

    # Fiche d'un compte : solde et valeur, opérations des douze derniers
    # mois, valorisations (placement, bien) avec leur saisie, emprunt et
    # tableau d'amortissement (dette).
    class AccountHandler < Handler
      LINES = 5

      def get
        view = Api.account(actor, id_param)
        render_account(view, valuation_form(view, {"valued_on" => Partiduo::Api::Core.today.to_s("%F")}))
      end

      def valuation_form(view : Api::AccountView, values : Hash(String, String)) : Form?
        return unless view.valued? && can_budget? && view.writable
        value = ->(name : String) { values[name]? || "" }
        fields = [
          Form::Field.new("valued_on", I18n.t("perso_ui.valuations.date"), "date", value.call("valued_on"), required: true),
          Form::Field.new("amount", I18n.t("perso_ui.valuations.amount"), "number", value.call("amount"), mono: true,
            help: I18n.t("perso_ui.valuations.amount_help")),
          Form::Field.new("note", I18n.t("perso_ui.valuations.note"), value: value.call("note"), maxlength: 255),
        ]
        groups = [Form::Group.new(nil, fields)]
        if Api::SECURITIES_NATURES.includes?(view.nature)
          lines = (1..LINES).flat_map do |index|
            [Form::Field.new("security_#{index}", I18n.t("perso_ui.valuations.security", index: index), value: value.call("security_#{index}"), maxlength: 120),
             Form::Field.new("quantity_#{index}", I18n.t("perso_ui.valuations.quantity"), "number", value.call("quantity_#{index}"), mono: true),
             Form::Field.new("price_#{index}", I18n.t("perso_ui.valuations.price"), "number", value.call("price_#{index}"), mono: true)]
          end
          groups << Form::Group.new(I18n.t("perso_ui.valuations.lines"), lines)
        end
        Form.new(groups)
      end

      def render_account(view : Api::AccountView, form : Form?, status : Int32 = 200) : Marten::HTTP::Response
        today = Partiduo::Api::Core.today
        facts = facts_of(view)
        sections = [Screen::Section.new(I18n.t("perso_ui.accounts.facts"), facts)]
        operations = Api.operations(actor, Api::OperationQuery.new(account_id: view.id,
          date_from: Ui.add_months(Time.utc(today.year, today.month, 1), -11), limit: 200))
        table = Table.new(I18n.t("perso_ui.accounts.operations"), [
          Table::Column.new("date", I18n.t("perso_ui.operations.date"), "mono"),
          Table::Column.new("payee", I18n.t("perso_ui.operations.payee")),
          Table::Column.new("category", I18n.t("perso_ui.operations.category")),
          Table::Column.new("amount", I18n.t("perso_ui.operations.amount"), "number"),
        ], operations.map do |operation|
          Table::Row.new([Present.date(fmt, operation.date), Table::Cell.new(operation.payee, Ui.url("operation", id: operation.entry_id)),
                          Table::Cell.new(operation.category_label), Present.money(fmt, operation.amount)])
        end, Ui.url("account", id: view.id), empty_message: I18n.t("perso_ui.operations.none"), id: "perso-account-operations")
        table.exportable = false
        sections << Screen::Section.new(I18n.t("perso_ui.accounts.operations"), table: table)
        sections.concat(valuation_sections(view)) if view.valued?
        sections.concat(loan_sections(view)) if view.debt?
        actions = account_actions(view)
        set_form(form, Ui.url("valuation_add", id: view.id), I18n.t("perso_ui.valuations.add"), title: I18n.t("perso_ui.valuations.add")) if form
        show_detail(view.label, crumbs({I18n.t("perso.menu.perso_accounts"), Ui.url("accounts")}, {view.label, nil}), sections,
          actions, status_tag: view.closed ? I18n.t("perso_ui.accounts.closed") : nil, status: status)
      end

      private def account_actions(view : Api::AccountView) : Array(Screen::Action)
        actions = [] of Screen::Action
        if view.writable && can_write? && !view.closed
          actions << link_action("perso_ui.operations.new", Ui.url_with("operation_new", {"account" => view.id.to_s}), "primary", "plus")
        end
        actions << link_action("perso_ui.accounts.edit", Ui.url("account_edit", id: view.id), "", "pencil") if can_admin?
        if view.debt? && view.loan_id.nil? && can_admin?
          actions << link_action("perso_ui.loans.new", Ui.url("loan_new", id: view.id), "", "calendar")
        end
        actions
      end

      private def facts_of(view : Api::AccountView) : Array(Screen::Item)
        [
          Screen::Item.new(I18n.t("perso_ui.accounts.nature"), I18n.t(view.nature_key)),
          Screen::Item.new(I18n.t("perso_ui.accounts.asset_kind"), view.asset_kind.empty? ? "" : I18n.t("perso.asset_kinds.#{view.asset_kind}")),
          Screen::Item.new(I18n.t("perso_ui.accounts.institution"), view.institution),
          Screen::Item.new(I18n.t("perso_ui.accounts.holders"), Present.holders(view)),
          Screen::Item.new(I18n.t("perso_ui.accounts.balance"), fmt.amount(view.balance), mono: true),
          Screen::Item.new(I18n.t("perso_ui.accounts.value"), fmt.amount(view.value), mono: true),
          Screen::Item.new(I18n.t("perso_ui.accounts.rate"), Present.percent(fmt, view.rate)),
          Screen::Item.new(I18n.t("perso_ui.accounts.ceiling"), view.ceiling.try { |ceiling| fmt.amount(ceiling) } || ""),
          Screen::Item.new(I18n.t("perso_ui.accounts.opened_on"), fmt.date(view.opened_on)),
        ]
      end

      private def valuation_sections(view : Api::AccountView) : Array(Screen::Section)
        holding = Api.holding(actor, view.id)
        items = [
          Screen::Item.new(I18n.t("perso_ui.valuations.contributions"), fmt.amount(holding.contributions), mono: true),
          Screen::Item.new(I18n.t("perso_ui.valuations.latest"), holding.latest.try { |latest| "#{fmt.amount(latest.amount)} (#{fmt.date(latest.valued_on)})" } || ""),
          Screen::Item.new(I18n.t("perso_ui.valuations.gain"), holding.latent_gain.try { |gain| fmt.amount(gain) } || "", mono: true),
        ]
        table = Table.new(I18n.t("perso_ui.valuations.history"), [
          Table::Column.new("date", I18n.t("perso_ui.valuations.date"), "mono"),
          Table::Column.new("amount", I18n.t("perso_ui.valuations.amount"), "number"),
          Table::Column.new("detail", I18n.t("perso_ui.valuations.detail")),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], holding.valuations.map do |valuation|
          detail = valuation.lines.map { |line| "#{line.security} : #{fmt.number(line.quantity)} × #{fmt.number(line.price)}" }.join(" ; ")
          actions = can_budget? ? [post_action("perso_ui.valuations.delete", Ui.url("valuation_delete", id: valuation.id), "perso_ui.valuations.confirm_delete", "row-danger", "trash-2")] : [] of Screen::Action
          Table::Row.new([Present.date(fmt, valuation.valued_on), Present.money(fmt, valuation.amount),
                          Table::Cell.new([detail, valuation.note].reject(&.empty?).join(" — ")), Table::Cell.new("", actions: actions)])
        end, Ui.url("account", id: view.id), empty_message: I18n.t("perso_ui.valuations.none"), id: "perso-valuations")
        table.exportable = false
        [Screen::Section.new(I18n.t("perso_ui.valuations.title"), items, table: table, note: I18n.t("perso_ui.valuations.note_help"))]
      end

      private def loan_sections(view : Api::AccountView) : Array(Screen::Section)
        loan_id = view.loan_id || return [] of Screen::Section
        loan = Api.loan(actor, loan_id)
        current = loan.current
        items = [
          Screen::Item.new(I18n.t("perso_ui.loans.payment_account"), loan.payment_account_label, Ui.url("account", id: loan.payment_account_id)),
          Screen::Item.new(I18n.t("perso_ui.loans.principal"), fmt.amount(current.initial_principal), mono: true),
          Screen::Item.new(I18n.t("perso_ui.loans.rate"), Present.percent(fmt, current.annual_rate)),
          Screen::Item.new(I18n.t("perso_ui.loans.remaining"), fmt.amount(loan.remaining), mono: true),
          Screen::Item.new(I18n.t("perso_ui.loans.total_interest"), fmt.amount(loan.total_interest), mono: true),
          Screen::Item.new(I18n.t("perso_ui.loans.total_insurance"), fmt.amount(loan.total_insurance), mono: true),
          Screen::Item.new(I18n.t("perso_ui.loans.version"), "#{current.number} — #{I18n.t(current.reason_key)} (#{fmt.date(current.effective_on)})"),
        ]
        rows = loan.rows.map do |row|
          actions = [] of Screen::Action
          if row.status.in?("upcoming", "overdue") && can_write? && view.writable
            actions << post_action("perso_ui.loans.confirm", Ui.url_with("loan_confirm", {"due_on" => row.due_on.to_s("%F")}, id: loan.id),
              "perso_ui.loans.confirm_question", "row", "check")
          end
          Table::Row.new([Table::Cell.new(row.number.to_s), Present.date(fmt, row.due_on), Present.money(fmt, row.capital),
                          Present.money(fmt, row.interest), Present.money(fmt, row.insurance), Present.money(fmt, row.total),
                          Present.money(fmt, row.remaining), Table::Cell.new(I18n.t(row.status_key)), Table::Cell.new("", actions: actions)])
        end
        table = Table.new(I18n.t("perso_ui.loans.table"), [
          Table::Column.new("number", I18n.t("perso_ui.loans.number"), "mono"),
          Table::Column.new("due_on", I18n.t("perso_ui.loans.due_on"), "mono"),
          Table::Column.new("capital", I18n.t("perso_ui.loans.capital"), "number"),
          Table::Column.new("interest", I18n.t("perso_ui.loans.interest"), "number"),
          Table::Column.new("insurance", I18n.t("perso_ui.loans.insurance"), "number", secondary: true),
          Table::Column.new("total", I18n.t("perso_ui.loans.total"), "number"),
          Table::Column.new("remaining", I18n.t("perso_ui.loans.remaining"), "number"),
          Table::Column.new("status", I18n.t("perso_ui.loans.status")),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], rows, Ui.url("account", id: view.id), id: "perso-loan-table")
        versions = Table.new(I18n.t("perso_ui.loans.versions"), [
          Table::Column.new("number", I18n.t("perso_ui.loans.number"), "mono"),
          Table::Column.new("effective_on", I18n.t("perso_ui.loans.effective_on"), "mono"),
          Table::Column.new("reason", I18n.t("perso_ui.loans.reason")),
          Table::Column.new("principal", I18n.t("perso_ui.loans.version_principal"), "number"),
          Table::Column.new("months", I18n.t("perso_ui.loans.months"), "number"),
          Table::Column.new("prepayment", I18n.t("perso_ui.loans.prepayment"), "number"),
        ], loan.versions.map do |version|
          Table::Row.new([Table::Cell.new(version.number.to_s), Present.date(fmt, version.effective_on),
                          Table::Cell.new(I18n.t(version.reason_key)), Present.money(fmt, version.principal),
                          Table::Cell.new(version.months.to_s), Table::Cell.new(version.prepayment.try { |amount| fmt.amount(amount) } || "")])
        end, Ui.url("account", id: view.id), id: "perso-loan-versions")
        versions.exportable = false
        actions = can_admin? ? [link_action("perso_ui.loans.prepay", Ui.url("loan_prepay", id: loan.id), "", "refresh-cw")] : [] of Screen::Action
        [Screen::Section.new(I18n.t("perso_ui.loans.title"), items, actions: actions),
         Screen::Section.new(I18n.t("perso_ui.loans.table"), table: table),
         Screen::Section.new(I18n.t("perso_ui.loans.versions"), table: versions, note: I18n.t("perso_ui.loans.versions_help"))]
      end
    end

    # Saisie d'une valorisation depuis la fiche du compte (D9).
    class ValuationAddHandler < AccountHandler
      def get
        go(Ui.url("account", id: id_param))
      end

      def post
        view = Api.account(actor, id_param)
        names = %w[valued_on amount note] + (1..LINES).flat_map { |index| ["security_#{index}", "quantity_#{index}", "price_#{index}"] }
        form = valuation_form(view, submitted(names)) || raise Partiduo::Api::Forbidden.new(Api::BUDGET)
        date = date_value(form, "valued_on", required: true)
        amount = decimal_value(form, "amount")
        lines = (1..LINES).compact_map do |index|
          security = field("security_#{index}")
          next if security.empty?
          quantity = decimal_value(form, "quantity_#{index}", required: true)
          price = decimal_value(form, "price_#{index}", required: true)
          next unless quantity && price
          Api::ValuationLineInput.new(security, quantity, price)
        end
        if !form.invalid && date
          result = Api.record_valuation(actor, Api::ValuationInput.new(account_id: view.id, valued_on: date, amount: amount,
            lines: lines, note: field("note")))
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.valuation_recorded")
            return go(Ui.url("account", id: view.id))
          end
          form.add_errors(result.errors, fmt)
        end
        render_account(view, form, 422)
      end
    end

    class ValuationDeleteHandler < Handler
      def get
        go(Ui.url("accounts"))
      end

      def post
        holding = Api.holdings(actor).find { |item| item.valuations.any?(&.id.==(id_param)) }
        result = Api.delete_valuation(actor, id_param)
        after(result, "perso_ui.flash.valuation_deleted", holding ? Ui.url("account", id: holding.account.id) : Ui.url("accounts"))
      end
    end
  end
end
