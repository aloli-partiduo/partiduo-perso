# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Comptes du foyer (D5, D-PER-006) : un journal financier de la
  # Comptabilité adossé à un compte de bilan par sa fiche Banque, créés par
  # le contrat (`create_account`, `Cards.create_card`, `create_ledger`). Le
  # solde est toujours lu dans la Comptabilité. Interne.
  module Accounts
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError

    # Compte de base de chaque nature, par régime (plans réduits du foyer,
    # ADR-011 A3) ; un bien selon son genre. Le PEA n'existe qu'en France.
    BASES = {
      "fr" => {"current" => "512", "savings" => "514", "life_insurance" => "2711", "pea" => "2712",
               "securities" => "2713", "mortgage" => "164", "other_debt" => "168",
               "residence" => "213", "real_estate" => "214", "vehicle" => "2182", "other" => "2188"},
      "be" => {"current" => "550", "savings" => "551", "life_insurance" => "2811", "securities" => "2813",
               "mortgage" => "173", "other_debt" => "174",
               "residence" => "221", "real_estate" => "222", "vehicle" => "241", "other" => "240"},
    }

    # Patrimoine d'ouverture, contrepartie d'un solde d'ouverture.
    OPENING_ACCOUNT = "10"

    MAX_LABEL = 120

    def self.base(nature : String, asset_kind : String, regime : String = Records.regime) : String?
      bases = BASES[regime]? || BASES["fr"]
      bases[nature == "property" ? asset_kind : nature]?
    end

    # --- Solde et valeur --------------------------------------------------------------

    # Solde au jour `as_of` lu dans la Comptabilité (débit − crédit) : positif
    # pour un avoir ; pour une dette, on rend le capital dû (crédit − débit).
    def self.balance(row : Account, as_of : Time? = nil) : BigDecimal
      statement = Acc.account_statement(Records.system, Acc::StatementQuery.new(account: row.account_number.to_s,
        date_to: as_of))
      Api::DEBT_NATURES.includes?(row.nature) ? -statement.balance : statement.balance
    rescue Partiduo::Api::NotFound
      Records::ZERO
    end

    # Valeur au patrimoine (D9) : capital restant dû d'un emprunt tenu par
    # l'extension, dernière valorisation d'un placement ou d'un bien, sinon
    # le solde.
    def self.value(row : Account, balance : BigDecimal, as_of : Time) : BigDecimal
      if Api::DEBT_NATURES.includes?(row.nature)
        if loan = Loan.filter(account_id: row.id).first
          return Loans.remaining(loan, as_of)
        end
        return balance
      end
      if row.nature.in?(Api::INVESTMENT_NATURES) || row.nature == "property"
        latest = Valuation.filter(account_id: row.id, valued_on__lte: as_of).order("-valued_on").first
        return latest.amount! if latest
      end
      balance
    end

    def self.view(row : Account, ledger : Acc::LedgerView, holders : Hash(Int64, Array(Api::MemberView)),
                  as_of : Time = Calendar.today) : Api::AccountView
      balance = balance(row, as_of)
      id = row.id!.to_i64
      last = Valuation.filter(account_id: id).order("-valued_on").first
      Api::AccountView.new(
        id: id, ledger_id: ledger.id, ledger_code: ledger.code, nature: row.nature.to_s, asset_kind: row.asset_kind.to_s,
        label: row.label.to_s, institution: row.institution.to_s, rate: row.rate, ceiling: row.ceiling,
        opened_on: row.opened_on, closed: row.closed!, position: row.position!.to_i32, balance: balance,
        value: value(row, balance, as_of), holders: holders[id]? || [] of Api::MemberView,
        writable: ledger.access.writable?, loan_id: Loan.filter(account_id: id).first.try(&.id!.to_i64),
        last_valued_on: last.try(&.valued_on))
    end

    # Titulaires de tous les comptes, par compte.
    def self.holders : Hash(Int64, Array(Api::MemberView))
      members = Member.all.to_a.index_by(&.id!.to_i64)
      AccountHolder.all.to_a.group_by(&.account_id!.to_i64).transform_values do |links|
        links.compact_map { |link| members[link.member_id!.to_i64]?.try { |member| Records.member_view(member) } }
      end
    end

    def self.views(actor : Partiduo::Api::Actor, as_of : Time = Calendar.today) : Array(Api::AccountView)
      links = holders
      Records.visible_accounts(actor).map { |(row, ledger)| view(row, ledger, links, as_of) }
    end

    # --- Contrôles --------------------------------------------------------------------

    def self.errors(input : Api::AccountInput | Api::AccountUpdateInput, nature : String) : Array(FieldError)
      errors = [] of FieldError
      label = input.label.strip
      if label.empty?
        errors << Records.error("label", "account.label.blank")
      elsif label.size > MAX_LABEL
        errors << Records.error("label", "account.label.too_long", {"max" => MAX_LABEL.to_s})
      end
      errors << Records.error("institution", "account.institution.too_long") if input.institution.size > MAX_LABEL
      if nature == "property"
        errors << Records.error("asset_kind", "account.asset_kind.invalid") unless Api::ASSET_KINDS.includes?(input.asset_kind)
      elsif !input.asset_kind.empty?
        errors << Records.error("asset_kind", "account.asset_kind.not_property")
      end
      input.rate.try { |rate| errors << Records.error("rate", "account.rate.invalid") if rate < 0 || rate >= 100 }
      input.ceiling.try { |ceiling| errors << Records.error("ceiling", "account.ceiling.invalid") if ceiling <= 0 }
      input.holder_ids.each do |member_id|
        errors << Records.error("holder_ids", "account.holder.invalid") unless Member.filter(id: member_id).exists?
      end
      errors
    end

    # --- Création ---------------------------------------------------------------------

    # Crée un compte du foyer : reprend un journal financier existant, ou
    # crée (au besoin) le compte de bilan, sa fiche Banque et son journal ;
    # passe le solde d'ouverture. Rend le compte ou les erreurs.
    def self.create(actor : Partiduo::Api::Actor, input : Api::AccountInput) : {Account?, Array(FieldError)}
      errors = errors(input, input.nature)
      errors << Records.error("nature", "account.nature.invalid") unless Api::NATURES.includes?(input.nature)
      return {nil, errors} unless errors.empty?

      ledger_id, number, card_code = if existing = input.ledger_id
                                       adopt_ledger(actor, existing, errors)
                                     else
                                       new_ledger(actor, input, errors)
                                     end
      return {nil, errors} unless errors.empty? && ledger_id && number

      row = Account.new(ledger_id: ledger_id, account_number: number, card_code: card_code, nature: input.nature,
        asset_kind: input.nature == "property" ? input.asset_kind : "", label: input.label.strip,
        institution: input.institution.strip, rate: input.rate.try { |rate| Records.round(rate, 4) }, ceiling: input.ceiling.try { |ceiling| Records.cents(ceiling) },
        opened_on: input.opened_on.try { |day| Calendar.day(day) }, closed: false, position: input.position)
      row.save!
      set_holders(row, input.holder_ids)
      if (amount = input.opening_balance) && !amount.zero?
        opening = opening_entry(actor, row, amount, input.opened_on || Calendar.today)
        return {nil, opening} unless opening.empty?
      end
      {row, [] of FieldError}
    end

    def self.set_holders(row : Account, member_ids : Array(Int64)) : Nil
      AccountHolder.filter(account_id: row.id).delete
      member_ids.uniq.each { |member_id| AccountHolder.create!(account_id: row.id, member_id: member_id) }
    end

    # Journal financier existant, non encore repris par l'extension.
    private def self.adopt_ledger(actor : Partiduo::Api::Actor, id : Int64, errors : Array(FieldError)) : {Int64?, String?, String}
      ledger = begin
        Acc.ledger(actor, id)
      rescue Partiduo::Api::NotFound
        errors << Records.error("ledger_id", "account.ledger.invalid")
        return {nil, nil, ""}
      end
      unless ledger.kind.financial?
        errors << Records.error("ledger_id", "account.ledger.not_financial")
        return {nil, nil, ""}
      end
      if Account.filter(ledger_id: id).exists?
        errors << Records.error("ledger_id", "account.ledger.taken")
        return {nil, nil, ""}
      end
      number = ledger.default_account.try(&.number)
      if number.nil?
        errors << Records.error("ledger_id", "account.ledger.not_financial")
        return {nil, nil, ""}
      end
      if Account.filter(account_number: number).exists?
        errors << Records.error("ledger_id", "account.number.taken")
        return {nil, nil, ""}
      end
      {ledger.id, number, ledger.bank_card_code || ""}
    end

    # Compte de bilan (repris ou créé sous la base de la nature), fiche
    # Banque qui le porte, journal financier.
    private def self.new_ledger(actor : Partiduo::Api::Actor, input : Api::AccountInput,
                                errors : Array(FieldError)) : {Int64?, String?, String}
      base = base(input.nature, input.asset_kind)
      if base.nil?
        errors << Records.error("nature", "account.nature.unavailable")
        return {nil, nil, ""}
      end
      number = input.account_number.try(&.strip).presence
      if number
        number = Partiduo::Api::Accounting.account(actor, number).number rescue nil
        if number.nil?
          errors << Records.error("account_number", "account.number.invalid")
          return {nil, nil, ""}
        end
        if Account.filter(account_number: number).exists?
          errors << Records.error("account_number", "account.number.taken")
          return {nil, nil, ""}
        end
      else
        number = next_number(base)
        result = Acc.create_account(actor, Acc::AccountInput.new(number: number, label: input.label.strip, parent: base,
          direct_use: true))
        if result.failure?
          errors.concat(result.errors)
          return {nil, nil, ""}
        end
      end

      category = Partiduo::Api::Cards.category_by_code(actor, "BANK")
      if category.nil?
        errors << Records.error("nature", "account.bank_category.missing")
        return {nil, nil, ""}
      end
      card = Partiduo::Api::Cards.create_card(actor, Partiduo::Api::Cards::CardInput.new(category_id: category.id,
        name: input.label.strip, description: input.institution.strip.presence), account: number)
      if card.failure?
        errors.concat(card.errors.map { |error| FieldError.new("label", error.key, error.params) })
        return {nil, nil, ""}
      end
      ledger = Acc.create_ledger(actor, Acc::LedgerInput.new(name: ledger_name(input.label.strip), kind: Acc::LedgerKind::Financial,
        bank_card: card.value!.code, receipt_prefix: "P-", receipt_padding: 5))
      if ledger.failure?
        errors.concat(ledger.errors.map { |error| FieldError.new("label", error.key, error.params) })
        return {nil, nil, ""}
      end
      {ledger.value!.id, number, card.value!.code}
    end

    # Nom de journal libre : le libellé du compte, suivi d'un rang s'il est
    # déjà pris (les noms des journaux sont uniques).
    private def self.ledger_name(label : String) : String
      taken = Acc.ledgers(Records.system).map(&.name.downcase).to_set
      return label unless taken.includes?(label.downcase)
      (2..999).each do |index|
        name = "#{label} (#{index})"
        return name unless taken.includes?(name.downcase)
      end
      "#{label} (#{Random::Secure.hex(3)})"
    end

    # Premier numéro libre sous la base : trois chiffres de plus
    # (`514001`, `2711001`).
    private def self.next_number(base : String) : String
      (1..999).each do |index|
        number = "#{base}#{index.to_s.rjust(3, '0')}"
        exists = begin
          Acc.account(Records.system, number)
          true
        rescue Partiduo::Api::NotFound
          false
        end
        return number unless exists
      end
      "#{base}#{Random::Secure.hex(3).upcase}"
    end

    # Solde d'ouverture (D-PER-006) : écriture d'opérations diverses contre
    # le patrimoine d'ouverture, dans le premier journal d'opérations
    # diverses ouvert à l'acteur.
    def self.opening_entry(actor : Partiduo::Api::Actor, row : Account, amount : BigDecimal, date : Time) : Array(FieldError)
      ledger = Acc.ledgers(actor, Acc::LedgerKind::Misc, enabled_only: true).find(&.access.writable?)
      return [Records.error("opening_balance", "account.misc_ledger.missing")] if ledger.nil?
      Years.prepare(Calendar.day(date).year)
      debt = Api::DEBT_NATURES.includes?(row.nature)
      positive = debt ? amount < 0 : amount > 0
      side = positive ? Acc::Side::Debit : Acc::Side::Credit
      lines = [
        Acc::EntryLineInput.new(account: row.account_number.to_s, side: side, amount: amount.abs),
        Acc::EntryLineInput.new(account: OPENING_ACCOUNT, side: side.opposite, amount: amount.abs),
      ]
      result = Acc.post_entry(actor, Acc::EntryInput.new(ledger_id: ledger.id, date: Calendar.day(date), lines: lines,
        label: I18n.t("perso.labels.opening", label: row.label.to_s), source: "perso:opening:#{row.id}"))
      result.failure? ? result.errors.map { |error| FieldError.new("opening_balance", error.key, error.params) } : [] of FieldError
    end
  end
end
