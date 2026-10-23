# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions des écrans de l'extension (ADR-005 D7) : chaque route de
# `/ext/PERSO/` servie en `GET` (liste tirée du routeur de Marten),
# obtenue dans chaque langue de l'interface par l'administrateur d'un
# foyer garni : deux membres, comptes de chaque sorte (courant, livret,
# PEA valorisé par lignes, résidence valorisée, prêt immobilier et son
# emprunt, dette sans emprunt), opérations (dépense avec justificatif,
# recette, virement, ventilation), opération récurrente aux échéances
# confirmée, sautée et en retard, budget, déplacements, règle et
# catégorie ajoutée. Contrôle de l'interface
# (`PartiduoUi::Translations`) : ni marqueur de traduction absente, ni
# clé brute, ni interpolation non résolue, et toute route atteinte par
# les liens des pages.

private alias S = Perso::SpecSupport
private alias Api = Perso::Api

describe "Traductions des écrans PERSO (langues de l'interface)" do
  it "rend chaque écran dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    S.provision
    [2025, 2026, 2027].each { |year| PartiduoUi::Reference.fiscal_year(year) }
    PartiduoUi::Accounts.create
    S.user("bruno@example.com", "Bruno")
    browser = PartiduoUi::Accounts.signed_in

    alice = Api.save_member(S.parent, Api::MemberInput.new(S.user_id("alice@example.com"), "Alice")).value!
    Api.save_member(S.parent, Api::MemberInput.new(S.user_id("bruno@example.com"), "Bruno", "minor")).value!
    livret = S.livret
    pea = Api.create_account(S.parent, Api::AccountInput.new(nature: "pea", label: "PEA")).value!
    Api.record_valuation(S.parent, Api::ValuationInput.new(pea.id, S.date("2026-09-15"),
      lines: [Api::ValuationLineInput.new("Fonds monde", S.d("10"), S.d("152.30"))])).value!
    house = Api.create_account(S.parent, Api::AccountInput.new(nature: "property", label: "Maison", asset_kind: "residence")).value!
    Api.record_valuation(S.parent, Api::ValuationInput.new(house.id, S.date("2026-06-01"), S.d("215000"))).value!
    mortgage = Api.create_account(S.parent, Api::AccountInput.new(nature: "mortgage", label: "Prêt maison", institution: "Banque")).value!
    Api.create_loan(S.parent, Api::LoanInput.new(account_id: mortgage.id, payment_account_id: S.current_account.id,
      principal: S.d("100000"), annual_rate: S.d("3.6"), months: 240, first_due_on: S.date("2026-02-05"),
      interest_category_id: S.category("Loyer ou échéance").id, insurance_category_id: S.category("Assurance habitation").id,
      insurance_mode: "initial", insurance_value: S.d("0.30"))).value!
    # Dette sans emprunt : lien de création de l'emprunt.
    debt = Api.create_account(S.parent, Api::AccountInput.new(nature: "other_debt", label: "Prêt familial")).value!

    spent = S.spend("Restos du cœur", "100", "2026-03-01", "Dons")
    Api.attach_document(S.parent, Api::DocumentInput.new(filename: "recu.pdf", content_type: "application/pdf",
      content: "%PDF-1.4\n%fin\n".to_slice, kind: "tax_receipt", label: "Reçu fiscal", entry_id: spent.entry_id)).value!
    S.spend("Carrefour", "84.30", "2026-09-10")
    Api.record_operation(S.parent, Api::OperationInput.new(account_id: S.current_account.id, date: S.date("2026-09-01"),
      amount: S.d("2500"), kind: "income", category_id: S.category("Salaires").id, payee: "Employeur",
      member_id: alice.id)).value!
    Api.record_operation(S.parent, Api::OperationInput.new(account_id: S.current_account.id, date: S.date("2026-09-02"),
      amount: S.d("300"), kind: "transfer", to_account_id: livret.id)).value!
    Api.record_operation(S.parent, Api::OperationInput.new(account_id: S.current_account.id, date: S.date("2026-09-05"),
      amount: S.d("120"), kind: "expense", payee: "Hypermarché",
      splits: [Api::SplitInput.new(S.category("Alimentation").id, S.d("90")),
               Api::SplitInput.new(S.category("Santé").id, S.d("30"))])).value!

    rent = Api.save_recurring(S.parent, Api::RecurringInput.new(account_id: S.current_account.id, payee: "Loyer",
      amount: S.d("750"), first_on: S.date("2026-07-05"), category_id: S.category("Loyer ou échéance").id)).value!
    Api.confirm_due(S.parent, Api::ConfirmInput.new(rent.id, S.date("2026-07-05"))).value!
    Api.skip_due(S.parent, rent.id, S.date("2026-08-05")).value!

    Api.create_budget(S.parent, 2026).value!
    Api.set_budget_line(S.parent, 2026, Api::BudgetLineInput.new(S.category("Alimentation").id, S.d("400"))).value!
    Api.add_trip(S.parent, Api::TripInput.new(2026, 5, 3200, alice.id, "Clientèle")).value!
    Api.save_rule(S.parent, Api::RuleInput.new(S.category("Alimentation").id, label_contains: "CARREFOUR", payee: "Carrefour")).value!
    Api.create_category(S.parent, Api::CategoryInput.new("Jardinage")).value!

    explorer = PartiduoUi::Translations::Explorer.new(&.name.starts_with?("perso:"))
    # Fiches que la limite d'adresses par route de l'exploration pourrait
    # écarter (six comptes, plus de quatre opérations) : PEA valorisé
    # (valorisations), prêt immobilier et son emprunt (remboursement
    # anticipé), dette sans emprunt (création), opération au justificatif.
    seeds = [pea.id, mortgage.id, debt.id].map { |id| "/ext/PERSO/accounts/#{id}" } + ["/ext/PERSO/operations/#{spent.entry_id}"]
    begin
      explorer.crawl(browser, "PERSO", seeds)
    ensure
      # L'exploration laisse active la dernière langue obtenue (nl) ; les
      # specs suivantes attendent la langue par défaut.
      I18n.activate(Marten.settings.i18n.default_locale)
    end
    puts "\nTraductions de PERSO : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end
