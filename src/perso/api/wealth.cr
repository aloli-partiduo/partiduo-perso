# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Api
    # --- Placements et valorisations (D9) ------------------------------------------------

    # Placements et biens visibles : historique des valeurs, versements
    # nets, plus-value latente.
    def self.holdings(actor : Actor) : Array(HoldingView)
      authorize!(actor, READ)
      Accounts.views(actor).select(&.valued?).map { |account| Wealth.holding(account) }
    end

    def self.holding(actor : Actor, account_id : Int64) : HoldingView
      authorize!(actor, READ)
      row, ledger = Records.account!(actor, account_id)
      Wealth.holding(Accounts.view(row, ledger, Accounts.holders))
    end

    # Saisit une valeur à une date (ou les lignes d'un PEA, d'un
    # compte-titres) ; l'historique est gardé. Ce n'est pas une écriture.
    def self.record_valuation(actor : Actor, input : ValuationInput) : Result(ValuationView)
      authorize!(actor, BUDGET)
      _account, errors = Wealth.errors(actor, input)
      return Result(ValuationView).failure(errors) unless errors.empty?
      Transaction.run { Result(ValuationView).success(Wealth.valuation_view(Wealth.create(actor, input))) }
    end

    def self.delete_valuation(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, BUDGET)
      Transaction.run do
        row = Valuation.filter(id: id).first || raise Partiduo::Api::NotFound.new("perso_valuation", id)
        Records.account!(actor, row.account_id!.to_i64)
        row.delete
        Result(Nil).success(nil)
      end
    end

    # Patrimoine net au jour (D9) : trésorerie, placements, biens, dettes,
    # répartitions, douze derniers mois. Comptes visibles seulement.
    def self.wealth(actor : Actor) : WealthView
      authorize!(actor, READ)
      Wealth.view(actor)
    end

    # --- Budgets (D8) ---------------------------------------------------------------------

    def self.budget_years(actor : Actor) : Array(Int32)
      authorize!(actor, READ)
      Budget.all.order("-year").to_a.map(&.year!.to_i32)
    end

    # Budget d'une année et son réalisé ; `nil` s'il n'existe pas. Exige
    # aussi `accounting.report.read` (comparaison de la prévision).
    def self.budget(actor : Actor, year : Int32) : BudgetView?
      authorize!(actor, READ)
      row = Budget.filter(year: year).first || return
      claim(actor, row)
      Budgets.view(actor, row)
    end

    # Reprise d'un budget créé avant la prévision tenue (D-PER-020) : à la
    # consultation par qui peut écrire les budgets, sa prévision devient
    # tenue par l'extension ; sinon elle le deviendra à la prochaine
    # écriture. Une prévision déjà modifiée hors de l'extension reste
    # signalée (`budget.forecast.broken`) à l'écriture.
    private def self.claim(actor : Actor, row : Budget) : Nil
      return unless actor.can?(BUDGET) && actor.can?("accounting.report.write") && Budgets.unclaimed?(actor, row)
      Transaction.run do
        errors = Budgets.claim(actor, row)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end
    end

    # Crée le budget d'une année (prévision de la Comptabilité). Exige
    # aussi `accounting.report.write`.
    def self.create_budget(actor : Actor, year : Int32) : Result(BudgetView)
      authorize!(actor, BUDGET)
      Transaction.run do
        row, errors = Budgets.create(actor, year)
        next Result(BudgetView).failure(errors) if row.nil?
        Result(BudgetView).success(Budgets.view(actor, row))
      end
    end

    # Montant budgété d'une catégorie (mensuel ou annuel).
    def self.set_budget_line(actor : Actor, year : Int32, input : BudgetLineInput) : Result(BudgetView)
      authorize!(actor, BUDGET)
      Transaction.run do
        budget = Records.budget!(year)
        _row, errors = Budgets.set_line(actor, budget, input)
        next Result(BudgetView).failure(errors) unless errors.empty?
        Result(BudgetView).success(Budgets.view(actor, budget))
      end
    end

    def self.delete_budget_line(actor : Actor, year : Int32, line_id : Int64) : Result(BudgetView)
      authorize!(actor, BUDGET)
      Transaction.run do
        budget = Records.budget!(year)
        row = BudgetLine.filter(id: line_id, budget_id: budget.id).first || raise Partiduo::Api::NotFound.new("perso_budget_line", line_id)
        errors = Budgets.delete_line(actor, row)
        next Result(BudgetView).failure(errors) unless errors.empty?
        Result(BudgetView).success(Budgets.view(actor, budget))
      end
    end

    # Propose le budget d'une année à partir du réalisé de l'année
    # précédente (D8) : le budget est créé au besoin ; les catégories déjà
    # budgétées sont gardées.
    def self.propose_budget(actor : Actor, year : Int32) : Result(BudgetView)
      authorize!(actor, BUDGET)
      Transaction.run do
        budget = Budget.filter(year: year).first
        if budget.nil?
          created, errors = Budgets.create(actor, year)
          next Result(BudgetView).failure(errors) if created.nil?
          budget = created
        end
        _count, errors = Budgets.propose(actor, budget)
        next Result(BudgetView).failure(errors) unless errors.empty?
        Result(BudgetView).success(Budgets.view(actor, budget))
      end
    end

    # --- Aide à la déclaration de revenus (D10) ------------------------------------------

    def self.tax_summary(actor : Actor, year : Int32) : TaxSummaryView
      authorize!(actor, READ)
      Tax.summary(actor, year)
    end

    def self.tax_csv(actor : Actor, year : Int32) : FileView
      authorize!(actor, READ)
      Exports.tax_csv(Tax.summary(actor, year))
    end

    # Récapitulatif en PDF/A ; `amount` met les montants en forme dans la
    # langue de l'utilisateur.
    def self.tax_pdf(actor : Actor, year : Int32, amount : Proc(BigDecimal, String)) : Result(FileView)
      authorize!(actor, READ)
      Exports.tax_pdf(actor, Tax.summary(actor, year), amount)
    end

    def self.trips(actor : Actor, year : Int32) : Array(TripView)
      authorize!(actor, READ)
      _chosen, table = Tax.rates(year)
      names = Records.member_names
      Trip.filter(year: year).order(:id).to_a.map do |row|
        TripView.new(row.id!.to_i64, year, row.member_id.try { |id| names[id.to_i64]? }, row.fiscal_power!.to_i32,
          row.kilometers!.to_i32, row.label.to_s, Tax.allowance(table, row.fiscal_power!.to_i32, row.kilometers!.to_i32))
      end
    end

    def self.add_trip(actor : Actor, input : TripInput) : Result(TripView)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      errors << Records.error("year", "trip.year.invalid") unless 1990 <= input.year <= 2999
      errors << Records.error("fiscal_power", "mileage.power.invalid") unless 1 <= input.fiscal_power <= 99
      errors << Records.error("kilometers", "trip.kilometers.invalid") unless 1 <= input.kilometers <= 200_000
      errors << Records.error("label", "trip.label.too_long") if input.label.size > 255
      if member_id = input.member_id
        errors << Records.error("member_id", "operation.member.invalid") unless Member.filter(id: member_id).exists?
      end
      return Result(TripView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Trip.create!(year: input.year, member_id: input.member_id, fiscal_power: input.fiscal_power,
          kilometers: input.kilometers, label: input.label.strip, created_by_id: actor.user_id)
        _chosen, table = Tax.rates(input.year)
        Result(TripView).success(TripView.new(row.id!.to_i64, input.year, Records.member_names[input.member_id || 0_i64]?,
          input.fiscal_power, input.kilometers, input.label.strip, Tax.allowance(table, input.fiscal_power, input.kilometers)))
      end
    end

    def self.delete_trip(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, WRITE)
      Transaction.run do
        (Trip.filter(id: id).first || raise Partiduo::Api::NotFound.new("perso_trip", id)).delete
        Result(Nil).success(nil)
      end
    end
  end
end
