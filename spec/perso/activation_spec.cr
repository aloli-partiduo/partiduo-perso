# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Perso::SpecSupport
private alias Api = Perso::Api

describe "Extension PERSO : manifeste, activation, dossier foyer (ADR-011 D1, D2, A1, A3)" do
  it "déclare ses dépendances, ses incompatibilités et ses permissions" do
    manifest = Partiduo::Modules["PERSO"]
    manifest.depends_on.should eq(["ACCOUNTING", "BANKIMPORT"])
    manifest.incompatible_with.should contain("INVOICING")
    manifest.incompatible_with.should contain("MICRO")
    manifest.incompatible_with.should contain("LIBERAL")
    manifest.incompatible_with.should contain("TELEDEC")
    manifest.incompatible_with.should_not contain("SEPA")
    manifest.permissions.should eq(["perso.read", "perso.write", "perso.budget", "perso.admin"])
    manifest.version.should eq(Perso::VERSION)
    Perso::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
  end

  it "refuse la Facturation dans un dossier où PERSO est actif, et inversement" do
    refused = Partiduo::Api::Modules.activate(S.system, "INVOICING")
    refused.failure?.should be_true
    refused.error_keys.should contain("modules.errors.activation.incompatible_with")
  end

  it "charge les catégories et reprend le compte courant au provisionnement d'un dossier foyer" do
    S.setup
    categories = Api.categories(S.system)
    categories.map(&.label).should contain("Alimentation")
    energy = S.category("Énergie")
    energy.parent_label.should eq("Logement")
    energy.depth.should eq(1)
    S.category("Dons").tax_tag.should eq("donation")
    S.category("Emploi à domicile").tax_tag.should eq("home_employment")
    S.category("Salaires").kind.should eq("income")
    current = S.current_account
    current.ledger_code.should eq("F01")
    current.balance.should eq(BigDecimal.new(0))
  end

  it "est indisponible dans un dossier d'entreprise" do
    with_active_modules("accounting,bankimport,perso") do
      PartiduoUi::Reference.provision("fr")
    end
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.categories(S.system) }
    Api.tile(S.system).should be_nil
  end

  it "reprend les catégories du plan après coup sans doublon" do
    S.setup
    before = Api.categories(S.system).size
    Api.load_categories(S.parent).value!.should eq(0)
    Api.categories(S.system).size.should eq(before)
  end
end
