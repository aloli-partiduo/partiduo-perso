# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Emprunts (D5, D-PER-009) : versions du tableau d'amortissement,
  # remboursement anticipé, échéances confirmées et leurs écritures.
  # Interne.
  module Loans
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError
    alias Actor = Partiduo::Api::Actor

    SOURCE = "perso:loan"

    # Écart de jours admis entre une échéance et l'écriture importée qui la
    # règle (D-PER-011).
    MATCH_DAYS = 10

    # Échéance du tableau complet : version qui la porte.
    record Line, version : Int32, row : Amortization::Row

    def self.terms(version : LoanVersion) : Amortization::Terms
      Amortization::Terms.new(
        principal: version.principal!, initial_principal: version.initial_principal!, annual_rate: version.annual_rate!,
        months: version.months!.to_i32, first_due_on: version.first_due_on!, deferral_months: version.deferral_months!.to_i32,
        deferral_kind: version.deferral_kind.to_s, insurance_mode: version.insurance_mode.to_s,
        insurance_value: version.insurance_value || BigDecimal.new(0))
    end

    def self.versions(loan : Loan) : Array(LoanVersion)
      LoanVersion.filter(loan_id: loan.id).order(:number).to_a
    end

    def self.current(loan : Loan) : LoanVersion
      LoanVersion.filter(loan_id: loan.id).order("-number").first || raise Partiduo::Api::NotFound.new("perso_loan", loan.id)
    end

    # Tableau complet : les échéances de chaque version antérieures à la
    # version suivante, puis celles de la version en vigueur ; numérotées à
    # la suite.
    def self.lines(loan : Loan) : Array(Line)
      list = versions(loan)
      lines = [] of Line
      list.each_with_index do |version, index|
        following = list[index + 1]?
        Amortization.rows(terms(version)).each do |row|
          next if following && row.due_on > following.effective_on!
          lines << Line.new(version.number!.to_i32, row)
        end
      end
      lines.map_with_index do |line, index|
        Line.new(line.version, line.row.copy_with(index: index + 1))
      end
    end

    # Capital restant dû au jour `as_of` : après la dernière échéance passée,
    # ou le capital emprunté avant la première ; après un remboursement
    # anticipé, le capital de la version qui le constate.
    def self.remaining(loan : Loan, as_of : Time) : BigDecimal
      list = versions(loan)
      return BigDecimal.new(0) if list.empty?
      version = list.reverse.find { |item| item.effective_on! <= as_of } || list.first
      rows = lines(loan).select { |line| line.version == version.number && line.row.due_on <= as_of }
      return rows.last.row.remaining if rows.present?
      version.number == list.first.number ? list.first.initial_principal! : version.principal!
    end

    def self.confirmed(loan : Loan) : Hash(Time, Installment)
      Installment.filter(loan_id: loan.id).to_a.to_h { |row| {row.due_on!, row} }
    end

    def self.status(due_on : Time, confirmed : Hash(Time, Installment), today : Time) : String
      return "confirmed" if confirmed.has_key?(due_on)
      due_on < today ? "overdue" : "upcoming"
    end

    # --- Vues ---------------------------------------------------------------------------

    def self.version_view(row : LoanVersion) : Api::LoanVersionView
      Api::LoanVersionView.new(
        number: row.number!.to_i32, effective_on: row.effective_on!, reason: row.reason.to_s, principal: row.principal!,
        initial_principal: row.initial_principal!, annual_rate: row.annual_rate!, months: row.months!.to_i32,
        first_due_on: row.first_due_on!, deferral_months: row.deferral_months!.to_i32, deferral_kind: row.deferral_kind.to_s,
        insurance_mode: row.insurance_mode.to_s, insurance_value: row.insurance_value || BigDecimal.new(0),
        prepayment: row.prepayment, prepayment_mode: row.prepayment_mode.to_s, created_at: row.created_at || Time.utc)
    end

    def self.view(loan : Loan, today : Time = Calendar.today) : Api::LoanView
      account = Account.filter(id: loan.account_id).first!
      payment = Account.filter(id: loan.payment_account_id).first!
      confirmed = confirmed(loan)
      rows = lines(loan).map do |line|
        row = line.row
        Api::LoanRowView.new(number: row.index, due_on: row.due_on, capital: row.capital, interest: row.interest,
          insurance: row.insurance, remaining: row.remaining, status: status(row.due_on, confirmed, today))
      end
      list = versions(loan)
      Api::LoanView.new(
        id: loan.id!.to_i64, account_id: account.id!.to_i64, account_label: account.label.to_s,
        payment_account_id: payment.id!.to_i64, payment_account_label: payment.label.to_s,
        interest_category_id: loan.interest_category_id!.to_i64, insurance_category_id: loan.insurance_category_id.try(&.to_i64),
        current: version_view(list.last), versions: list.map { |item| version_view(item) }, rows: rows,
        remaining: remaining(loan, today))
    end

    # --- Contrôles ----------------------------------------------------------------------

    def self.errors(actor : Actor, input : Api::LoanInput) : Array(FieldError)
      errors = [] of FieldError
      account_errors(actor, input, errors)
      terms_errors(input, errors)
      category_error(input.interest_category_id, "interest_category_id", errors)
      if id = input.insurance_category_id
        category_error(id, "insurance_category_id", errors)
      elsif input.insurance_mode != "none"
        errors << Records.error("insurance_category_id", "loan.category.blank")
      end
      errors
    end

    # Compte de dette sans emprunt, compte payeur de trésorerie.
    private def self.account_errors(actor : Actor, input : Api::LoanInput, errors : Array(FieldError)) : Nil
      if account = Records.writable_account(actor, input.account_id, "account_id", errors)
        errors << Records.error("account_id", "loan.account.not_debt") unless Api::DEBT_NATURES.includes?(account.nature)
        errors << Records.error("account_id", "loan.account.taken") if Loan.filter(account_id: account.id).exists?
      end
      if payment = Records.writable_account(actor, input.payment_account_id, "payment_account_id", errors)
        errors << Records.error("payment_account_id", "loan.payment.not_cash") unless Api::CASH_NATURES.includes?(payment.nature)
      end
    end

    # Capital, taux, durée, différé, assurance.
    def self.terms_errors(input : Api::LoanInput, errors : Array(FieldError)) : Nil
      errors << Records.error("principal", "loan.principal.positive") unless input.principal > 0
      errors << Records.error("annual_rate", "loan.rate.invalid") unless 0 <= input.annual_rate < 100
      errors << Records.error("months", "loan.months.invalid") unless 1 <= input.months <= 600
      errors << Records.error("deferral_kind", "loan.deferral.invalid") unless Api::DEFERRAL_KINDS.includes?(input.deferral_kind)
      deferral_ok = input.deferral_kind == "none" ? input.deferral_months == 0 : 1 <= input.deferral_months < input.months
      errors << Records.error("deferral_months", "loan.deferral.months") unless deferral_ok
      errors << Records.error("insurance_mode", "loan.insurance.invalid") unless Api::INSURANCE_MODES.includes?(input.insurance_mode)
      errors << Records.error("insurance_value", "loan.insurance.value") if input.insurance_value < 0
    end

    private def self.category_error(id : Int64, field : String, errors : Array(FieldError)) : Nil
      row = Category.filter(id: id).first
      if row.nil? || row.kind != "expense" || !row.active
        errors << Records.error(field, "loan.category.invalid")
      elsif Category.filter(parent_id: row.id).exists?
        errors << Records.error(field, "operation.category.has_children")
      end
    end

    # --- Commandes ----------------------------------------------------------------------

    def self.create(actor : Actor, input : Api::LoanInput) : Loan
      loan = Loan.create!(account_id: input.account_id, payment_account_id: input.payment_account_id,
        interest_category_id: input.interest_category_id, insurance_category_id: input.insurance_category_id)
      LoanVersion.create!(loan_id: loan.id, number: 1, effective_on: Calendar.day(input.first_due_on), reason: "initial",
        principal: input.principal, initial_principal: input.principal, annual_rate: input.annual_rate, months: input.months,
        first_due_on: Calendar.day(input.first_due_on), deferral_months: input.deferral_months,
        deferral_kind: input.deferral_kind, insurance_mode: input.insurance_mode, insurance_value: input.insurance_value,
        created_by_id: actor.user_id)
      loan
    end

    # Remboursement anticipé (D5) : nouvelle version à partir de sa date —
    # capital restant après la dernière échéance passée, moins le montant ;
    # échéances suivantes recalculées (durée ou montant réduits) ; un
    # remboursement total solde l'emprunt. Rend la version, ou les erreurs.
    def self.prepay(actor : Actor, loan : Loan, input : Api::PrepaymentInput) : {LoanVersion?, Array(FieldError)}
      date = Calendar.day(input.date)
      current = current(loan)
      errors = prepayment_errors(input, date, current)
      return {nil, errors} unless errors.empty?

      all = lines(loan)
      future = all.reject { |line| line.row.due_on <= date }
      remaining = all.reverse_each.find { |line| line.row.due_on <= date }.try(&.row.remaining) || current.initial_principal!
      if future.empty? || remaining <= 0
        return {nil, [Records.error("date", "loan.prepayment.after_end")]}
      end
      if input.amount > remaining
        return {nil, [Records.error("amount", "loan.prepayment.too_much", {"remaining" => remaining.to_s})]}
      end
      left = Amortization.cents(remaining - input.amount)
      version = LoanVersion.create!(loan_id: loan.id, number: current.number!.to_i32 + 1, effective_on: date,
        reason: left.zero? ? "repaid" : "prepayment", principal: left, initial_principal: current.initial_principal!,
        annual_rate: current.annual_rate!, months: remaining_months(left, input.mode, current, future),
        first_due_on: future.first.row.due_on, deferral_months: 0, deferral_kind: "none",
        insurance_mode: current.insurance_mode.to_s, insurance_value: current.insurance_value || BigDecimal.new(0),
        prepayment: Amortization.cents(input.amount), prepayment_mode: input.mode, created_by_id: actor.user_id)
      {version, [] of FieldError}
    end

    private def self.prepayment_errors(input : Api::PrepaymentInput, date : Time, current : LoanVersion) : Array(FieldError)
      errors = [] of FieldError
      errors << Records.error("mode", "loan.prepayment.mode") unless Api::PREPAYMENT_MODES.includes?(input.mode)
      errors << Records.error("amount", "loan.prepayment.positive") unless input.amount > 0
      errors << Records.error("date", "loan.prepayment.before") if date <= current.effective_on! && current.number != 1
      errors
    end

    # Échéances restantes après un remboursement : aucune s'il solde
    # l'emprunt ; autant qu'avant pour réduire l'échéance ; sinon celles
    # qu'il faut pour rembourser le reste en gardant l'échéance.
    private def self.remaining_months(left : BigDecimal, mode : String, current : LoanVersion, future : Array(Line)) : Int32
      return 0 if left.zero?
      return future.size if mode == "installment"
      payment = future.find { |line| line.row.capital > 0 }.try { |line| line.row.capital + line.row.interest }
      return future.size if payment.nil?
      Math.min(Amortization.months_for(left, current.annual_rate!, payment), future.size)
    end

    # Confirme une échéance (D7) : sur le compte payeur, le total (capital,
    # intérêts, assurance) en une écriture — capital au compte de passage,
    # intérêts et assurance à leurs catégories ; sur le compte de l'emprunt,
    # la diminution de la dette (ou l'augmentation des intérêts capitalisés
    # d'un différé total). Rend les erreurs.
    def self.confirm(actor : Actor, loan : Loan, due_on : Time, date : Time? = nil) : Array(FieldError)
      due_on = Calendar.day(due_on)
      line = lines(loan).find { |item| item.row.due_on == due_on }
      return [Records.error("due_on", "loan.installment.unknown")] if line.nil?
      return [Records.error("due_on", "loan.installment.done")] if Installment.filter(loan_id: loan.id, due_on: due_on).exists?
      errors = [] of FieldError
      account = Records.writable_account(actor, loan.account_id!.to_i64, "account_id", errors)
      payment = Records.writable_account(actor, loan.payment_account_id!.to_i64, "payment_account_id", errors)
      return errors unless errors.empty? && account && payment
      day = Calendar.day(date || line.row.due_on)
      return [Records.error("date", "operation.date.out_of_range")] unless Years.prepare(day.year)
      posting = Posting.new(loan, line.row, account, payment, day)
      payment_entry, failure = posting.payment_entry(actor)
      return failure if failure
      loan_entry, failure = posting.debt_entry(actor)
      return failure if failure
      Installment.create!(loan_id: loan.id, due_on: due_on, version_number: line.version, entry_id: payment_entry || loan_entry,
        transfer_entry_id: payment_entry ? loan_entry : nil, created_by_id: actor.user_id)
      [] of FieldError
    end

    # Écritures d'une échéance confirmée : le règlement sur le compte payeur
    # (capital au compte de passage, intérêts et assurance à leurs
    # catégories), la variation de la dette sur le compte de l'emprunt.
    class Posting
      getter label : String
      getter capital : BigDecimal
      getter capitalized : BigDecimal
      getter interest : BigDecimal
      getter insurance : BigDecimal
      @due : String
      @transit : String
      @interest_category : Category
      @insurance_category : Category?

      def initialize(@loan : Loan, row : Amortization::Row, @account : Account, @payment : Account, @day : Time)
        @label = I18n.t("perso.labels.installment", label: @account.label.to_s, number: row.index.to_s)
        @due = row.due_on.to_s("%F")
        @capital = row.capital > 0 ? row.capital : BigDecimal.new(0)
        @capitalized = row.capital < 0 ? -row.capital : BigDecimal.new(0)
        @interest = @capitalized > 0 ? BigDecimal.new(0) : row.interest
        @insurance = row.insurance
        @transit = Operations.transit_account
        @interest_category = Records.category!(@loan.interest_category_id!.to_i64)
        @insurance_category = @loan.insurance_category_id.try { |id| Records.category!(id.to_i64) }
      end

      def total : BigDecimal
        capital + interest + insurance
      end

      def payment_entry(actor : Actor) : {Int64?, Array(FieldError)?}
        return {nil, nil} unless total > 0
        lines = [line(@payment.account_number.to_s, Acc::Side::Credit, total)]
        lines << line(@transit, Acc::Side::Debit, capital) if capital > 0
        lines << line(@interest_category.account.to_s, Acc::Side::Debit, interest) if interest > 0
        lines << line((@insurance_category || @interest_category).account.to_s, Acc::Side::Debit, insurance) if insurance > 0
        result = Acc.post_entry(actor, Acc::EntryInput.new(ledger_id: @payment.ledger_id!.to_i64, date: @day, lines: lines,
          label: label, source: source("payment")))
        result.failure? ? {nil, result.errors} : {result.value!.id, nil}
      end

      def debt_entry(actor : Actor) : {Int64?, Array(FieldError)?}
        return {nil, nil} unless capital > 0 || capitalized > 0
        counterpart = capital > 0 ? @transit : @interest_category.account.to_s
        amount = capital > 0 ? capital : -capitalized
        result = Acc.post_financial(actor, Acc::FinancialInput.new(ledger_id: @account.ledger_id!.to_i64, date: @day,
          lines: [Acc::PaymentLineInput.new(amount, account: counterpart, label: label)], source: source("debt")))
        result.failure? ? {nil, result.errors} : {result.value!.first.id, nil}
      end

      private def line(number : String, side : Acc::Side, amount : BigDecimal) : Acc::EntryLineInput
        Acc::EntryLineInput.new(account: number, side: side, amount: amount, label: label)
      end

      # Référence unique de l'écriture : l'emprunt, l'échéance, un tirage.
      private def source(part : String) : String
        "#{SOURCE}:#{@loan.id}:#{@due}:#{UUID.random.hexstring[0, 8]}:#{part}"
      end
    end

    # Écriture transférée d'un relevé sur le compte payeur, du montant total
    # d'une échéance non confirmée proche : l'échéance est rapprochée
    # (D-PER-011).
    def self.match(entry : Acc::EntryView, ledger_account : Account, amount : BigDecimal) : Bool
      return false unless amount < 0
      Loan.filter(payment_account_id: ledger_account.id).each do |loan|
        confirmed = confirmed(loan)
        candidate = lines(loan).find do |line|
          row = line.row
          !confirmed.has_key?(row.due_on) && (row.due_on - entry.date).abs <= MATCH_DAYS.days &&
            (Math.max(row.capital, BigDecimal.new(0)) + row.interest + row.insurance) == -amount
        end
        next unless candidate
        Installment.create!(loan_id: loan.id, due_on: candidate.row.due_on, version_number: candidate.version,
          entry_id: entry.id, created_by_id: entry.created_by_id)
        return true
      end
      false
    end
  end
end
