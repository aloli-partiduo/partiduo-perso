# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Perso::SpecSupport
private alias Api = Perso::Api

# Administrateur connecté (profil ADMIN : toutes les permissions), dossier
# foyer provisionné, années 2025 à 2027.
private def signed_in : PartiduoUi::Browser
  S.provision
  [2025, 2026, 2027].each { |year| PartiduoUi::Reference.fiscal_year(year) }
  PartiduoUi::Accounts.create
  S.user("bruno@example.com", "Bruno")
  PartiduoUi::Accounts.signed_in
end

private def operation_form(**values) : Hash(String, String)
  form = {"account_id" => S.current_account.id.to_s, "kind" => "expense", "date" => "2026-09-10", "amount" => "42,50",
          "category_id" => S.category("Alimentation").id.to_s, "to_account_id" => "", "payee" => "Marché",
          "member_id" => "", "note" => ""}
  (1..4).each { |index| form["split_category_#{index}"] = ""; form["split_amount_#{index}"] = "" }
  values.each { |key, value| form[key.to_s] = value }
  form
end

describe "Écrans du foyer sous /ext/PERSO/ (ADR-005, ADR-011 D4)" do
  it "est montée sous le code de l'extension, avec ses permissions par route" do
    Marten.routes.reverse("perso:operations").should eq("/ext/PERSO/operations")
    mount = PartiduoUi::Extensions["PERSO"]? || raise("interface non montée")
    mount.permission.should eq("perso.read")
    mount.permission_for("perso:operation_new").should eq("perso.write")
    mount.permission_for("perso:budget_line").should eq("perso.budget")
    mount.permission_for("perso:account_new").should eq("perso.admin")
    mount.permission_for("perso:wealth").should eq("perso.read")
  end

  it "déclare la variante « Recettes et dépenses » du foyer, sans les menus d'entreprise de la Comptabilité" do
    flavor = PartiduoUi::SimpleMode.flavors.find! { |item| item.module_code == "PERSO" }
    flavor.read.should eq("perso.read")
    flavor.menu.map(&.code).should eq(%w[DASHBOARD PERSO_OPERATIONS PERSO_ACCOUNTS BANKIMPORT_LINES PERSO_SCHEDULE
      PERSO_BUDGETS PERSO_WEALTH PERSO_TAX])
    flavor.hidden_menus.should contain("ACC_FEC")
    flavor.hidden_menus.should contain("ACC_CLOSING")
    flavor.hidden_menus.should contain("ACC_VAT_RETURN")
  end

  it "présente le menu réduit et les tuiles du foyer en recettes et dépenses" do
    browser = signed_in
    S.spend("Carrefour", "84,30".sub(',', '.'), "2026-09-10")
    home = browser.get("/").html
    home.should contain("Trésorerie du foyer")
    home.should contain("Patrimoine net")
    menu = browser.get("/ext/PERSO/operations").html
    menu.should contain(%(href="/ext/PERSO/schedule"))
    menu.should contain(%(href="/ext/PERSO/wealth"))
    menu.should_not contain(%(href="/accounting/fec"))
  end

  it "saisit une opération par le formulaire, la montre, la corrige et la supprime" do
    browser = signed_in
    browser.get("/ext/PERSO/").headers["Location"].should eq("/ext/PERSO/operations")
    form = browser.get("/ext/PERSO/operations/new").html
    form.should contain("Nouvelle opération")
    form.should contain("Ventilation sur plusieurs catégories")
    form.should_not contain(">62<")
    refused = browser.post("/ext/PERSO/operations/new", operation_form(amount: "abc"))
    refused.status.should eq(422)
    created = browser.post("/ext/PERSO/operations/new", operation_form)
    created.status.should eq(302)
    list = browser.follow(created).html
    list.should contain("Opération enregistrée.")
    list.should contain("Marché")
    list.should contain("42,50")
    view = Api.operations(S.system).first
    detail = browser.get("/ext/PERSO/operations/#{view.entry_id}").html
    detail.should contain("Versions successives")
    detail.should contain("Ajouter un justificatif")
    corrected = browser.post("/ext/PERSO/operations/#{view.entry_id}/edit", operation_form(amount: "45"))
    corrected.status.should eq(302)
    browser.follow(corrected).html.should contain("Opération corrigée")
    current = Api.operations(S.system).first
    current.versions.should eq(2)
    deleted = browser.post("/ext/PERSO/operations/#{current.entry_id}/delete")
    browser.follow(deleted).html.should contain("Opération supprimée")
    csv = browser.get("/ext/PERSO/exports/operations")
    csv.content_type.should contain("text/csv")
  end

  it "montre les comptes, l'échéancier, les budgets, le patrimoine et la déclaration" do
    browser = signed_in
    browser.get("/ext/PERSO/accounts").html.should contain("Compte courant")
    created = browser.post("/ext/PERSO/accounts/new", {"nature" => "savings", "label" => "Livret A", "institution" => "",
                                                       "asset_kind" => "", "rate" => "3", "ceiling" => "", "opened_on" => "2026-01-01",
                                                       "holder_ids" => "", "ledger_id" => "", "opening_balance" => "1000", "position" => "20"})
    created.status.should eq(302)
    account = browser.follow(created).html
    account.should contain("Livret A")
    account.should contain("000,00")
    browser.get("/ext/PERSO/schedule").html.should contain("Soldes prévisionnels")
    browser.post("/ext/PERSO/recurring/new", {"account_id" => S.current_account.id.to_s, "kind" => "expense", "payee" => "Loyer",
                                              "amount" => "700", "estimated" => "", "category_id" => S.category("Loyer ou échéance").id.to_s,
                                              "to_account_id" => "", "frequency" => "monthly", "interval_days" => "", "first_on" => "2026-10-05",
                                              "last_on" => "", "business_days" => "", "member_id" => "", "active" => "1"}).status.should eq(302)
    schedule = browser.get("/ext/PERSO/schedule").html
    schedule.should contain("Loyer")
    browser.post("/ext/PERSO/budgets/create?year=2026").status.should eq(302)
    budget = browser.get("/ext/PERSO/budgets?year=2026").html
    budget.should contain("Budget 2026")
    browser.post("/ext/PERSO/budgets/2026/lines", {"category_id" => S.category("Alimentation").id.to_s, "amount" => "400",
                                                   "period_kind" => "monthly"}).status.should eq(302)
    browser.get("/ext/PERSO/budgets?year=2026").html.should contain("Dans le budget")
    browser.get("/ext/PERSO/wealth").html.should contain("Patrimoine net")
    tax = browser.get("/ext/PERSO/tax?year=2026").html
    tax.should contain("Déclaration des revenus 2026")
    tax.should contain("7UF")
    browser.get("/ext/PERSO/tax/csv?year=2026").content_type.should contain("text/csv")
    browser.get("/ext/PERSO/tax/pdf?year=2026").content_type.should eq("application/pdf")
  end

  it "ouvre les paramètres à l'administrateur du foyer seulement" do
    browser = signed_in
    browser.get("/ext/PERSO/categories").html.should contain("Alimentation")
    browser.get("/ext/PERSO/rules").status.should eq(200)
    browser.get("/ext/PERSO/rules").html.should contain(%(name="payee"))
    browser.get("/ext/PERSO/members").status.should eq(200)
    browser.get("/ext/PERSO/settings").html.should contain("Barème kilométrique")
    profile = PartiduoUi::Accounts.profile("Lecture du foyer", ["perso.read", "accounting.ledger.read", "accounting.entry.read"])
    PartiduoUi::Accounts.create("lecture@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("lecture@example.com")
    reader.get("/ext/PERSO/operations").status.should eq(200)
    reader.get("/ext/PERSO/categories").status.should eq(403)
    reader.get("/ext/PERSO/operations/new").status.should eq(403)
  end
end
