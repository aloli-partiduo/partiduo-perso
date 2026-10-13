# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Opérations récurrentes et échéancier (D7, D-PER-010, D-PER-011) :
  # échéances tirées des modèles et des tableaux d'amortissement, solde
  # prévisionnel de chaque compte calculé à l'affichage — aucune tâche
  # planifiée n'écrit d'opération. Interne.
  module Schedule
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError
    alias Actor = Partiduo::Api::Actor

    # Retard signalé : les échéances passées non confirmées des 90 derniers
    # jours.
    OVERDUE_DAYS = 90

    # Écart de jours admis entre une échéance et l'écriture importée qui la
    # règle ; écart de montant admis pour un montant estimé (en %).
    MATCH_DAYS       = 10
    ESTIMATE_PERCENT = BigDecimal.new(20)

    MAX_OCCURRENCES = 2000

    # Dates prévues d'une opération récurrente dans `[from, to]`.
    def self.dates(row : Recurring, from : Time, to : Time) : Array(Time)
      first = row.first_on!
      last = row.last_on
      stop = last && last < to ? last : to
      list = [] of Time
      index = 0
      loop do
        date = step(row, first, index)
        break if date > stop || index > MAX_OCCURRENCES
        list << date if date >= from
        index += 1
      end
      list
    end

    private def self.step(row : Recurring, first : Time, index : Int32) : Time
      case row.frequency
      when "quarterly" then Calendar.add_months(first, index * 3)
      when "yearly"    then Calendar.add_months(first, index * 12)
      when "days"      then first + (index * (row.interval_days || 1).to_i32).days
      else                  Calendar.add_months(first, index)
      end
    end

    # Date effective d'une échéance : reportée au jour ouvré suivant si
    # demandé.
    def self.effective(row : Recurring, due_on : Time, regime : String) : Time
      row.business_days ? Calendar.next_business_day(due_on, regime) : due_on
    end

    # Prochaine échéance non traitée à partir du jour.
    def self.next_due(row : Recurring, today : Time = Calendar.today) : Time?
      done = Occurrence.filter(recurring_id: row.id).to_a.map(&.due_on!).to_set
      dates(row, today, today + 800.days).find { |date| !done.includes?(date) }
    end

    # Montant signé d'une opération récurrente pour son compte.
    def self.signed(row : Recurring, amount : BigDecimal = row.amount!) : BigDecimal
      row.kind == "income" ? amount : -amount
    end

    # --- Vues ---------------------------------------------------------------------------

    def self.recurring_view(row : Recurring, accounts : Hash(Int64, Account), categories : Hash(Int64, String)) : Api::RecurringView
      Api::RecurringView.new(
        id: row.id!.to_i64, account_id: row.account_id!.to_i64, account_label: accounts[row.account_id!.to_i64]?.try(&.label.to_s) || "",
        kind: row.kind.to_s, category_id: row.category_id.try(&.to_i64),
        category_label: row.category_id.try { |id| categories[id.to_i64]? }, to_account_id: row.to_account_id.try(&.to_i64),
        to_account_label: row.to_account_id.try { |id| accounts[id.to_i64]?.try(&.label.to_s) }, payee: row.payee.to_s,
        amount: row.amount!, estimated: row.estimated!, frequency: row.frequency.to_s,
        interval_days: row.interval_days.try(&.to_i32), first_on: row.first_on!, last_on: row.last_on,
        business_days: row.business_days!, member_id: row.member_id.try(&.to_i64), active: row.active!,
        next_due_on: row.active ? next_due(row) : nil)
    end

    def self.category_labels : Hash(Int64, String)
      Categories.labels_by_account.values.to_h { |(id, label)| {id, label} }
    end

    # Effet d'une échéance sur un compte (le virement touche deux comptes).
    record Effect, account_id : Int64, date : Time, amount : BigDecimal

    # Échéancier de `from` à `to` (D7) : échéances des opérations
    # récurrentes et des emprunts des comptes visibles, retards des 90
    # derniers jours, soldes prévisionnels des comptes de trésorerie.
    def self.build(actor : Actor, from : Time, to : Time, today : Time = Calendar.today) : Api::ScheduleView
      builder = Builder.new(Records.visible_accounts(actor).to_h { |(row, _)| {row.id!.to_i64, row} }, from, to, today)
      Recurring.filter(active: true).order(:id).each { |row| builder.add_recurring(row) }
      Loan.all.order(:id).each { |loan| builder.add_loan(loan) }
      dues = builder.dues.sort_by! { |due| {due.date, due.account_label, due.label} }
      Api::ScheduleView.new(date_from: from, date_to: to, dues: dues, balances: balances(builder.visible, builder.effects, today, to))
    end

    # Échéances d'une période et leurs effets sur les soldes ; les
    # échéances passées avant la période ne sont gardées qu'en retard.
    class Builder
      getter visible : Hash(Int64, Account)
      getter dues = [] of Api::DueView
      getter effects = [] of Effect
      @regime : String
      @categories : Hash(Int64, String)
      @window : Time

      def initialize(@visible : Hash(Int64, Account), @from : Time, @to : Time, @today : Time)
        @regime = Records.regime
        @categories = Schedule.category_labels
        @window = Math.min(@from, @today - OVERDUE_DAYS.days)
      end

      def add_recurring(row : Recurring) : Nil
        account = @visible[row.account_id!.to_i64]? || return
        target = row.to_account_id.try { |id| @visible[id.to_i64]? }
        done = Occurrence.filter(recurring_id: row.id).to_a.index_by(&.due_on!)
        label = if row.kind == "transfer"
                  I18n.t("perso.labels.transfer", label: target.try(&.label.to_s) || "")
                else
                  @categories[row.category_id.try(&.to_i64) || 0_i64]? || ""
                end
        Schedule.dates(row, @window, @to).each do |due_on|
          occurrence = done[due_on]?
          status = occurrence.try(&.status.to_s) || state(due_on)
          next if skipped?(due_on, status)
          date = Schedule.effective(row, due_on, @regime)
          amount = occurrence.try(&.amount) || row.amount!
          dues << Api::DueView.new(due_on: due_on, date: date, account_id: account.id!.to_i64, account_label: account.label.to_s,
            label: row.payee.to_s, category_label: label, amount: Schedule.signed(row, amount), status: status,
            estimated: row.estimated!, recurring_id: row.id!.to_i64, entry_id: occurrence.try(&.entry_id.try(&.to_i64)))
          next unless status.in?("upcoming", "overdue")
          effects << Effect.new(account.id!.to_i64, date, Schedule.signed(row, amount))
          effects << Effect.new(target.id!.to_i64, date, amount) if target
        end
      end

      def add_loan(loan : Loan) : Nil
        payment = @visible[loan.payment_account_id!.to_i64]? || return
        label = @visible[loan.account_id!.to_i64]?.try(&.label.to_s) || ""
        confirmed = Loans.confirmed(loan)
        Loans.lines(loan).each do |line|
          row = line.row
          next unless @window <= row.due_on <= @to
          status = Loans.status(row.due_on, confirmed, @today)
          next if skipped?(row.due_on, status)
          total = Math.max(row.capital, BigDecimal.new(0)) + (row.capital < 0 ? BigDecimal.new(0) : row.interest) + row.insurance
          dues << Api::DueView.new(due_on: row.due_on, date: row.due_on, account_id: payment.id!.to_i64,
            account_label: payment.label.to_s, label: I18n.t("perso.labels.installment", label: label, number: row.index.to_s),
            category_label: I18n.t("perso.labels.loan"), amount: -total, status: status, estimated: false,
            loan_id: loan.id!.to_i64, entry_id: confirmed[row.due_on]?.try(&.entry_id.try(&.to_i64)))
          effects << Effect.new(payment.id!.to_i64, row.due_on, -total) if status.in?("upcoming", "overdue")
        end
      end

      private def state(due_on : Time) : String
        due_on < @today ? "overdue" : "upcoming"
      end

      private def skipped?(due_on : Time, status : String) : Bool
        due_on < @from && status != "overdue"
      end
    end

    # Soldes prévisionnels des comptes de trésorerie : solde du jour, puis
    # chaque échéance non traitée jusqu'à la fin de la période (les retards
    # comptent au jour même).
    private def self.balances(visible : Hash(Int64, Account), effects : Array(Effect), today : Time, to : Time) : Array(Api::BalanceForecastView)
      visible.values.select { |row| Api::CASH_NATURES.includes?(row.nature) && !row.closed }.map do |row|
        id = row.id!.to_i64
        balance = Accounts.balance(row, today)
        running = balance
        lowest = balance
        lowest_on = today
        effects.select { |effect| effect.account_id == id && effect.date <= to }
          .sort_by! { |effect| Math.max(effect.date, today) }
          .each do |effect|
            running += effect.amount
            if running < lowest
              lowest = running
              lowest_on = Math.max(effect.date, today)
            end
          end
        Api::BalanceForecastView.new(id, row.label.to_s, balance, running, lowest, lowest_on)
      end
    end

    # --- Contrôles et commandes -------------------------------------------------------

    def self.errors(actor : Actor, input : Api::RecurringInput) : Array(FieldError)
      errors = [] of FieldError
      Records.writable_account(actor, input.account_id, "account_id", errors)
      errors << Records.error("kind", "operation.kind.invalid") unless Api::OPERATION_KINDS.includes?(input.kind)
      model_errors(input, errors)
      if input.kind == "transfer"
        if target = Records.writable_account(actor, input.to_account_id, "to_account_id", errors)
          errors << Records.error("to_account_id", "operation.transfer.same_account") if target.id == input.account_id
        end
      else
        category = input.category_id.try { |id| Category.filter(id: id).first }
        Categories.posting_error(category, input.kind == "income" ? "income" : "expense").try do |key|
          errors << Records.error("category_id", key)
        end
      end
      if (member_id = input.member_id) && !Member.filter(id: member_id).exists?
        errors << Records.error("member_id", "operation.member.invalid")
      end
      errors
    end

    # Bénéficiaire, montant, fréquence et intervalle, dates.
    private def self.model_errors(input : Api::RecurringInput, errors : Array(FieldError)) : Nil
      payee = input.payee.strip
      errors << Records.error("payee", "recurring.payee.blank") if payee.empty?
      errors << Records.error("payee", "operation.payee.too_long", {"max" => Operations::MAX_PAYEE.to_s}) if payee.size > Operations::MAX_PAYEE
      errors << Records.error("amount", "operation.amount.positive") unless input.amount > 0
      errors << Records.error("frequency", "recurring.frequency.invalid") unless Api::FREQUENCIES.includes?(input.frequency)
      days = input.interval_days
      if input.frequency == "days" && !(days && 1 <= days <= 366)
        errors << Records.error("interval_days", "recurring.interval.invalid")
      end
      if (last = input.last_on) && last < input.first_on
        errors << Records.error("last_on", "recurring.last_on.before")
      end
    end

    def self.apply(row : Recurring, input : Api::RecurringInput) : Recurring
      row.account_id = input.account_id
      row.kind = input.kind
      row.category_id = input.kind == "transfer" ? nil : input.category_id
      row.to_account_id = input.kind == "transfer" ? input.to_account_id : nil
      row.payee = input.payee.strip
      row.amount = Records.cents(input.amount)
      row.estimated = input.estimated
      row.frequency = input.frequency
      row.interval_days = input.frequency == "days" ? input.interval_days : nil
      row.first_on = Calendar.day(input.first_on)
      row.last_on = input.last_on.try { |day| Calendar.day(day) }
      row.business_days = input.business_days
      row.member_id = input.member_id
      row.active = input.active
      row
    end

    # Confirme une échéance (D7) : l'opération est passée, l'échéance la
    # garde.
    def self.confirm(actor : Actor, row : Recurring, input : Api::ConfirmInput) : {Operation?, Array(FieldError)}
      due_on = Calendar.day(input.due_on)
      unless dates(row, due_on, due_on).includes?(due_on)
        return {nil, [Records.error("due_on", "recurring.due.unknown")]}
      end
      if Occurrence.filter(recurring_id: row.id, due_on: due_on).exists?
        return {nil, [Records.error("due_on", "recurring.due.done")]}
      end
      amount = input.amount || row.amount!
      date = input.date || effective(row, due_on, Records.regime)
      operation, errors = Operations.record(actor, Api::OperationInput.new(
        account_id: row.account_id!.to_i64, date: date, amount: amount, kind: row.kind.to_s,
        category_id: row.category_id.try(&.to_i64), to_account_id: row.to_account_id.try(&.to_i64), payee: row.payee.to_s,
        member_id: row.member_id.try(&.to_i64)))
      return {nil, errors} if operation.nil?
      Occurrence.create!(recurring_id: row.id, due_on: due_on, status: "confirmed", entry_id: operation.entry_id,
        amount: Records.cents(amount), created_by_id: actor.user_id)
      {operation, [] of FieldError}
    end

    def self.skip(actor : Actor, row : Recurring, due_on : Time) : Array(FieldError)
      due_on = Calendar.day(due_on)
      return [Records.error("due_on", "recurring.due.unknown")] unless dates(row, due_on, due_on).includes?(due_on)
      return [Records.error("due_on", "recurring.due.done")] if Occurrence.filter(recurring_id: row.id, due_on: due_on).exists?
      Occurrence.create!(recurring_id: row.id, due_on: due_on, status: "skipped", created_by_id: actor.user_id)
      [] of FieldError
    end

    # Écriture transférée d'un relevé (D-PER-011) : rapproche l'échéance
    # non traitée la plus proche d'une opération récurrente du même compte,
    # de même contrepartie et de même montant (à 20 % près pour un montant
    # estimé).
    def self.match(entry : Acc::EntryView, account : Account, amount : BigDecimal, counterparts : Set(String)) : Bool
      categories = Category.all.to_a.to_h { |row| {row.id!.to_i64, row.account.to_s} }
      accounts = Account.all.to_a.to_h { |row| {row.id!.to_i64, row.account_number.to_s} }
      transit = Operations.transit_account
      best = nil
      Recurring.filter(account_id: account.id, active: true).each do |row|
        target = if row.kind == "transfer"
                   [row.to_account_id.try { |id| accounts[id.to_i64]? }, transit].compact
                 else
                   [row.category_id.try { |id| categories[id.to_i64]? }].compact
                 end
        next unless target.any? { |number| counterparts.includes?(number) }
        expected = signed(row)
        next unless expected.sign == amount.sign
        unless amount == expected || (row.estimated && (amount - expected).abs * 100 <= expected.abs * ESTIMATE_PERCENT)
          next
        end
        done = Occurrence.filter(recurring_id: row.id).to_a.map(&.due_on!).to_set
        dates(row, entry.date - MATCH_DAYS.days, entry.date + MATCH_DAYS.days).each do |due_on|
          next if done.includes?(due_on)
          gap = (due_on - entry.date).abs
          best = {row, due_on, gap} if best.nil? || gap < best[2]
        end
      end
      found = best || return false
      Occurrence.create!(recurring_id: found[0].id, due_on: found[1], status: "matched", entry_id: entry.id,
        amount: Records.cents(amount.abs), created_by_id: entry.created_by_id)
      true
    end
  end
end
