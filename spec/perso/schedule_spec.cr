# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Perso::SpecSupport
private alias Api = Perso::Api

private def rent(**changes) : Api::RecurringView
  input = Api::RecurringInput.new(account_id: S.current_account.id, payee: "Loyer", amount: S.d("750"),
    first_on: S.date("2026-07-05"), category_id: S.category("Loyer ou échéance").id)
  result = Api.save_recurring(S.parent, input.copy_with(**changes))
  raise "récurrence refusée : #{result.error_keys.join(", ")}" if result.failure?
  result.value!
end

describe "Opérations récurrentes et échéancier (ADR-011 D7)" do
  it "calcule les échéances, les reporte au jour ouvré, signale les retards" do
    Perso::Calendar.easter(2026).should eq(S.date("2026-04-05"))
    Perso::Calendar.next_business_day(S.date("2026-07-04")).should eq(S.date("2026-07-06"))
    Perso::Calendar.next_business_day(S.date("2026-07-14")).should eq(S.date("2026-07-15"))
    S.setup
    view = rent(business_days: true)
    view.next_due_on.should eq(S.date("2026-10-05"))
    schedule = Api.schedule(S.parent, S.date("2026-09-28"), S.date("2026-12-31"))
    dates = schedule.dues.map(&.date)
    dates.should contain(S.date("2026-10-05"))
    dates.should contain(S.date("2026-12-07"))
    schedule.dues.select(&.status.==("overdue")).map(&.due_on).should eq([S.date("2026-07-05"), S.date("2026-08-05"), S.date("2026-09-05")])
    schedule.overdue_count.should eq(3)
    Api.overdue_count(S.parent).should eq(3)
  end

  it "confirme une échéance (l'opération est passée) ou l'écarte ; le solde prévisionnel suit" do
    S.setup
    view = rent
    operation = Api.confirm_due(S.parent, Api::ConfirmInput.new(view.id, S.date("2026-07-05"))).value!
    operation.amount.should eq(S.d("-750"))
    S.balance("512001").should eq(S.d("-750"))
    Api.confirm_due(S.parent, Api::ConfirmInput.new(view.id, S.date("2026-07-05"))).error_keys.should eq(["perso.errors.recurring.due.done"])
    Api.skip_due(S.parent, view.id, S.date("2026-08-05")).success?.should be_true
    Api.confirm_due(S.parent, Api::ConfirmInput.new(view.id, S.date("2026-07-06"))).error_keys.should eq(["perso.errors.recurring.due.unknown"])
    schedule = Api.schedule(S.parent, S.date("2026-09-28"), S.date("2026-11-30"))
    schedule.overdue_count.should eq(1)
    balance = schedule.balances.find! { |item| item.account_label == "Compte courant" }
    balance.balance.should eq(S.d("-750"))
    balance.projected.should eq(S.d("-3000"))
    balance.lowest.should eq(S.d("-3000"))
    Api.reopen_due(S.parent, view.id, S.date("2026-08-05")).success?.should be_true
    Api.schedule(S.parent, S.date("2026-09-28"), S.date("2026-09-30")).overdue_count.should eq(2)
  end

  it "rapproche une échéance d'une ligne importée de même catégorie et de même montant (entry.posted)" do
    S.setup
    view = rent
    S.import_line("PRLV LOYER JUILLET", "-750", "6101", "06/07/2026")
    occurrence = Perso::Occurrence.filter(recurring_id: view.id).first!
    occurrence.status.should eq("matched")
    occurrence.due_on.should eq(S.date("2026-07-05"))
    Api.schedule(S.parent, S.date("2026-09-28"), S.date("2026-09-30")).overdue_count.should eq(2)
  end

  it "prévoit un virement d'épargne sur les deux comptes, et refuse une saisie incohérente" do
    S.setup
    livret = S.livret
    rent(kind: "transfer", category_id: nil, to_account_id: livret.id, payee: "Épargne", amount: S.d("100"),
      first_on: S.date("2026-10-01"), frequency: "quarterly")
    schedule = Api.schedule(S.parent, S.date("2026-09-28"), S.date("2027-04-30"))
    schedule.dues.map(&.due_on).should eq([S.date("2026-10-01"), S.date("2027-01-01"), S.date("2027-04-01")])
    schedule.balances.find! { |item| item.account_label == "Livret A" }.projected.should eq(S.d("300"))
    bad = Api.save_recurring(S.parent, Api::RecurringInput.new(account_id: S.current_account.id, payee: "", amount: S.d("0"),
      first_on: S.date("2026-10-01"), frequency: "days", category_id: S.category("Salaires").id))
    bad.error_keys.sort.should eq(["perso.errors.operation.amount.positive", "perso.errors.operation.category.kind",
                                   "perso.errors.recurring.interval.invalid", "perso.errors.recurring.payee.blank"])
  end
end
