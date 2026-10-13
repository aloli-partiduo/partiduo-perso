# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Placements, valorisations et patrimoine net (D9, D-PER-014) : la
  # valorisation est une donnée de l'extension, pas une écriture ; le
  # patrimoine combine les soldes de la Comptabilité, les dernières valeurs
  # saisies et le capital restant dû des tableaux d'amortissement. Seuls
  # comptent les comptes visibles de l'acteur (D12). Interne.
  module Wealth
    alias FieldError = Partiduo::Api::FieldError
    alias Actor = Partiduo::Api::Actor

    ZERO = BigDecimal.new(0)

    MAX_LINES = 200

    def self.valuation_view(row : Valuation) : Api::ValuationView
      lines = ValuationLine.filter(valuation_id: row.id).order(:id).to_a.map do |line|
        Api::ValuationLineView.new(line.security.to_s, line.quantity!, line.price!, line.amount!)
      end
      Api::ValuationView.new(id: row.id!.to_i64, account_id: row.account_id!.to_i64, valued_on: row.valued_on!,
        amount: row.amount!, note: row.note.to_s, lines: lines, created_at: row.created_at || Time.utc)
    end

    def self.holding(account : Api::AccountView) : Api::HoldingView
      rows = Valuation.filter(account_id: account.id).order("-valued_on").to_a
      views = rows.map { |row| valuation_view(row) }
      Api::HoldingView.new(account: account, valuations: views, contributions: account.balance, latest: views.first?)
    end

    # --- Valorisations ------------------------------------------------------------------

    def self.errors(actor : Actor, input : Api::ValuationInput) : {Account?, Array(FieldError)}
      errors = [] of FieldError
      account = Records.writable_account(actor, input.account_id, "account_id", errors)
      if account && !(account.nature.in?(Api::INVESTMENT_NATURES) || account.nature == "property")
        errors << Records.error("account_id", "valuation.account.not_valued")
      end
      if input.lines.empty?
        amount = input.amount
        errors << Records.error("amount", "valuation.amount.invalid") if amount.nil? || amount < 0
      else
        if account && !account.nature.in?(Api::SECURITIES_NATURES)
          errors << Records.error("lines", "valuation.lines.not_securities")
        end
        line_errors(input.lines, errors)
      end
      errors << Records.error("note", "valuation.note.too_long") if input.note.size > 255
      if account && Valuation.filter(account_id: account.id, valued_on: Calendar.day(input.valued_on)).exists?
        errors << Records.error("valued_on", "valuation.date.taken")
      end
      {account, errors}
    end

    private def self.line_errors(lines : Array(Api::ValuationLineInput), errors : Array(FieldError)) : Nil
      errors << Records.error("lines", "valuation.lines.too_many") if lines.size > MAX_LINES
      lines.each_with_index do |line, index|
        errors << Records.error("lines[#{index}].security", "valuation.security.blank") if line.security.strip.empty?
        errors << Records.error("lines[#{index}].quantity", "valuation.quantity.positive") unless line.quantity > 0
        errors << Records.error("lines[#{index}].price", "valuation.price.invalid") if line.price < 0
      end
    end

    def self.create(actor : Actor, input : Api::ValuationInput) : Valuation
      amounts = input.lines.map { |line| Records.cents(line.quantity * line.price) }
      total = input.lines.empty? ? (input.amount || ZERO) : amounts.sum(ZERO)
      row = Valuation.create!(account_id: input.account_id, valued_on: Calendar.day(input.valued_on), amount: total,
        note: input.note.strip, created_by_id: actor.user_id)
      input.lines.each_with_index do |line, index|
        ValuationLine.create!(valuation_id: row.id, security: line.security.strip[0, 120], quantity: line.quantity,
          price: line.price, amount: amounts[index])
      end
      row
    end

    # --- Patrimoine ---------------------------------------------------------------------

    # Valeur signée d'un compte au patrimoine : une dette compte en moins.
    def self.signed(account : Api::AccountView) : BigDecimal
      account.debt? ? -account.value : account.value
    end

    def self.view(actor : Actor, today : Time = Calendar.today) : Api::WealthView
      accounts = Accounts.views(actor, today).reject { |account| account.closed && account.value.zero? }
      cash = accounts.select(&.cash?).sum(ZERO, &.value)
      investments = accounts.select(&.investment?)
      property = accounts.select(&.property?).sum(ZERO, &.value)
      debts = accounts.select(&.debt?).sum(ZERO, &.value)
      by_nature = Api::NATURES.compact_map do |nature|
        list = accounts.select(&.nature.==(nature))
        next if list.empty?
        Api::AmountView.new(nature, I18n.t("perso.natures.#{nature}"), list.sum(ZERO) { |account| signed(account) })
      end
      Api::WealthView.new(as_of: today, cash: cash, investments: investments,
        investments_total: investments.sum(ZERO, &.value), property_total: property, debts_total: debts,
        accounts: accounts, by_nature: by_nature, by_member: by_member(accounts), months: months(actor, today))
    end

    # Répartition par membre : la valeur d'un compte se partage à parts
    # égales entre ses titulaires (le reste du partage au premier) ; un
    # compte sans titulaire est au foyer.
    def self.by_member(accounts : Array(Api::AccountView)) : Array(Api::AmountView)
      totals = {} of String => {String, BigDecimal}
      household = I18n.t("perso.labels.household")
      accounts.each do |account|
        value = signed(account)
        if account.holders.empty?
          current = totals["household"]? || {household, ZERO}
          totals["household"] = {current[0], current[1] + value}
          next
        end
        share = Records.cents(value / BigDecimal.new(account.holders.size))
        account.holders.each_with_index do |holder, index|
          part = index == 0 ? value - share * (account.holders.size - 1) : share
          key = "member_#{holder.id}"
          current = totals[key]? || {holder.display_name, ZERO}
          totals[key] = {current[0], current[1] + part}
        end
      end
      totals.map { |code, (label, amount)| Api::AmountView.new(code, label, amount) }.sort_by!(&.label)
    end

    # Patrimoine net à la fin de chacun des douze derniers mois (le mois en
    # cours : au jour).
    def self.months(actor : Actor, today : Time) : Array(Api::AmountView)
      visible = Records.visible_accounts(actor)
      links = Accounts.holders
      (0..11).to_a.reverse.map do |back|
        month = Calendar.add_months(Time.utc(today.year, today.month, 1), -back)
        as_of = back == 0 ? today : Calendar.end_of_month(month)
        net = visible.sum(ZERO) do |(row, ledger)|
          next ZERO if row.opened_on.try { |day| day > as_of }
          signed(Accounts.view(row, ledger, links, as_of))
        end
        Api::AmountView.new(month.to_s("%Y-%m"), month.to_s("%Y-%m"), net)
      end
    end
  end
end
