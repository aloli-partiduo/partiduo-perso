# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Perso::SpecSupport
private alias Api = Perso::Api
private alias Am = Perso::Amortization

private def mortgage : Api::AccountView
  Api.create_account(S.parent, Api::AccountInput.new(nature: "mortgage", label: "Prêt maison",
    opening_balance: S.d("100000"), opened_on: S.date("2026-01-01"))).value!
end

private def loan_input(account : Api::AccountView, **changes) : Api::LoanInput
  input = Api::LoanInput.new(account_id: account.id, payment_account_id: S.current_account.id, principal: S.d("100000"),
    annual_rate: S.d("3.6"), months: 240, first_due_on: S.date("2026-02-05"),
    interest_category_id: S.category("Loyer ou échéance").id, insurance_category_id: S.category("Assurance habitation").id,
    insurance_mode: "initial", insurance_value: S.d("0.30"))
  input.copy_with(**changes)
end

describe "Emprunts et tableau d'amortissement (ADR-011 D5)" do
  it "calcule des échéances constantes au centime, la dernière ajustée" do
    terms = Am::Terms.new(principal: S.d("100000"), initial_principal: S.d("100000"), annual_rate: S.d("3.6"),
      months: 240, first_due_on: S.date("2026-02-05"))
    rows = Am.rows(terms)
    rows.size.should eq(240)
    first = rows.first
    first.interest.should eq(S.d("300"))
    (first.capital + first.interest).should eq(S.d("585.11"))
    rows[1].due_on.should eq(S.date("2026-03-05"))
    rows.last.remaining.should eq(S.d("0"))
    rows.sum(S.d("0"), &.capital).should eq(S.d("100000"))
    Am.installment(S.d("1200"), S.d("0"), 12).should eq(S.d("100"))
  end

  it "applique un différé partiel ou total et une assurance proportionnelle" do
    base = Am::Terms.new(principal: S.d("10000"), initial_principal: S.d("10000"), annual_rate: S.d("6"), months: 12,
      first_due_on: S.date("2026-01-31"), deferral_months: 2, deferral_kind: "partial", insurance_mode: "remaining",
      insurance_value: S.d("1.2"))
    partial = Am.rows(base)
    partial[0].capital.should eq(S.d("0"))
    partial[0].interest.should eq(S.d("50"))
    partial[0].insurance.should eq(S.d("10"))
    partial[1].due_on.should eq(S.date("2026-02-28"))
    total = Am.rows(base.copy_with(deferral_kind: "total"))
    total[0].capital.should eq(S.d("-50"))
    total[1].remaining.should eq(S.d("10100.25"))
    total.last.remaining.should eq(S.d("0"))
  end

  it "rattache un emprunt à un compte de dette, en donne le tableau et le capital restant dû" do
    S.setup
    account = mortgage
    loan = Api.create_loan(S.parent, loan_input(account)).value!
    loan.rows.size.should eq(240)
    loan.rows.first.insurance.should eq(S.d("25"))
    loan.current.reason.should eq("initial")
    loan.remaining.should eq(loan.rows.reverse_each.find! { |row| row.due_on <= S.date("2026-09-28") }.remaining)
    loan.rows.first.status.should eq("overdue")
    Api.account(S.system, account.id).value.should eq(loan.remaining)
    Api.create_loan(S.parent, loan_input(account)).error_keys.should eq(["perso.errors.loan.account.taken"])
    Api.create_loan(S.parent, loan_input(S.livret)).error_keys.should contain("perso.errors.loan.account.not_debt")
  end

  it "confirme une échéance : règlement sur le compte payeur, diminution de la dette, intérêts et assurance en catégories" do
    S.setup
    account = mortgage
    loan = Api.create_loan(S.parent, loan_input(account)).value!
    row = loan.rows.first
    after = Api.confirm_installment(S.parent, loan.id, row.due_on).value!
    after.rows.first.status.should eq("confirmed")
    S.balance("512001").should eq(-(row.capital + row.interest + row.insurance))
    S.balance("164001").should eq(S.d("-100000") + row.capital)
    S.balance("6101").should eq(row.interest)
    S.balance("6105").should eq(row.insurance)
    S.balance("58").should eq(S.d("0"))
    Api.confirm_installment(S.parent, loan.id, row.due_on).error_keys.should eq(["perso.errors.loan.installment.done"])
  end

  it "recalcule le tableau après un remboursement anticipé partiel et garde la version précédente" do
    S.setup
    account = mortgage
    loan = Api.create_loan(S.parent, loan_input(account)).value!
    before = loan.rows.find! { |row| row.due_on == S.date("2026-06-05") }.remaining
    prepaid = Api.prepay_loan(S.parent, loan.id, Api::PrepaymentInput.new(S.date("2026-06-20"), S.d("20000"), "duration")).value!
    prepaid.versions.size.should eq(2)
    prepaid.current.reason.should eq("prepayment")
    prepaid.current.principal.should eq(before - S.d("20000"))
    prepaid.current.first_due_on.should eq(S.date("2026-07-05"))
    prepaid.rows.size.should be < 240
    prepaid.rows.last.remaining.should eq(S.d("0"))
    prepaid.rows.find! { |row| row.due_on == S.date("2026-06-05") }.remaining.should eq(before)
    S.balance("164001").should eq(S.d("-80000"))

    same = Api.prepay_loan(S.parent, loan.id, Api::PrepaymentInput.new(S.date("2026-08-20"), S.d("1000"), "installment",
      record_operation: false)).value!
    same.versions.size.should eq(3)
    full = Api.prepay_loan(S.parent, loan.id, Api::PrepaymentInput.new(S.date("2026-09-20"), same.rows.find! { |row| row.due_on == S.date("2026-09-05") }.remaining,
      "duration", record_operation: false)).value!
    full.current.reason.should eq("repaid")
    full.remaining.should eq(S.d("0"))
  end

  it "rapproche une échéance d'une ligne importée de même montant (entry.posted)" do
    S.setup
    account = mortgage
    loan = Api.create_loan(S.parent, loan_input(account, insurance_mode: "none", insurance_value: S.d("0"),
      insurance_category_id: nil)).value!
    S.import_line("ECHEANCE PRET", "-585.11", "164001", "06/02/2026")
    Api.loan(S.system, loan.id).rows.first.status.should eq("confirmed")
  end

  it "donne l'aperçu d'un tableau avant de l'enregistrer" do
    S.setup
    account = mortgage
    rows = Api.preview_loan(S.parent, loan_input(account, months: 12)).value!
    rows.size.should eq(12)
    Api.preview_loan(S.parent, loan_input(account, months: 0)).error_keys.should eq(["perso.errors.loan.months.invalid"])
  end
end
