# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Ui
    # `/ext/PERSO/budgets` : le budget d'une année (D8) — montant budgété par
    # catégorie, budget et réalisé à date, écart, reste sur l'année,
    # dépassements signalés ; saisie d'un montant, proposition tirée du
    # réalisé de l'année précédente.
    class BudgetsHandler < Handler
      def get
        year = year_param
        budget = Api.budget(actor, year)
        years = (Api.budget_years(actor) + [year, Partiduo::Api::Core.today.year, Partiduo::Api::Core.today.year + 1]).uniq.sort!.reverse!
        tabs = years.map { |item| Screen::Tab.new(item.to_s, Ui.url_with("budgets", {"year" => item.to_s}), item == year) }
        actions = [] of Screen::Action
        sections = [] of Screen::Section
        if budget.nil?
          if can_budget?
            actions << post_action("perso_ui.budgets.create", Ui.url_with("budget_create", {"year" => year.to_s}), nil, "primary", "plus")
            actions << post_action("perso_ui.budgets.propose", Ui.url("budget_propose", year: year), nil, "", "refresh-cw")
          end
          sections << Screen::Section.new(I18n.t("perso_ui.budgets.title", year: year), note: I18n.t("perso_ui.budgets.none", year: year))
        else
          sections << Screen::Section.new(I18n.t("perso_ui.budgets.title", year: year), table: lines_table(budget),
            note: alert(budget))
          sections << Screen::Section.new(I18n.t("perso_ui.budgets.months"), table: months_table(budget))
          if can_budget?
            actions << post_action("perso_ui.budgets.propose", Ui.url("budget_propose", year: year), "perso_ui.budgets.propose_question", "", "refresh-cw")
            set_form(line_form({"period_kind" => "monthly"}), Ui.url("budget_line", year: year), I18n.t("perso_ui.budgets.set_line"),
              title: I18n.t("perso_ui.budgets.set_line"))
          end
        end
        show_detail(I18n.t("perso.menu.perso_budgets"), crumbs({I18n.t("perso.menu.perso_budgets"), nil}), sections, actions,
          intro: I18n.t("perso_ui.budgets.intro"), tabs: tabs)
      end

      def line_form(values : Hash(String, String)) : Form
        Form.new([Form::Group.new(nil, [
          Form::Field.new("category_id", I18n.t("perso_ui.operations.category"), "select", values["category_id"]? || "",
            options: category_options(postable: false), required: true),
          Form::Field.new("amount", I18n.t("perso_ui.budgets.amount"), "number", values["amount"]? || "", required: true, mono: true),
          Form::Field.new("period_kind", I18n.t("perso_ui.budgets.period_kind"), "select", values["period_kind"]? || "monthly",
            options: code_options(Api::PERIOD_KINDS, "perso.period_kinds")),
        ])])
      end

      private def alert(budget : Api::BudgetView) : String?
        over = budget.over
        return if over.empty?
        I18n.t("perso_ui.budgets.over", count: over.size, list: over.map(&.category_label).join(", "))
      end

      private def lines_table(budget : Api::BudgetView) : Table
        rows = budget.lines.map do |line|
          actions = can_budget? ? [post_action("perso_ui.budgets.delete_line", Ui.url("budget_line_delete", year: budget.year, id: line.id),
            "perso_ui.budgets.confirm_delete", "row-danger", "trash-2")] : [] of Screen::Action
          state = line.over? ? I18n.t("perso_ui.budgets.state_over") : I18n.t("perso_ui.budgets.state_ok")
          Table::Row.new([
            Table::Cell.new(line.category_label), Table::Cell.new(I18n.t(line.period_kind_key)), Present.money(fmt, line.amount),
            Present.money(fmt, line.budget_to_date), Present.money(fmt, line.actual_to_date), Present.money(fmt, line.difference),
            Present.money(fmt, line.remaining), Table::Cell.new(state), Table::Cell.new("", actions: actions),
          ], css: line.over? ? "is-warning" : "")
        end
        Table.new(I18n.t("perso_ui.budgets.title", year: budget.year), [
          Table::Column.new("category", I18n.t("perso_ui.operations.category")),
          Table::Column.new("period_kind", I18n.t("perso_ui.budgets.period_kind"), secondary: true),
          Table::Column.new("amount", I18n.t("perso_ui.budgets.amount"), "number"),
          Table::Column.new("budget", I18n.t("perso_ui.budgets.budget_to_date"), "number"),
          Table::Column.new("actual", I18n.t("perso_ui.budgets.actual_to_date"), "number"),
          Table::Column.new("difference", I18n.t("perso_ui.budgets.difference"), "number"),
          Table::Column.new("remaining", I18n.t("perso_ui.budgets.remaining"), "number"),
          Table::Column.new("state", I18n.t("perso_ui.schedule.status")),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], rows, Ui.url_with("budgets", {"year" => budget.year.to_s}), empty_message: I18n.t("perso_ui.budgets.empty"), id: "perso-budget")
      end

      # Réalisé mois par mois, dépenses et recettes budgétées.
      private def months_table(budget : Api::BudgetView) : Table
        expenses = budget.lines.select(&.kind.==("expense"))
        incomes = budget.lines.select(&.kind.==("income"))
        rows = budget.months.map_with_index do |month, index|
          spent = expenses.sum(BigDecimal.new(0)) { |line| line.monthly_actual[index]? || BigDecimal.new(0) }
          planned = expenses.sum(BigDecimal.new(0)) { |line| line.monthly_budget[index]? || BigDecimal.new(0) }
          earned = incomes.sum(BigDecimal.new(0)) { |line| line.monthly_actual[index]? || BigDecimal.new(0) }
          Table::Row.new([Table::Cell.new(fmt.month(month)), Present.money(fmt, planned), Present.money(fmt, spent),
                          Present.money(fmt, earned), Present.money(fmt, earned - spent)])
        end
        table = Table.new(I18n.t("perso_ui.budgets.months"), [
          Table::Column.new("month", I18n.t("perso_ui.budgets.month")),
          Table::Column.new("planned", I18n.t("perso_ui.budgets.planned_expenses"), "number"),
          Table::Column.new("spent", I18n.t("perso_ui.budgets.actual_expenses"), "number"),
          Table::Column.new("earned", I18n.t("perso_ui.budgets.actual_income"), "number"),
          Table::Column.new("balance", I18n.t("perso_ui.budgets.balance"), "number"),
        ], rows, Ui.url_with("budgets", {"year" => budget.year.to_s}), id: "perso-budget-months")
        table.exportable = false
        table
      end
    end

    class BudgetCreateHandler < Handler
      def get
        go(Ui.url("budgets"))
      end

      def post
        year = query("year").to_i? || field("year").to_i? || Partiduo::Api::Core.today.year
        after(Api.create_budget(actor, year), "perso_ui.flash.budget_created", Ui.url_with("budgets", {"year" => year.to_s}), {"year" => year.to_s})
      end
    end

    class BudgetLineHandler < BudgetsHandler
      def post
        year = params["year"].to_s.to_i
        form = line_form(submitted(%w[category_id amount period_kind]))
        amount = decimal_value(form, "amount", required: true)
        category = id_field("category_id")
        if amount.nil? || category.nil?
          flash["danger"] = I18n.t("perso_ui.budgets.line_invalid")
          return go(Ui.url_with("budgets", {"year" => year.to_s}))
        end
        result = Api.set_budget_line(actor, year, Api::BudgetLineInput.new(category, amount, field("period_kind").presence || "monthly"))
        after(result, "perso_ui.flash.budget_line_saved", Ui.url_with("budgets", {"year" => year.to_s}))
      end
    end

    class BudgetLineDeleteHandler < Handler
      def get
        go(Ui.url("budgets"))
      end

      def post
        year = params["year"].to_s.to_i
        after(Api.delete_budget_line(actor, year, id_param), "perso_ui.flash.budget_line_deleted", Ui.url_with("budgets", {"year" => year.to_s}))
      end
    end

    class BudgetProposeHandler < Handler
      def get
        go(Ui.url("budgets"))
      end

      def post
        year = params["year"].to_s.to_i
        after(Api.propose_budget(actor, year), "perso_ui.flash.budget_proposed", Ui.url_with("budgets", {"year" => year.to_s}))
      end
    end

    # `/ext/PERSO/wealth` : le patrimoine net (D9) — trésorerie,
    # placements et plus-values latentes, biens, dettes ; répartitions par
    # nature et par membre ; douze derniers mois.
    class WealthHandler < Handler
      def get
        wealth = Api.wealth(actor)
        summary = [
          Screen::Item.new(I18n.t("perso_ui.wealth.cash"), fmt.amount(wealth.cash), mono: true),
          Screen::Item.new(I18n.t("perso_ui.wealth.investments"), fmt.amount(wealth.investments_total), mono: true),
          Screen::Item.new(I18n.t("perso_ui.wealth.property"), fmt.amount(wealth.property_total), mono: true),
          Screen::Item.new(I18n.t("perso_ui.wealth.debts"), fmt.amount(-wealth.debts_total), mono: true),
          Screen::Item.new(I18n.t("perso_ui.wealth.net"), fmt.amount(wealth.net), mono: true),
        ]
        holdings = Api.holdings(actor)
        investments = Table.new(I18n.t("perso_ui.wealth.holdings"), [
          Table::Column.new("label", I18n.t("perso_ui.accounts.label")),
          Table::Column.new("nature", I18n.t("perso_ui.accounts.nature"), secondary: true),
          Table::Column.new("contributions", I18n.t("perso_ui.valuations.contributions"), "number"),
          Table::Column.new("value", I18n.t("perso_ui.valuations.latest"), "number"),
          Table::Column.new("date", I18n.t("perso_ui.valuations.date"), "mono"),
          Table::Column.new("gain", I18n.t("perso_ui.valuations.gain"), "number"),
        ], holdings.map do |holding|
          Table::Row.new([Table::Cell.new(holding.account.label, Ui.url("account", id: holding.account.id)),
                          Table::Cell.new(I18n.t(holding.account.nature_key)), Present.money(fmt, holding.contributions),
                          Present.money(fmt, holding.latest.try(&.amount) || holding.account.value),
                          Present.date(fmt, holding.latest.try(&.valued_on)),
                          holding.latent_gain.try { |gain| Present.money(fmt, gain) } || Table::Cell.new("")])
        end, Ui.url("wealth"), empty_message: I18n.t("perso_ui.wealth.no_holdings"), id: "perso-holdings")
        by_nature = amounts_table(I18n.t("perso_ui.wealth.by_nature"), wealth.by_nature, "perso-by-nature")
        by_member = amounts_table(I18n.t("perso_ui.wealth.by_member"), wealth.by_member, "perso-by-member")
        months = amounts_table(I18n.t("perso_ui.wealth.months"), wealth.months.map { |item| Api::AmountView.new(item.code, fmt.month(Time.parse_utc("#{item.code}-01", "%Y-%m-%d")), item.amount) }, "perso-months")
        actions = [link_action("perso_ui.wealth.export_valuations", Ui.url("export", kind: "valuations"), "", "download")]
        show_detail(I18n.t("perso.menu.perso_wealth"), crumbs({I18n.t("perso.menu.perso_wealth"), nil}), [
          Screen::Section.new(I18n.t("perso_ui.wealth.summary", date: fmt.date(wealth.as_of)), summary),
          Screen::Section.new(I18n.t("perso_ui.wealth.holdings"), table: investments, note: I18n.t("perso_ui.wealth.holdings_help")),
          Screen::Section.new(I18n.t("perso_ui.wealth.by_nature"), table: by_nature),
          Screen::Section.new(I18n.t("perso_ui.wealth.by_member"), table: by_member),
          Screen::Section.new(I18n.t("perso_ui.wealth.months"), table: months),
        ], actions, intro: I18n.t("perso_ui.wealth.intro"))
      end

      private def amounts_table(caption : String, items : Array(Api::AmountView), id : String) : Table
        Table.new(caption, [
          Table::Column.new("label", I18n.t("perso_ui.wealth.item")),
          Table::Column.new("amount", I18n.t("perso_ui.wealth.amount"), "number"),
        ], items.map { |item| Table::Row.new([Table::Cell.new(item.label), Present.money(fmt, item.amount)]) }, Ui.url("wealth"), id: id)
      end
    end
  end
end
