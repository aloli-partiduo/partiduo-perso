# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Perso::SpecSupport
private alias Api = Perso::Api

describe "Aide à la déclaration de revenus (ADR-011 D10)" do
  it "récapitule dons, emploi à domicile (aides déduites), frais réels et revenus fonciers d'une année" do
    S.setup
    S.spend("Restos du cœur", "150", "2026-02-01", "Dons")
    S.spend("Restos du cœur", "50", "2026-11-01", "Dons")
    S.spend("Croix-Rouge", "80", "2026-05-01", "Dons")
    S.spend("Nounou", "600", "2026-03-31", "Emploi à domicile")
    aid = Api.create_category(S.parent, Api::CategoryInput.new(label: "Aides CAF garde", kind: "income",
      parent_id: S.category("Revenus").id, tax_tag: "home_employment_aid")).value!
    S.spend("CAF", "200", "2026-04-05", aid.label, kind: "income")
    S.spend("Locataire", "650", "2026-03-01", "Revenus fonciers", kind: "income")
    S.spend("Dons 2025", "999", "2025-12-31", "Dons")
    Api.add_trip(S.parent, Api::TripInput.new(2026, 5, 12000, label: "Clio")).value!.allowance.should eq(S.d("5679"))

    summary = Api.tax_summary(S.parent, 2026)
    donations = summary.sections.find! { |section| section.code == "donations" }
    donations.total.should eq(S.d("280"))
    donations.items.map { |item| {item.label, item.amount, item.entries.size} }
      .should eq([{"Croix-Rouge", S.d("80"), 1}, {"Restos du cœur", S.d("200"), 2}])
    donations.boxes.map(&.code).should eq(["7UF", "7UD"])
    home = summary.sections.find! { |section| section.code == "home_employment" }
    home.total.should eq(S.d("400"))
    expenses = summary.sections.find! { |section| section.code == "professional_expenses" }
    expenses.total.should eq(S.d("5679"))
    summary.sections.find! { |section| section.code == "rental" }.total.should eq(S.d("650"))
    summary.boxes_year.should eq(2025)
    summary.mileage_year.should eq(2024)

    csv = String.new(Api.tax_csv(S.parent, 2026).content)
    csv.should contain("Dons;7UF 7UD;Restos du cœur;2026-02-01")
    pdf = Api.tax_pdf(S.parent, 2026, ->(value : BigDecimal) { value.to_s }).value!
    pdf.content_type.should eq("application/pdf")
    String.new(pdf.content[0, 5]).should eq("%PDF-")
  end

  it "applique le barème saisi par l'administrateur à partir de son année" do
    S.setup
    Api.set_mileage_rates(S.parent, 2026, [Api::MileageRateInput.new(2026, 5, S.d("0.7"), max_km: nil)]).value!.should eq(1)
    Api.add_trip(S.parent, Api::TripInput.new(2026, 5, 1000)).value!.allowance.should eq(S.d("700"))
    Api.trips(S.parent, 2025).should be_empty
    year, rates = Api.mileage_rates(S.parent, 2025)
    year.should eq(2024)
    rates.size.should eq(15)
  end
end
