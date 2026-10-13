# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Api
    # --- Opérations récurrentes (D7) ---------------------------------------------------

    def self.recurrings(actor : Actor) : Array(RecurringView)
      authorize!(actor, READ)
      visible = Records.visible_accounts(actor).to_h { |(row, _)| {row.id!.to_i64, row} }
      labels = Schedule.category_labels
      Recurring.all.order(:payee, :id).to_a.select { |row| visible.has_key?(row.account_id!.to_i64) }
        .map { |row| Schedule.recurring_view(row, visible, labels) }
    end

    def self.recurring(actor : Actor, id : Int64) : RecurringView
      authorize!(actor, READ)
      row = Records.recurring!(id)
      Records.account!(actor, row.account_id!.to_i64)
      Schedule.recurring_view(row, Account.all.to_a.index_by(&.id!.to_i64), Schedule.category_labels)
    end

    def self.save_recurring(actor : Actor, input : RecurringInput, id : Int64? = nil) : Result(RecurringView)
      authorize!(actor, WRITE)
      errors = Schedule.errors(actor, input)
      return Result(RecurringView).failure(errors) unless errors.empty?
      Transaction.run do
        row = if id
                found = Records.recurring!(id)
                Records.account!(actor, found.account_id!.to_i64)
                found
              else
                Recurring.new(created_by_id: actor.user_id)
              end
        Schedule.apply(row, input).save!
        Result(RecurringView).success(Schedule.recurring_view(row, Account.all.to_a.index_by(&.id!.to_i64), Schedule.category_labels))
      end
    end

    # Supprime une opération récurrente ; les opérations déjà passées
    # restent.
    def self.delete_recurring(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, WRITE)
      Transaction.run do
        row = Records.recurring!(id)
        Records.account!(actor, row.account_id!.to_i64)
        row.delete
        Result(Nil).success(nil)
      end
    end

    # --- Échéancier (D7) ------------------------------------------------------------------

    # Échéances de `from` à `to` et soldes prévisionnels ; retards des 90
    # derniers jours signalés. Calculé à l'affichage. Exige aussi
    # `accounting.entry.read` (soldes).
    def self.schedule(actor : Actor, from : Time, to : Time) : ScheduleView
      authorize!(actor, READ)
      Schedule.build(actor, Calendar.day(from), Calendar.day(to))
    end

    # Confirme une échéance d'opération récurrente : l'opération est passée
    # (D7). Mêmes droits du cœur que `record_operation`.
    def self.confirm_due(actor : Actor, input : ConfirmInput) : Result(OperationView)
      authorize!(actor, WRITE)
      Transaction.run do
        row = Records.recurring!(input.recurring_id)
        Records.account!(actor, row.account_id!.to_i64)
        operation, errors = Schedule.confirm(actor, row, input)
        next Result(OperationView).failure(errors) if operation.nil?
        Result(OperationView).success(present(actor, operation.entry_id!.to_i64))
      end
    end

    # Écarte une échéance (pas d'opération cette fois-ci).
    def self.skip_due(actor : Actor, recurring_id : Int64, due_on : Time) : Result(Nil)
      authorize!(actor, WRITE)
      Transaction.run do
        row = Records.recurring!(recurring_id)
        Records.account!(actor, row.account_id!.to_i64)
        errors = Schedule.skip(actor, row, due_on)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end
    end

    # Rend à traiter une échéance écartée ou rapprochée à tort (l'écriture
    # rapprochée reste).
    def self.reopen_due(actor : Actor, recurring_id : Int64, due_on : Time) : Result(Nil)
      authorize!(actor, WRITE)
      Transaction.run do
        row = Records.recurring!(recurring_id)
        Records.account!(actor, row.account_id!.to_i64)
        occurrence = Occurrence.filter(recurring_id: row.id, due_on: Calendar.day(due_on)).first
        if occurrence.nil? || occurrence.status == "confirmed"
          next Result(Nil).failure(Records.error("due_on", "recurring.due.not_reopenable"))
        end
        occurrence.delete
        Result(Nil).success(nil)
      end
    end

    # --- Emprunts (D5) ---------------------------------------------------------------------

    def self.loans(actor : Actor) : Array(LoanView)
      authorize!(actor, READ)
      visible = Records.visible_accounts(actor).map(&.[0].id!.to_i64).to_set
      Loan.all.order(:id).to_a.select { |loan| visible.includes?(loan.account_id!.to_i64) }.map { |loan| Loans.view(loan) }
    end

    def self.loan(actor : Actor, id : Int64) : LoanView
      authorize!(actor, READ)
      loan = Records.loan!(id)
      Records.account!(actor, loan.account_id!.to_i64)
      Loans.view(loan)
    end

    # Tableau d'une saisie non enregistrée (aperçu de l'écran).
    def self.preview_loan(actor : Actor, input : LoanInput) : Result(Array(LoanRowView))
      authorize!(actor, READ)
      errors = Loans.errors(actor, input).select(&.field.in?("principal", "annual_rate", "months", "deferral_kind",
        "deferral_months", "insurance_mode", "insurance_value"))
      return Result(Array(LoanRowView)).failure(errors) unless errors.empty?
      terms = Amortization::Terms.new(principal: input.principal, initial_principal: input.principal,
        annual_rate: input.annual_rate, months: input.months, first_due_on: Calendar.day(input.first_due_on),
        deferral_months: input.deferral_months, deferral_kind: input.deferral_kind, insurance_mode: input.insurance_mode,
        insurance_value: input.insurance_value)
      rows = Amortization.rows(terms).map do |row|
        LoanRowView.new(row.index, row.due_on, row.capital, row.interest, row.insurance, row.remaining, "upcoming")
      end
      Result(Array(LoanRowView)).success(rows)
    end

    # Rattache un emprunt à un compte de dette (D5) : sa première version
    # du tableau d'amortissement.
    def self.create_loan(actor : Actor, input : LoanInput) : Result(LoanView)
      authorize!(actor, ADMIN)
      errors = Loans.errors(actor, input)
      return Result(LoanView).failure(errors) unless errors.empty?
      Transaction.run { Result(LoanView).success(Loans.view(Loans.create(actor, input))) }
    end

    # Remboursement anticipé, partiel ou total (D5) : nouvelle version du
    # tableau à partir de sa date, les précédentes gardées ; le virement du
    # compte payeur vers l'emprunt est passé si demandé.
    def self.prepay_loan(actor : Actor, id : Int64, input : PrepaymentInput) : Result(LoanView)
      authorize!(actor, ADMIN)
      Transaction.run do
        loan = Records.loan!(id)
        Records.account!(actor, loan.account_id!.to_i64)
        version, errors = Loans.prepay(actor, loan, input)
        next Result(LoanView).failure(errors) if version.nil?
        if input.record_operation
          _row, failures = Operations.record(actor, OperationInput.new(account_id: loan.payment_account_id!.to_i64,
            date: input.date, amount: input.amount, kind: "transfer", to_account_id: loan.account_id!.to_i64,
            payee: I18n.t("perso.labels.prepayment")))
          next Result(LoanView).failure(failures) unless failures.empty?
        end
        Result(LoanView).success(Loans.view(loan))
      end
    end

    # Confirme une échéance d'emprunt (D7) : règlement sur le compte payeur,
    # diminution de la dette sur le compte de l'emprunt.
    def self.confirm_installment(actor : Actor, id : Int64, due_on : Time, date : Time? = nil) : Result(LoanView)
      authorize!(actor, WRITE)
      Transaction.run do
        loan = Records.loan!(id)
        Records.account!(actor, loan.account_id!.to_i64)
        errors = Loans.confirm(actor, loan, due_on, date)
        next Result(LoanView).failure(errors) unless errors.empty?
        Result(LoanView).success(Loans.view(loan))
      end
    end
  end
end
