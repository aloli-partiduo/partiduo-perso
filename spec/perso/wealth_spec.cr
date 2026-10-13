# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Perso::SpecSupport
private alias Api = Perso::Api

describe "Placements, valorisations et patrimoine net (ADR-011 D9)" do
  it "garde l'historique des valeurs saisies et calcule la plus-value latente" do
    S.setup
    insurance = Api.create_account(S.parent, Api::AccountInput.new(nature: "life_insurance", label: "Assurance-vie",
      opening_balance: S.d("30000"), opened_on: S.date("2026-01-01"))).value!
    Api.record_valuation(S.parent, Api::ValuationInput.new(insurance.id, S.date("2026-06-30"), S.d("30800"))).value!
    Api.record_valuation(S.parent, Api::ValuationInput.new(insurance.id, S.date("2026-09-01"), S.d("31250.40"))).value!
    holding = Api.holding(S.system, insurance.id)
    holding.valuations.map(&.amount).should eq([S.d("31250.40"), S.d("30800")])
    holding.contributions.should eq(S.d("30000"))
    holding.latent_gain.should eq(S.d("1250.40"))
    Api.account(S.system, insurance.id).value.should eq(S.d("31250.40"))
    Api.record_valuation(S.parent, Api::ValuationInput.new(insurance.id, S.date("2026-09-01"), S.d("1"))).error_keys
      .should eq(["perso.errors.valuation.date.taken"])
    Api.record_valuation(S.parent, Api::ValuationInput.new(S.current_account.id, S.date("2026-09-01"), S.d("1"))).error_keys
      .should eq(["perso.errors.valuation.account.not_valued"])
  end

  it "valorise un compte-titres ligne à ligne" do
    S.setup
    titles = Api.create_account(S.parent, Api::AccountInput.new(nature: "securities", label: "Compte-titres")).value!
    valuation = Api.record_valuation(S.parent, Api::ValuationInput.new(titles.id, S.date("2026-09-15"),
      lines: [Api::ValuationLineInput.new("ETF Monde", S.d("12.5"), S.d("101.236")),
              Api::ValuationLineInput.new("Action A", S.d("3"), S.d("45.10"))])).value!
    valuation.amount.should eq(S.d("1400.75"))
    valuation.lines.first.amount.should eq(S.d("1265.45"))
  end

  it "combine trésorerie, placements, biens et dettes, par nature et par membre" do
    S.setup
    alice = Api.save_member(S.parent, Api::MemberInput.new(S.user_id("alice@example.com"), "Alice")).value!
    bruno = Api.save_member(S.parent, Api::MemberInput.new(S.user_id("bruno@example.com"), "Bruno")).value!
    Api.create_account(S.parent, Api::AccountInput.new(nature: "savings", label: "Livret", opening_balance: S.d("5000"),
      opened_on: S.date("2026-01-01"), holder_ids: [alice.id, bruno.id])).value!
    house = Api.create_account(S.parent, Api::AccountInput.new(nature: "property", label: "Maison", asset_kind: "residence",
      opening_balance: S.d("200000"), opened_on: S.date("2026-01-01"))).value!
    Api.record_valuation(S.parent, Api::ValuationInput.new(house.id, S.date("2026-06-01"), S.d("215000"))).value!
    Api.create_account(S.parent, Api::AccountInput.new(nature: "mortgage", label: "Prêt", opening_balance: S.d("150000"),
      opened_on: S.date("2026-01-01"))).value!
    S.spend("Courses", "100", "2026-09-01")
    wealth = Api.wealth(S.parent)
    wealth.cash.should eq(S.d("4900"))
    wealth.property_total.should eq(S.d("215000"))
    wealth.debts_total.should eq(S.d("150000"))
    wealth.net.should eq(S.d("69900"))
    wealth.by_nature.find! { |item| item.code == "mortgage" }.amount.should eq(S.d("-150000"))
    wealth.by_member.find! { |item| item.label == "Alice" }.amount.should eq(S.d("2500"))
    wealth.by_member.find! { |item| item.label == "Foyer" }.amount.should eq(S.d("64900"))
    wealth.months.size.should eq(12)
    wealth.months.last.amount.should eq(S.d("69900"))
    wealth.months.find! { |item| item.code == "2026-05" }.amount.should eq(S.d("55000"))
    present(Api.tile(S.parent)).net_worth.should eq(S.d("69900"))
  end
end
