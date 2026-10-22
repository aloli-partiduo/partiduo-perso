# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Ui
    # `/ext/PERSO/schedule` : l'échéancier (D7) — échéances de la période
    # (opérations récurrentes, emprunts), retards signalés, confirmation ou
    # écart d'une échéance, soldes prévisionnels des comptes.
    class ScheduleHandler < Handler
      HORIZONS = %w[30 60 90 180 365]

      def get
        today = Partiduo::Api::Core.today
        horizon = HORIZONS.includes?(query("days")) ? query("days") : "60"
        schedule = Api.schedule(actor, today, today + horizon.to_i.days)
        dues = Table.new(I18n.t("perso_ui.schedule.dues"), [
          Table::Column.new("date", I18n.t("perso_ui.schedule.date"), "mono"),
          Table::Column.new("account", I18n.t("perso_ui.operations.account"), secondary: true),
          Table::Column.new("label", I18n.t("perso_ui.operations.payee")),
          Table::Column.new("category", I18n.t("perso_ui.operations.category"), secondary: true),
          Table::Column.new("amount", I18n.t("perso_ui.operations.amount"), "number"),
          Table::Column.new("status", I18n.t("perso_ui.schedule.status")),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], schedule.dues.map { |due| due_row(due) }, Ui.url("schedule"), params: {"days" => horizon},
          empty_message: I18n.t("perso_ui.schedule.none"), id: "perso-dues")
        balances = Table.new(I18n.t("perso_ui.schedule.balances"), [
          Table::Column.new("account", I18n.t("perso_ui.operations.account")),
          Table::Column.new("balance", I18n.t("perso_ui.schedule.balance"), "number"),
          Table::Column.new("projected", I18n.t("perso_ui.schedule.projected"), "number"),
          Table::Column.new("lowest", I18n.t("perso_ui.schedule.lowest"), "number"),
          Table::Column.new("lowest_on", I18n.t("perso_ui.schedule.lowest_on"), "mono"),
        ], schedule.balances.map do |item|
          Table::Row.new([Table::Cell.new(item.account_label, Ui.url("account", id: item.account_id)), Present.money(fmt, item.balance),
                          Present.money(fmt, item.projected), Present.money(fmt, item.lowest), Present.date(fmt, item.lowest_on)])
        end, Ui.url("schedule"), id: "perso-balances")
        balances.exportable = false
        tabs = HORIZONS.map do |days|
          Screen::Tab.new(I18n.t("perso_ui.schedule.horizon", days: days), Ui.url_with("schedule", {"days" => days}), days == horizon)
        end
        actions = [link_action("perso_ui.recurring.title", Ui.url("recurrings"), "", "refresh-cw")]
        actions.unshift(link_action("perso_ui.recurring.new", Ui.url("recurring_new"), "primary", "plus")) if can_write?
        note = schedule.overdue_count > 0 ? I18n.t("perso_ui.schedule.overdue", count: schedule.overdue_count) : nil
        show_detail(I18n.t("perso.menu.perso_schedule"), crumbs({I18n.t("perso.menu.perso_schedule"), nil}), [
          Screen::Section.new(I18n.t("perso_ui.schedule.dues"), table: dues, note: note),
          Screen::Section.new(I18n.t("perso_ui.schedule.balances"), table: balances, note: I18n.t("perso_ui.schedule.balances_help")),
        ], actions, intro: I18n.t("perso_ui.schedule.intro", days: horizon), tabs: tabs)
      end

      private def due_row(due : Api::DueView) : Table::Row
        actions = [] of Screen::Action
        if can_write?
          if recurring = due.recurring_id
            params = {"recurring_id" => recurring.to_s, "due_on" => due.due_on.to_s("%F")}
            if due.pending?
              actions << post_action("perso_ui.schedule.confirm", Ui.url_with("schedule_confirm", params), "perso_ui.schedule.confirm_question", "row", "check")
              actions << post_action("perso_ui.schedule.skip", Ui.url_with("schedule_skip", params), "perso_ui.schedule.skip_question", "row", "x")
            elsif due.status.in?("skipped", "matched")
              actions << post_action("perso_ui.schedule.reopen", Ui.url_with("schedule_reopen", params), nil, "row", "undo-2")
            end
          elsif (loan = due.loan_id) && due.pending?
            actions << post_action("perso_ui.loans.confirm", Ui.url_with("loan_confirm", {"due_on" => due.due_on.to_s("%F"), "next" => "schedule"}, id: loan),
              "perso_ui.loans.confirm_question", "row", "check")
          end
        end
        label = due.estimated ? I18n.t("perso_ui.schedule.estimated", label: due.label) : due.label
        Table::Row.new([
          Present.date(fmt, due.date), Table::Cell.new(due.account_label), Table::Cell.new(label, due.entry_id.try { |id| Ui.url("operation", id: id) }),
          Table::Cell.new(due.category_label), Present.money(fmt, due.amount), Table::Cell.new(I18n.t(due.status_key)),
          Table::Cell.new("", actions: actions),
        ], css: due.status == "overdue" ? "is-warning" : "")
      end
    end

    abstract class DueCommand < Handler
      def get
        go(Ui.url("schedule"))
      end

      def recurring_id : Int64
        query("recurring_id").to_i64? || raise Partiduo::Api::NotFound.new("perso_recurring", query("recurring_id"))
      end

      def due_on : Time
        fmt.parse_date(query("due_on")) || Time.parse_utc(query("due_on"), "%Y-%m-%d")
      rescue Time::Format::Error | ArgumentError
        raise Partiduo::Api::NotFound.new("perso_due", query("due_on"))
      end
    end

    class ScheduleConfirmHandler < DueCommand
      def post
        result = Api.confirm_due(actor, Api::ConfirmInput.new(recurring_id, due_on))
        after(result, "perso_ui.flash.due_confirmed", Ui.url("schedule"))
      end
    end

    class ScheduleSkipHandler < DueCommand
      def post
        after(Api.skip_due(actor, recurring_id, due_on), "perso_ui.flash.due_skipped", Ui.url("schedule"))
      end
    end

    class ScheduleReopenHandler < DueCommand
      def post
        after(Api.reopen_due(actor, recurring_id, due_on), "perso_ui.flash.due_reopened", Ui.url("schedule"))
      end
    end

    # `/ext/PERSO/recurring` : les opérations récurrentes (D7).
    class RecurringsHandler < Handler
      def get
        rows = Api.recurrings(actor).map do |view|
          actions = [] of Screen::Action
          if can_write?
            actions << link_action("perso_ui.recurring.edit", Ui.url("recurring_edit", id: view.id), "row", "pencil")
            actions << post_action("perso_ui.recurring.delete", Ui.url("recurring_delete", id: view.id), "perso_ui.recurring.confirm_delete", "row-danger", "trash-2")
          end
          frequency = view.frequency == "days" ? I18n.t("perso_ui.recurring.every_days", count: view.interval_days || 1) : I18n.t(view.frequency_key)
          Table::Row.new([
            Table::Cell.new(view.payee), Table::Cell.new(view.account_label),
            Table::Cell.new(view.to_account_label.try { |label| I18n.t("perso_ui.operations.transfer_to", label: label) } || view.category_label || ""),
            Table::Cell.new(frequency), Present.money(fmt, view.kind == "income" ? view.amount : -view.amount),
            Present.date(fmt, view.next_due_on), Table::Cell.new(view.active ? I18n.t("perso_ui.recurring.active") : I18n.t("perso_ui.recurring.inactive")),
            Table::Cell.new("", actions: actions),
          ])
        end
        table = Table.new(I18n.t("perso_ui.recurring.title"), [
          Table::Column.new("payee", I18n.t("perso_ui.operations.payee")),
          Table::Column.new("account", I18n.t("perso_ui.operations.account"), secondary: true),
          Table::Column.new("category", I18n.t("perso_ui.operations.category")),
          Table::Column.new("frequency", I18n.t("perso_ui.recurring.frequency")),
          Table::Column.new("amount", I18n.t("perso_ui.operations.amount"), "number"),
          Table::Column.new("next", I18n.t("perso_ui.recurring.next_due"), "mono"),
          Table::Column.new("state", I18n.t("perso_ui.schedule.status"), secondary: true),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], rows, Ui.url("recurrings"), empty_message: I18n.t("perso_ui.recurring.none"), id: "perso-recurrings")
        actions = can_write? ? [link_action("perso_ui.recurring.new", Ui.url("recurring_new"), "primary", "plus")] : [] of Screen::Action
        list_page(I18n.t("perso_ui.recurring.title"), table, crumbs({I18n.t("perso.menu.perso_schedule"), Ui.url("schedule")},
          {I18n.t("perso_ui.recurring.title"), nil}), "perso_ui.recurring.csv_name", actions, intro: I18n.t("perso_ui.recurring.intro"))
      end
    end

    abstract class RecurringScreen < Handler
      FIELDS = %w[account_id kind payee amount estimated category_id to_account_id frequency interval_days first_on last_on
        business_days member_id active]

      def values_of(view : Api::RecurringView) : Hash(String, String)
        {"account_id" => view.account_id.to_s, "kind" => view.kind, "payee" => view.payee, "amount" => fmt.input_number(view.amount),
         "estimated" => view.estimated ? "1" : "", "category_id" => view.category_id.to_s, "to_account_id" => view.to_account_id.to_s,
         "frequency" => view.frequency, "interval_days" => view.interval_days.to_s, "first_on" => view.first_on.to_s("%F"),
         "last_on" => view.last_on.try(&.to_s("%F")) || "", "business_days" => view.business_days ? "1" : "",
         "member_id" => view.member_id.to_s, "active" => view.active ? "1" : ""}
      end

      def recurring_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        fields = [
          Form::Field.new("account_id", I18n.t("perso_ui.operations.account"), "select", value.call("account_id"), options: account_options, required: true),
          Form::Field.new("kind", I18n.t("perso_ui.operations.kind"), "select", value.call("kind").presence || "expense",
            options: code_options(Api::OPERATION_KINDS, "perso.operation_kinds"), required: true),
          Form::Field.new("payee", I18n.t("perso_ui.operations.payee"), value: value.call("payee"), required: true, maxlength: 120),
          Form::Field.new("amount", I18n.t("perso_ui.operations.amount"), "number", value.call("amount"), required: true, mono: true),
          Form::Field.new("estimated", I18n.t("perso_ui.recurring.estimated"), "checkbox", value.call("estimated")),
          Form::Field.new("category_id", I18n.t("perso_ui.operations.category"), "select", value.call("category_id"), options: category_options),
          Form::Field.new("to_account_id", I18n.t("perso_ui.operations.to_account"), "select", value.call("to_account_id"),
            options: account_options(blank: true)),
          Form::Field.new("frequency", I18n.t("perso_ui.recurring.frequency"), "select", value.call("frequency").presence || "monthly",
            options: code_options(Api::FREQUENCIES, "perso.frequencies"), required: true),
          Form::Field.new("interval_days", I18n.t("perso_ui.recurring.interval_days"), "number", value.call("interval_days"), mono: true,
            help: I18n.t("perso_ui.recurring.interval_help")),
          Form::Field.new("first_on", I18n.t("perso_ui.recurring.first_on"), "date", value.call("first_on"), required: true),
          Form::Field.new("last_on", I18n.t("perso_ui.recurring.last_on"), "date", value.call("last_on")),
          Form::Field.new("business_days", I18n.t("perso_ui.recurring.business_days"), "checkbox", value.call("business_days")),
          Form::Field.new("member_id", I18n.t("perso_ui.operations.member"), "select", value.call("member_id"), options: member_options),
          Form::Field.new("active", I18n.t("perso_ui.recurring.active"), "checkbox", value.call("active")),
        ]
        Form.new([Form::Group.new(nil, fields)])
      end

      def read_input(form : Form) : Api::RecurringInput?
        amount = decimal_value(form, "amount", required: true)
        first = date_value(form, "first_on", required: true)
        last = date_value(form, "last_on")
        interval = int_value(form, "interval_days")
        account_id = id_field("account_id")
        form.add_error("account_id", I18n.t("ui.forms.required")) if account_id.nil?
        return if form.invalid || amount.nil? || first.nil? || account_id.nil?
        kind = field("kind").presence || "expense"
        Api::RecurringInput.new(account_id: account_id, payee: field("payee"), amount: amount, first_on: first, kind: kind,
          category_id: kind == "transfer" ? nil : id_field("category_id"), to_account_id: kind == "transfer" ? id_field("to_account_id") : nil,
          estimated: checkbox("estimated"), frequency: field("frequency").presence || "monthly", interval_days: interval,
          last_on: last, business_days: checkbox("business_days"), member_id: id_field("member_id"), active: checkbox("active"))
      end
    end

    class RecurringNewHandler < RecurringScreen
      def get
        show(recurring_form({"first_on" => Partiduo::Api::Core.today.to_s("%F"), "active" => "1"}))
      end

      def post
        form = recurring_form(submitted(FIELDS))
        if input = read_input(form)
          result = Api.save_recurring(actor, input)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.recurring_saved")
            return go(Ui.url("recurrings"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("perso_ui.recurring.new")
        form_page(title, crumbs({I18n.t("perso_ui.recurring.title"), Ui.url("recurrings")}, {title, nil}), form,
          Ui.url("recurring_new"), I18n.t("ui.forms.create"), Ui.url("recurrings"))
      end
    end

    class RecurringEditHandler < RecurringScreen
      def get
        show(recurring_form(values_of(Api.recurring(actor, id_param))))
      end

      def post
        form = recurring_form(submitted(FIELDS))
        if input = read_input(form)
          result = Api.save_recurring(actor, input, id_param)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.recurring_saved")
            return go(Ui.url("recurrings"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("perso_ui.recurring.edit")
        form_page(title, crumbs({I18n.t("perso_ui.recurring.title"), Ui.url("recurrings")}, {title, nil}), form,
          Ui.url("recurring_edit", id: id_param), I18n.t("ui.forms.save"), Ui.url("recurrings"))
      end
    end

    class RecurringDeleteHandler < Handler
      def get
        go(Ui.url("recurrings"))
      end

      def post
        after(Api.delete_recurring(actor, id_param), "perso_ui.flash.recurring_deleted", Ui.url("recurrings"))
      end
    end

    # Emprunt d'un compte de dette (D5) : conditions, puis tableau.
    class LoanNewHandler < Handler
      FIELDS = %w[payment_account_id principal annual_rate months first_due_on deferral_kind deferral_months insurance_mode
        insurance_value interest_category_id insurance_category_id]

      def get
        view = Api.account(actor, id_param)
        show(view, loan_form({"deferral_kind" => "none", "insurance_mode" => "none", "deferral_months" => "0", "insurance_value" => "0"}))
      end

      def post
        view = Api.account(actor, id_param)
        form = loan_form(submitted(FIELDS))
        if input = read_input(form, view.id)
          result = Api.create_loan(actor, input)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.loan_created")
            return go(Ui.url("account", id: view.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      # Conditions lues ; `nil` et des erreurs de formulaire si un montant,
      # une durée ou une date est illisible.
      private def read_input(form : Form, account_id : Int64) : Api::LoanInput?
        terms = read_terms(form)
        links = read_links(form)
        return if form.invalid
        terms.try do |(principal, rate, months, first)|
          links.try do |(payment, interest)|
            Api::LoanInput.new(account_id: account_id, payment_account_id: payment, principal: principal, annual_rate: rate,
              months: months, first_due_on: first, interest_category_id: interest, insurance_category_id: id_field("insurance_category_id"),
              deferral_months: int_value(form, "deferral_months") || 0, deferral_kind: field("deferral_kind").presence || "none",
              insurance_mode: field("insurance_mode").presence || "none", insurance_value: decimal_value(form, "insurance_value") || BigDecimal.new(0))
          end
        end
      end

      # Capital, taux, nombre d'échéances, première échéance.
      private def read_terms(form : Form) : {BigDecimal, BigDecimal, Int32, Time}?
        principal = decimal_value(form, "principal", required: true)
        rate = decimal_value(form, "annual_rate", required: true)
        months = int_value(form, "months", required: true)
        first = date_value(form, "first_due_on", required: true)
        {principal, rate, months, first} if principal && rate && months && first
      end

      # Compte payeur, catégorie des intérêts.
      private def read_links(form : Form) : {Int64, Int64}?
        payment = id_field("payment_account_id")
        interest = id_field("interest_category_id")
        form.add_error("payment_account_id", I18n.t("ui.forms.required")) if payment.nil?
        form.add_error("interest_category_id", I18n.t("ui.forms.required")) if interest.nil?
        {payment, interest} if payment && interest
      end

      private def loan_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        cash = accounts.select { |account| account.cash? && account.writable && !account.closed }.map { |account| option(account.id.to_s, account.label) }
        fields = [
          Form::Field.new("payment_account_id", I18n.t("perso_ui.loans.payment_account"), "select", value.call("payment_account_id"),
            options: [blank_option] + cash, required: true),
          Form::Field.new("principal", I18n.t("perso_ui.loans.principal"), "number", value.call("principal"), required: true, mono: true),
          Form::Field.new("annual_rate", I18n.t("perso_ui.loans.rate"), "number", value.call("annual_rate"), required: true, mono: true,
            help: I18n.t("perso_ui.loans.rate_help")),
          Form::Field.new("months", I18n.t("perso_ui.loans.months"), "number", value.call("months"), required: true, mono: true),
          Form::Field.new("first_due_on", I18n.t("perso_ui.loans.first_due_on"), "date", value.call("first_due_on"), required: true),
          Form::Field.new("deferral_kind", I18n.t("perso_ui.loans.deferral_kind"), "select", value.call("deferral_kind"),
            options: code_options(Api::DEFERRAL_KINDS, "perso.deferral_kinds")),
          Form::Field.new("deferral_months", I18n.t("perso_ui.loans.deferral_months"), "number", value.call("deferral_months"), mono: true),
          Form::Field.new("insurance_mode", I18n.t("perso_ui.loans.insurance_mode"), "select", value.call("insurance_mode"),
            options: code_options(Api::INSURANCE_MODES, "perso.insurance_modes")),
          Form::Field.new("insurance_value", I18n.t("perso_ui.loans.insurance_value"), "number", value.call("insurance_value"), mono: true,
            help: I18n.t("perso_ui.loans.insurance_help")),
          Form::Field.new("interest_category_id", I18n.t("perso_ui.loans.interest_category"), "select", value.call("interest_category_id"),
            options: category_options("expense"), required: true),
          Form::Field.new("insurance_category_id", I18n.t("perso_ui.loans.insurance_category"), "select", value.call("insurance_category_id"),
            options: category_options("expense")),
        ]
        Form.new([Form::Group.new(nil, fields)])
      end

      private def show(view : Api::AccountView, form : Form) : Marten::HTTP::Response
        title = I18n.t("perso_ui.loans.new")
        form_page(title, crumbs({I18n.t("perso.menu.perso_accounts"), Ui.url("accounts")}, {view.label, Ui.url("account", id: view.id)},
          {title, nil}), form, Ui.url("loan_new", id: view.id), I18n.t("ui.forms.create"), Ui.url("account", id: view.id),
          intro: I18n.t("perso_ui.loans.intro"))
      end
    end

    # Remboursement anticipé (D5) : une nouvelle version du tableau.
    class LoanPrepayHandler < Handler
      def get
        show(Api.loan(actor, id_param), prepay_form({"date" => Partiduo::Api::Core.today.to_s("%F"), "mode" => "duration", "record" => "1"}))
      end

      def post
        loan = Api.loan(actor, id_param)
        form = prepay_form(submitted(%w[date amount mode record]))
        date = date_value(form, "date", required: true)
        amount = decimal_value(form, "amount", required: true)
        if !form.invalid && date && amount
          result = Api.prepay_loan(actor, loan.id, Api::PrepaymentInput.new(date, amount, field("mode").presence || "duration", checkbox("record")))
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.loan_prepaid")
            return go(Ui.url("account", id: loan.account_id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(loan, form)
      end

      private def prepay_form(values : Hash(String, String)) : Form
        Form.new([Form::Group.new(nil, [
          Form::Field.new("date", I18n.t("perso_ui.loans.prepayment_date"), "date", values["date"]? || "", required: true),
          Form::Field.new("amount", I18n.t("perso_ui.loans.prepayment"), "number", values["amount"]? || "", required: true, mono: true),
          Form::Field.new("mode", I18n.t("perso_ui.loans.prepayment_mode"), "select", values["mode"]? || "duration",
            options: code_options(Api::PREPAYMENT_MODES, "perso.prepayment_modes")),
          Form::Field.new("record", I18n.t("perso_ui.loans.record_operation"), "checkbox", values["record"]? || ""),
        ])])
      end

      private def show(loan : Api::LoanView, form : Form) : Marten::HTTP::Response
        title = I18n.t("perso_ui.loans.prepay")
        form_page(title, crumbs({I18n.t("perso.menu.perso_accounts"), Ui.url("accounts")},
          {loan.account_label, Ui.url("account", id: loan.account_id)}, {title, nil}), form, Ui.url("loan_prepay", id: loan.id),
          I18n.t("perso_ui.loans.prepay"), Ui.url("account", id: loan.account_id), intro: I18n.t("perso_ui.loans.prepay_intro"))
      end
    end

    class LoanConfirmHandler < Handler
      def get
        go(Ui.url("schedule"))
      end

      def post
        due = fmt.parse_date(query("due_on")) || raise Partiduo::Api::NotFound.new("perso_installment", query("due_on"))
        result = Api.confirm_installment(actor, id_param, due)
        back = query("next") == "schedule" ? Ui.url("schedule") : result.value?.try { |loan| Ui.url("account", id: loan.account_id) } || Ui.url("schedule")
        after(result, "perso_ui.flash.installment_confirmed", back)
      end
    end
  end
end
