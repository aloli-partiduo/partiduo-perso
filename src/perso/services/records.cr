# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Recherche des lignes, visibilité par journal et outils communs du
  # métier (interne).
  module Records
    alias Api = Perso::Api
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError
    alias Actor = Partiduo::Api::Actor

    ZERO = BigDecimal.new(0)

    def self.error(field : String, key : String, params : Hash(String, String) = {} of String => String) : FieldError
      FieldError.new(field, "perso.errors.#{key}", params)
    end

    def self.system : Actor
      Actor.system
    end

    # Montant arrondi au centime, demi-centime au-dessus (comme le cœur),
    # échelle ramenée à deux décimales au plus.
    def self.cents(value : BigDecimal) : BigDecimal
      Amortization.cents(value)
    end

    # Valeur arrondie à `digits` décimales (demi au-dessus), échelle ramenée
    # au plus juste : elle s'enregistre dans une colonne à `digits` décimales.
    def self.round(value : BigDecimal, digits : Int32) : BigDecimal
      text = value.round(digits, mode: :ties_away).to_s
      text = text.rstrip('0').rstrip('.') if text.includes?('.')
      BigDecimal.new(text.empty? || text == "-" ? "0" : text)
    end

    def self.decimal(value : BigDecimal?) : BigDecimal
      value || ZERO
    end

    # Régime fiscal du dossier (`fr`, `be`).
    def self.regime : String
      Partiduo::Api::Core.settings(system).tax_regime
    rescue Partiduo::Api::NotFound
      "fr"
    end

    def self.household? : Bool
      Partiduo::Api::Core.settings(system).household?
    rescue Partiduo::Api::NotFound
      false
    end

    # --- Recherche ---------------------------------------------------------------

    def self.category!(id : Int64) : Category
      Category.filter(id: id).first || raise Partiduo::Api::NotFound.new("perso_category", id)
    end

    def self.member!(id : Int64) : Member
      Member.filter(id: id).first || raise Partiduo::Api::NotFound.new("perso_member", id)
    end

    def self.recurring!(id : Int64) : Recurring
      Recurring.filter(id: id).first || raise Partiduo::Api::NotFound.new("perso_recurring", id)
    end

    def self.loan!(id : Int64) : Loan
      Loan.filter(id: id).first || raise Partiduo::Api::NotFound.new("perso_loan", id)
    end

    def self.budget!(year : Int32) : Budget
      Budget.filter(year: year).first || raise Partiduo::Api::NotFound.new("perso_budget", year)
    end

    # --- Visibilité (D12, droits par journal) ---------------------------------------

    # Journaux financiers visibles de l'acteur, par identifiant.
    def self.ledgers(actor : Actor) : Hash(Int64, Acc::LedgerView)
      Acc.ledgers(actor, Acc::LedgerKind::Financial).to_h { |ledger| {ledger.id, ledger} }
    rescue Partiduo::Api::AccessDenied
      {} of Int64 => Acc::LedgerView
    end

    # Comptes du foyer dont l'acteur voit le journal.
    def self.visible_accounts(actor : Actor) : Array({Account, Acc::LedgerView})
      visible = ledgers(actor)
      Account.all.order(:position, :label, :id).to_a.compact_map do |row|
        ledger = visible[row.ledger_id!.to_i64]? || next
        {row, ledger}
      end
    end

    # Compte visible de l'acteur ; `NotFound` sinon.
    def self.account!(actor : Actor, id : Int64) : {Account, Acc::LedgerView}
      row = Account.filter(id: id).first || raise Partiduo::Api::NotFound.new("perso_account", id)
      ledger = ledgers(actor)[row.ledger_id!.to_i64]? || raise Partiduo::Api::NotFound.new("perso_account", id)
      {row, ledger}
    end

    # Compte visible et où l'acteur peut écrire, ou erreur sur `field`.
    def self.writable_account(actor : Actor, id : Int64?, field : String, errors : Array(FieldError)) : Account?
      if id.nil?
        errors << error(field, "account.blank")
        return
      end
      row, ledger = account!(actor, id)
      unless ledger.access.writable?
        errors << error(field, "account.read_only")
        return
      end
      if row.closed
        errors << error(field, "account.closed")
        return
      end
      row
    rescue Partiduo::Api::NotFound
      errors << error(field, "account.invalid")
      nil
    end

    # --- Membres --------------------------------------------------------------------

    def self.member_names : Hash(Int64, String)
      Member.all.to_a.to_h { |row| {row.id!.to_i64, row.display_name.to_s} }
    end

    def self.member_name_for_user(user_id : Int64?) : String?
      user_id.try { |id| Member.filter(user_id: id).first.try(&.display_name.to_s) }
    end

    def self.member_view(row : Member, emails : Hash(Int64, String) = {} of Int64 => String) : Api::MemberView
      Api::MemberView.new(row.id!.to_i64, row.user_id!.to_i64, row.display_name.to_s, row.role.to_s,
        emails[row.user_id!.to_i64]? || "")
    end
  end
end
