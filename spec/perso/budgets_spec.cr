# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Perso::SpecSupport
private alias Api = Perso::Api
private alias Acc = Partiduo::Api::Accounting

describe "Budgets sur les prévisions de la Comptabilité (ADR-011 D8)" do
  it "crée le budget de l'année comme une prévision, compare budget et réalisé, signale un dépassement" do
    S.setup
    budget = Api.create_budget(S.parent, 2026).value!
    forecast = Acc.forecast(S.system, budget.forecast_id)
    forecast.name.should eq("Budget 2026")
    forecast.categories.map(&.label).should eq(["Dépenses", "Recettes"])
    Api.set_budget_line(S.parent, 2026, Api::BudgetLineInput.new(S.category("Alimentation").id, S.d("400"))).value!
    Api.set_budget_line(S.parent, 2026, Api::BudgetLineInput.new(S.category("Loisirs et vacances").id, S.d("1200"), "annual")).value!
    Api.set_budget_line(S.parent, 2026, Api::BudgetLineInput.new(S.category("Salaires").id, S.d("3000"))).value!
    S.spend("Carrefour", "4100", "2026-03-10")
    S.spend("Vacances", "500", "2026-07-10", "Loisirs et vacances")
    S.spend("Paie", "3000", "2026-09-01", "Salaires", kind: "income")
    view = present(Api.budget(S.parent, 2026))
    food = view.lines.find! { |line| line.category_label == "Alimentation" }
    food.budget_to_date.should eq(S.d("3600"))
    food.actual_to_date.should eq(S.d("4100"))
    food.difference.should eq(S.d("500"))
    food.remaining.should eq(S.d("700"))
    food.over?.should be_true
    food.monthly_actual[2].should eq(S.d("4100"))
    leisure = view.lines.find! { |line| line.category_label == "Loisirs et vacances" }
    leisure.budget_year.should eq(S.d("1200"))
    leisure.over?.should be_false
    salary = view.lines.find! { |line| line.category_label == "Revenus › Salaires" }
    salary.actual_year.should eq(S.d("3000"))
    salary.over?.should be_false
    view.over.map(&.category_label).should eq(["Alimentation"])
    present(Api.tile(S.parent)).over_budget.should eq(["Alimentation"])
  end

  it "refuse une catégorie déjà budgétée ou recouverte par son parent, et retire une ligne" do
    S.setup
    Api.create_budget(S.parent, 2026).value!
    Api.set_budget_line(S.parent, 2026, Api::BudgetLineInput.new(S.category("Logement").id, S.d("900"))).value!
    Api.set_budget_line(S.parent, 2026, Api::BudgetLineInput.new(S.category("Énergie").id, S.d("90"))).error_keys
      .should eq(["perso.errors.budget.category.overlap"])
    Api.create_budget(S.parent, 2026).error_keys.should eq(["perso.errors.budget.year.taken"])
    view = present(Api.budget(S.parent, 2026))
    Api.delete_budget_line(S.parent, 2026, view.lines.first.id).value!.lines.should be_empty
  end

  it "propose le budget de l'année suivante à partir du réalisé" do
    S.setup
    S.spend("Carrefour", "2400", "2026-03-10")
    S.spend("Pharmacie", "120", "2026-04-10", "Santé")
    view = Api.propose_budget(S.parent, 2027).value!
    view.year.should eq(2027)
    view.lines.map { |line| {line.category_label, line.amount} }.sort!.should eq([{"Alimentation", S.d("200")}, {"Santé", S.d("10")}])
  end
end
