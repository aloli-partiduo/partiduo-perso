# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Budgets (D8, D-PER-012) : une prévision budgétaire de la Comptabilité
  # par année civile (`create_forecast`), deux catégories de prévision
  # (dépenses, recettes), un élément par catégorie budgétée dont la formule
  # du réel porte sur le compte de la catégorie et ses sous-comptes ;
  # réalisé, écart et reste lus dans `forecast_report`. Interne.
  module Budgets
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError
    alias Actor = Partiduo::Api::Actor

    # Rang des deux catégories de la prévision.
    GROUPS = {"expense" => 1, "income" => 2}

    # Formule du réel d'une catégorie : solde débiteur des comptes d'une
    # dépense, créditeur d'une recette.
    def self.formula(category : Category) : String
      suffix = category.kind == "income" ? "S" : "s"
      "[#{category.account}%-#{suffix}]"
    end

    # Crée le budget d'une année : l'exercice civil (créé au besoin), la
    # prévision et ses deux catégories.
    def self.create(actor : Actor, year : Int32) : {Budget?, Array(FieldError)}
      if Budget.filter(year: year).exists?
        return {nil, [Records.error("year", "budget.year.taken", {"year" => year.to_s})]}
      end
      Years.prepare(year)
      periods = Years.periods(year)
      return {nil, [Records.error("year", "budget.year.missing", {"year" => year.to_s})]} if periods.nil?
      forecast = Acc.create_forecast(actor, Acc::ForecastInput.new(name: I18n.t("perso.labels.budget", year: year.to_s),
        start_period_id: periods.first.id, end_period_id: periods.last.id))
      return {nil, forecast.errors} if forecast.failure?
      forecast_id = forecast.value!.id
      GROUPS.each do |kind, position|
        result = Acc.create_forecast_category(actor, forecast_id,
          Acc::ForecastCategoryInput.new(I18n.t("perso.category_kinds.#{kind}"), position))
        return {nil, result.errors} if result.failure?
      end
      {Budget.create!(year: year, forecast_id: forecast_id), [] of FieldError}
    end

    # Catégorie de la prévision qui reçoit les éléments d'un sens.
    private def self.group_id(actor : Actor, budget : Budget, kind : String) : Int64?
      view = Acc.forecast(actor, budget.forecast_id!.to_i64)
      view.categories.find(&.position.==(GROUPS[kind])).try(&.id)
    end

    # Montants de chaque mois : le montant mensuel, ou l'annuel réparti au
    # centime (la dernière période reçoit le reste).
    def self.monthly_amounts(amount : BigDecimal, period_kind : String) : Array(BigDecimal)
      return Array.new(12, amount) if period_kind == "monthly"
      part = Records.cents(amount / BigDecimal.new(12))
      list = Array.new(11, part)
      list << amount - part * 11
      list
    end

    def self.line_errors(budget : Budget, input : Api::BudgetLineInput, current : BudgetLine? = nil) : Array(FieldError)
      errors = [] of FieldError
      errors << Records.error("amount", "budget.amount.invalid") if input.amount < 0
      errors << Records.error("period_kind", "budget.period_kind.invalid") unless Api::PERIOD_KINDS.includes?(input.period_kind)
      category = Category.filter(id: input.category_id).first
      if category.nil?
        errors << Records.error("category_id", "operation.category.invalid")
        return errors
      end
      others = BudgetLine.filter(budget_id: budget.id).to_a.reject { |row| current && row.id == current.id }
      taken = others.map(&.category_id!.to_i64).to_set
      if taken.includes?(category.id!.to_i64)
        errors << Records.error("category_id", "budget.category.taken")
      else
        related = Category.filter(parent_id: category.id).to_a.map(&.id!.to_i64)
        category.parent_id.try { |id| related << id.to_i64 }
        errors << Records.error("category_id", "budget.category.overlap") if related.any? { |id| taken.includes?(id) }
      end
      errors
    end

    # Ajoute ou remplace le montant budgété d'une catégorie.
    def self.set_line(actor : Actor, budget : Budget, input : Api::BudgetLineInput) : {BudgetLine?, Array(FieldError)}
      current = BudgetLine.filter(budget_id: budget.id, category_id: input.category_id).first
      errors = line_errors(budget, input, current)
      return {nil, errors} unless errors.empty?
      category = Records.category!(input.category_id)
      periods = Years.periods(budget.year!.to_i32) || return {nil, [Records.error("year", "budget.year.missing", {"year" => budget.year.to_s})]}
      amounts = monthly_amounts(input.amount, input.period_kind)
      item = Acc::ForecastItemInput.new(label: Categories.view(category).full_label, formula: formula(category),
        amount: input.period_kind == "monthly" ? input.amount : BigDecimal.new(0), position: category.position!.to_i32,
        period_amounts: input.period_kind == "monthly" ? [] of Acc::ForecastPeriodAmountInput : periods.map_with_index { |period, index| Acc::ForecastPeriodAmountInput.new(period.id, amounts[index]) })
      if current
        result = Acc.update_forecast_item(actor, current.forecast_item_id!.to_i64, item)
        return {nil, result.errors} if result.failure?
        current.amount = Records.cents(input.amount)
        current.period_kind = input.period_kind
        current.save!
        return {current, [] of FieldError}
      end
      group = group_id(actor, budget, category.kind.to_s) || return {nil, [Records.error("year", "budget.forecast.broken")]}
      result = Acc.create_forecast_item(actor, group, item)
      return {nil, result.errors} if result.failure?
      row = BudgetLine.create!(budget_id: budget.id, category_id: category.id, period_kind: input.period_kind,
        amount: Records.cents(input.amount), forecast_item_id: result.value!.id)
      {row, [] of FieldError}
    end

    def self.delete_line(actor : Actor, row : BudgetLine) : Array(FieldError)
      result = Acc.delete_forecast_item(actor, row.forecast_item_id!.to_i64)
      return result.errors if result.failure?
      row.delete
      [] of FieldError
    end

    # Budget et réalisé (D8) : `forecast_report` de la prévision, mois par
    # mois ; « à date » : jusqu'au mois du jour pour l'année en cours.
    def self.view(actor : Actor, budget : Budget, today : Time = Calendar.today) : Api::BudgetView
      report = Acc.forecast_report(actor, budget.forecast_id!.to_i64)
      items = report.categories.flat_map(&.items).index_by(&.item_id)
      year = budget.year!.to_i32
      elapsed = if year < today.year
                  12
                elsif year > today.year
                  0
                else
                  today.month
                end
      categories = Category.all.to_a.index_by(&.id!.to_i64)
      lines = BudgetLine.filter(budget_id: budget.id).to_a.compact_map do |row|
        category = categories[row.category_id!.to_i64]? || next
        item = items[row.forecast_item_id!.to_i64]?
        estimated = item.try(&.estimated) || monthly_amounts(row.amount!, row.period_kind.to_s)
        real = item.try(&.real) || Array.new(12, BigDecimal.new(0))
        Api::BudgetLineView.new(
          id: row.id!.to_i64, category_id: category.id!.to_i64, category_label: Categories.view(category).full_label,
          kind: category.kind.to_s, period_kind: row.period_kind.to_s, amount: row.amount!,
          budget_to_date: estimated.first(elapsed).sum(BigDecimal.new(0)), actual_to_date: real.first(elapsed).sum(BigDecimal.new(0)),
          budget_year: estimated.sum(BigDecimal.new(0)), actual_year: real.sum(BigDecimal.new(0)),
          monthly_budget: estimated, monthly_actual: real)
      end
      lines.sort_by! { |line| {line.kind == "income" ? 1 : 0, line.category_label.downcase} }
      Api::BudgetView.new(id: budget.id!.to_i64, year: year, forecast_id: budget.forecast_id!.to_i64,
        months: report.periods.map(&.starts_on), lines: lines, as_of: today)
    end

    # Réalisé d'une catégorie sur une année, lu dans la Comptabilité.
    def self.actual(category : Category, year : Int32) : BigDecimal
      total = BigDecimal.new(0)
      Acc.chart(Records.system, category.account.to_s).each do |line|
        statement = Acc.account_statement(Records.system, Acc::StatementQuery.new(account: line.account.number,
          date_from: Calendar.year_start(year), date_to: Calendar.year_end(year)))
        total += statement.total_debit - statement.total_credit
      end
      category.kind == "income" ? -total : total
    rescue Partiduo::Api::NotFound
      BigDecimal.new(0)
    end

    # Budget proposé (D8) : pour chaque catégorie sans sous-catégorie qui a
    # un réalisé l'année précédente, un montant mensuel égal au douzième de
    # ce réalisé. Les catégories déjà budgétées sont gardées. Rend le nombre
    # de montants proposés.
    def self.propose(actor : Actor, budget : Budget) : {Int32, Array(FieldError)}
      year = budget.year!.to_i32 - 1
      taken = BudgetLine.filter(budget_id: budget.id).to_a.map(&.category_id!.to_i64).to_set
      parents = Category.all.to_a.compact_map(&.parent_id.try(&.to_i64)).to_set
      count = 0
      Category.filter(active: true).order(:kind, :position, :label).each do |category|
        id = category.id!.to_i64
        next if parents.includes?(id) || taken.includes?(id)
        next if category.parent_id.try { |parent| taken.includes?(parent.to_i64) }
        actual = actual(category, year)
        next unless actual > 0
        _row, errors = set_line(actor, budget, Api::BudgetLineInput.new(id, Records.cents(actual / BigDecimal.new(12)), "monthly"))
        return {count, errors} unless errors.empty?
        count += 1
      end
      {count, [] of FieldError}
    end
  end
end
