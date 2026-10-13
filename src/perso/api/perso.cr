# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Contrat public de l'extension des finances personnelles d'un foyer
  # (ADR-011), sur le modèle de `Partiduo::Api` (DECISIONS C2 du cœur) :
  # acteur en premier argument, contrôle d'accès en première ligne
  # (extension active, dossier foyer, permission), objets de vue immuables,
  # toute écriture par une commande qui rend un `Result` avec ses erreurs
  # par champ, dans une transaction. L'interface de l'extension
  # (`ui/bulma/`) ne voit que ce module, `Bankimport::Api` et
  # `Partiduo::Api`.
  #
  # Ce fichier : contrôle d'accès, catégories, comptes, membres, règles de
  # catégorisation, barème kilométrique, tuile. Opérations dans
  # `operations.cr`, échéancier et emprunts dans `schedule.cr`, patrimoine,
  # budgets et déclaration dans `wealth.cr`. Référence : `doc/api/perso.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Transaction = Partiduo::Api::Transaction
    alias Acc = Partiduo::Api::Accounting

    MODULE_CODE = Perso::CODE
    READ        = "perso.read"
    WRITE       = "perso.write"
    BUDGET      = "perso.budget"
    ADMIN       = "perso.admin"

    # --- Disponibilité ---------------------------------------------------------------

    # Extension active, dossier d'un foyer, acteur qui peut lire.
    def self.available?(actor : Actor) : Bool
      Partiduo::Modules.active?(MODULE_CODE) && actor.authenticated? && actor.can?(READ) && Records.household?
    end

    # --- Catégories (D3) ----------------------------------------------------------------

    def self.categories(actor : Actor, include_inactive : Bool = true) : Array(CategoryView)
      authorize!(actor, READ)
      Categories.views(include_inactive)
    end

    def self.category(actor : Actor, id : Int64) : CategoryView
      authorize!(actor, READ)
      Categories.view(Records.category!(id))
    end

    # Catégorie d'un compte du plan (`62`, `6101`), pour les échanges avec
    # d'autres programmes (chargement d'un dossier, import) : l'interface du
    # foyer ne montre jamais ce numéro. `NotFound` si le compte n'est pas
    # celui d'une catégorie.
    def self.category_by_account(actor : Actor, number : String) : CategoryView
      authorize!(actor, READ)
      row = Category.filter(account: number.strip.upcase).first || raise Partiduo::Api::NotFound.new("perso_category", number)
      Categories.view(row)
    end

    # Crée une catégorie et son compte. Exige aussi
    # `accounting.account.write`.
    def self.create_category(actor : Actor, input : CategoryInput) : Result(CategoryView)
      authorize!(actor, ADMIN)
      errors = Categories.errors(input)
      return Result(CategoryView).failure(errors) unless errors.empty?
      Transaction.run do
        row, failures = Categories.create(actor, input)
        next Result(CategoryView).failure(failures) if row.nil?
        Result(CategoryView).success(Categories.view(row))
      end
    end

    # Modifie libellé, étiquette fiscale, rang, état ; le sens et le parent
    # ne changent pas (le compte reste à sa place).
    def self.update_category(actor : Actor, id : Int64, input : CategoryInput) : Result(CategoryView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.category!(id)
        errors = Categories.errors(input.copy_with(parent_id: row.parent_id.try(&.to_i64)), row)
        next Result(CategoryView).failure(errors) unless errors.empty?
        failures = Categories.update(actor, row, input)
        next Result(CategoryView).failure(failures) unless failures.empty?
        Result(CategoryView).success(Categories.view(row))
      end
    end

    # Supprime une catégorie jamais employée et son compte ; une catégorie
    # employée se retire (`update_category`, `active` faux).
    def self.delete_category(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        errors = Categories.delete(actor, Records.category!(id))
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end
    end

    # Reprend les comptes des classes 6 et 7 du plan comme catégories, sans
    # toucher aux catégories existantes (extension activée après la création
    # du dossier). Rend le nombre de catégories créées.
    def self.load_categories(actor : Actor) : Result(Int32)
      authorize!(actor, ADMIN)
      Guard.authorize!(actor, "accounting.account.read")
      Transaction.run { Result(Int32).success(Categories.load_defaults(actor)) }
    end

    # --- Comptes du foyer (D5) -----------------------------------------------------------

    # Comptes visibles de l'acteur (droits par journal, D12), solde et valeur
    # au jour `as_of`.
    def self.accounts(actor : Actor, as_of : Time? = nil) : Array(AccountView)
      authorize!(actor, READ)
      Accounts.views(actor, as_of.try { |day| Calendar.day(day) } || Calendar.today)
    end

    def self.account(actor : Actor, id : Int64) : AccountView
      authorize!(actor, READ)
      row, ledger = Records.account!(actor, id)
      Accounts.view(row, ledger, Accounts.holders)
    end

    # Journaux financiers que l'extension n'a pas encore repris (le compte
    # courant du plan réduit, un journal créé dans la Comptabilité).
    def self.available_ledgers(actor : Actor) : Array(Acc::LedgerView)
      authorize!(actor, ADMIN)
      taken = Account.all.to_a.map(&.ledger_id!.to_i64).to_set
      Records.ledgers(actor).values.reject { |ledger| taken.includes?(ledger.id) }.sort_by!(&.code)
    end

    # Crée un compte du foyer (D5) : journal financier repris, ou compte de
    # bilan, fiche Banque et journal créés par le contrat ; solde
    # d'ouverture passé en opérations diverses. Exige aussi les droits du
    # cœur employés : `accounting.account.write`, `cards.card.write`,
    # `accounting.ledger.write` (création), `accounting.entry.post` (solde
    # d'ouverture).
    def self.create_account(actor : Actor, input : AccountInput) : Result(AccountView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row, errors = Accounts.create(actor, input)
        next Result(AccountView).failure(errors) if row.nil?
        ledger = Acc.ledger(Records.system, row.ledger_id!.to_i64)
        Result(AccountView).success(Accounts.view(row, ledger, Accounts.holders))
      end
    end

    # Modifie ce que l'extension tient d'un compte (libellé, établissement,
    # taux, plafond, titulaires, clôture) ; le libellé du journal suit.
    def self.update_account(actor : Actor, id : Int64, input : AccountUpdateInput) : Result(AccountView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row, ledger = Records.account!(actor, id)
        errors = Accounts.errors(input, row.nature.to_s)
        next Result(AccountView).failure(errors) unless errors.empty?
        row.label = input.label.strip
        row.institution = input.institution.strip
        row.asset_kind = row.nature == "property" ? input.asset_kind : ""
        row.rate = input.rate.try { |rate| Records.round(rate, 4) }
        row.ceiling = input.ceiling.try { |ceiling| Records.cents(ceiling) }
        row.opened_on = input.opened_on.try { |day| Calendar.day(day) }
        row.closed = input.closed
        row.position = input.position
        row.save!
        Accounts.set_holders(row, input.holder_ids)
        Result(AccountView).success(Accounts.view(row, ledger, Accounts.holders))
      end
    end

    # --- Membres (D12) ---------------------------------------------------------------------

    def self.members(actor : Actor) : Array(MemberView)
      authorize!(actor, READ)
      emails = begin
        actor.can?("auth.users.manage") ? Partiduo::Api::Auth.users(actor).to_h { |user| {user.id, user.email} } : {} of Int64 => String
      rescue Partiduo::Api::AccessDenied
        {} of Int64 => String
      end
      Member.all.order(:display_name).to_a.map { |row| Records.member_view(row, emails) }
    end

    # Utilisateurs du dossier qui peuvent devenir membres : exige la gestion
    # des utilisateurs du socle.
    def self.candidate_users(actor : Actor) : Array(Partiduo::Api::Auth::UserView)
      authorize!(actor, ADMIN)
      taken = Member.all.to_a.map(&.user_id!.to_i64).to_set
      Partiduo::Api::Auth.users(actor).reject { |user| taken.includes?(user.id) }
    end

    def self.save_member(actor : Actor, input : MemberInput, id : Int64? = nil) : Result(MemberView)
      authorize!(actor, ADMIN)
      errors = [] of FieldError
      name = input.display_name.strip
      errors << Records.error("display_name", "member.name.blank") if name.empty?
      errors << Records.error("display_name", "member.name.too_long") if name.size > 80
      errors << Records.error("role", "member.role.invalid") unless MEMBER_ROLES.includes?(input.role)
      taken = Member.filter(user_id: input.user_id)
      taken = taken.exclude(id: id) if id
      errors << Records.error("user_id", "member.user.taken") if taken.exists?
      begin
        Partiduo::Api::Auth.user(Records.system, input.user_id)
      rescue Partiduo::Api::NotFound
        errors << Records.error("user_id", "member.user.invalid")
      end
      return Result(MemberView).failure(errors) unless errors.empty?
      Transaction.run do
        row = id ? Records.member!(id) : Member.new
        row.user_id = input.user_id
        row.display_name = name
        row.role = input.role
        row.save!
        Result(MemberView).success(Records.member_view(row))
      end
    end

    def self.delete_member(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        Records.member!(id).delete
        Result(Nil).success(nil)
      end
    end

    # Comptes que voit un membre (D12, visibilité par compte) : les droits
    # par journal du socle sont activés pour son utilisateur, en écriture sur
    # les comptes donnés (en lecture pour un conseiller), aucun accès aux
    # autres comptes du foyer. Exige aussi la gestion des utilisateurs du
    # socle.
    def self.set_member_accounts(actor : Actor, id : Int64, account_ids : Array(Int64)) : Result(Nil)
      authorize!(actor, ADMIN)
      member = Records.member!(id)
      user_id = member.user_id!.to_i64
      access = member.role == "advisor" ? "R" : "W"
      Transaction.run do
        result = Partiduo::Api::Auth.set_ledger_security(actor, user_id, true)
        next Result(Nil).failure(result.errors) if result.failure?
        failure = Account.all.to_a.each do |row|
          code = account_ids.includes?(row.id!.to_i64) ? access : "X"
          set = Partiduo::Api::Auth.set_ledger_access(actor, user_id, row.ledger_id!.to_i64, code)
          break set.errors if set.failure?
        end
        failure.is_a?(Array) ? Result(Nil).failure(failure) : Result(Nil).success(nil)
      end
    end

    # --- Règles de catégorisation (D6) -------------------------------------------------------

    # Règles de `partiduo-bankimport` dont la contrepartie est le compte d'une
    # catégorie (D-PER-017) : le foyer les lit et les écrit par le contrat de
    # l'import, sous les droits `bankimport.*`.
    def self.rules(actor : Actor) : Array(RuleView)
      authorize!(actor, READ)
      categories = Categories.labels_by_account
      accounts = Account.all.to_a.to_h { |row| {row.ledger_id!.to_i64, row.id!.to_i64} }
      Bankimport::Api.rules(actor).compact_map do |rule|
        found = categories[rule.account]? || next
        RuleView.new(id: rule.id, category_id: found[0], category_label: found[1], label_contains: rule.label_contains,
          amount: rule.amount, direction: rule.direction, account_id: rule.ledger_id.try { |ledger| accounts[ledger]? },
          position: rule.position, active: rule.active, learned: rule.learned, hits: rule.hits)
      end
    end

    def self.save_rule(actor : Actor, input : RuleInput, id : Int64? = nil) : Result(RuleView)
      authorize!(actor, ADMIN)
      category = Category.filter(id: input.category_id).first
      return Result(RuleView).failure(Records.error("category_id", "operation.category.invalid")) if category.nil?
      ledger_id = input.account_id.try { |account_id| Records.account!(actor, account_id)[0].ledger_id!.to_i64 }
      rule = Bankimport::Api::RuleInput.new(label_contains: input.label_contains, amount: input.amount,
        direction: input.direction, account: category.account.to_s, ledger_id: ledger_id, position: input.position,
        active: input.active)
      result = id ? Bankimport::Api.update_rule(actor, id, rule) : Bankimport::Api.create_rule(actor, rule)
      return Result(RuleView).failure(result.errors.map { |error| FieldError.new(error.field == "account" ? "category_id" : error.field, error.key, error.params) }) if result.failure?
      view = rules(actor).find(&.id.==(result.value!.id)) || raise Partiduo::Api::NotFound.new("perso_rule", result.value!.id)
      Result(RuleView).success(view)
    end

    def self.delete_rule(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Bankimport::Api.delete_rule(actor, id)
    end

    # --- Barème kilométrique (D10) ---------------------------------------------------------

    # Barème retenu pour une année (saisi, sinon valeurs de départ) : année
    # retenue et tranches.
    def self.mileage_rates(actor : Actor, year : Int32) : {Int32?, Array(MileageRateView)}
      authorize!(actor, READ)
      chosen, table = Tax.rates(year)
      stored = chosen ? MileageRate.filter(year: chosen).to_a : [] of MileageRate
      views = table.keys.sort!.flat_map do |power|
        table[power].map do |rate|
          row = stored.find { |item| item.fiscal_power == power && item.max_km.try(&.to_i32) == rate.max_km }
          MileageRateView.new(row.try(&.id!.to_i64) || 0_i64, chosen || year, power, rate.max_km, rate.coefficient, rate.constant)
        end
      end
      {chosen, views}
    end

    # Enregistre le barème d'une année : les tranches données remplacent
    # celles de l'année.
    def self.set_mileage_rates(actor : Actor, year : Int32, rates : Array(MileageRateInput)) : Result(Int32)
      authorize!(actor, ADMIN)
      errors = [] of FieldError
      errors << Records.error("year", "mileage.year.invalid") unless 1990 <= year <= 2999
      rates.each_with_index do |rate, index|
        errors << Records.error("rates[#{index}].fiscal_power", "mileage.power.invalid") unless 1 <= rate.fiscal_power <= 99
        errors << Records.error("rates[#{index}].coefficient", "mileage.coefficient.invalid") if rate.coefficient < 0
        rate.max_km.try { |max| errors << Records.error("rates[#{index}].max_km", "mileage.max_km.invalid") unless max > 0 }
      end
      keys = rates.map { |rate| {rate.fiscal_power, rate.max_km} }
      errors << Records.error("rates", "mileage.duplicate") unless keys.uniq.size == keys.size
      return Result(Int32).failure(errors) unless errors.empty?
      Transaction.run do
        MileageRate.filter(year: year).delete
        rates.each do |rate|
          MileageRate.create!(year: year, fiscal_power: rate.fiscal_power, max_km: rate.max_km,
            coefficient: rate.coefficient, constant: rate.constant)
        end
        Result(Int32).success(rates.size)
      end
    end

    # --- Tableau de bord --------------------------------------------------------------------

    # Tuile ; `nil` si l'extension est inactive, le dossier celui d'une
    # entreprise ou l'acteur sans droit (ni lecture des écritures).
    def self.tile(actor : Actor, today : Time = Calendar.today) : TileView?
      return unless available?(actor) && actor.can?("accounting.entry.read")
      accounts = Accounts.views(actor, today)
      schedule = Schedule.build(actor, today, today + 30.days, today)
      over = [] of String
      if actor.can?("accounting.report.read") && (budget = Budget.filter(year: today.year).first)
        over = Budgets.view(actor, budget, today).over.map(&.category_label)
      end
      cash = accounts.select(&.cash?).sum(BigDecimal.new(0), &.value)
      net = accounts.sum(BigDecimal.new(0)) { |account| Wealth.signed(account) }
      TileView.new(cash, net, schedule.overdue_count, schedule.dues.count(&.status.==("upcoming")), over, accounts.size)
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # Échéances en retard, pour le compteur du menu ; `nil` sans droit.
    def self.overdue_count(actor : Actor) : Int64?
      return unless available?(actor) && actor.can?("accounting.entry.read")
      today = Calendar.today
      count = Schedule.build(actor, today, today, today).overdue_count.to_i64
      count.zero? ? nil : count
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # --- Outils ------------------------------------------------------------------------------

    # Extension active et permission ; un dossier d'entreprise n'a pas de
    # finances de foyer : l'extension y est indisponible (D-PER-001).
    private def self.authorize!(actor : Actor, permission : String) : Nil
      Guard.authorize!(actor, permission, module_code: MODULE_CODE)
      raise Partiduo::Api::ModuleDisabled.new(MODULE_CODE) unless Records.household?
    end
  end
end
