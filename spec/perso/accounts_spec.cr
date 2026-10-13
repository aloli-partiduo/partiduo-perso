# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Perso::SpecSupport
private alias Api = Perso::Api
private alias Acc = Partiduo::Api::Accounting

describe "Comptes du foyer (ADR-011 D5, D12)" do
  it "crée un livret : compte sous la base de la nature, fiche Banque et journal financier, par le contrat" do
    S.setup
    livret = S.livret
    livret.nature.should eq("savings")
    livret.rate.should eq(S.d("3"))
    livret.ledger_code.should_not eq("F01")
    ledger = Acc.ledger(S.system, livret.ledger_id)
    ledger.kind.financial?.should be_true
    ledger.default_account.try(&.number).should eq("514001")
    Acc.account(S.system, "514001").parent_number.should eq("514")
  end

  it "passe un solde d'ouverture contre le patrimoine d'ouverture, en dette pour un emprunt" do
    S.setup
    input = Api::AccountInput.new(nature: "mortgage", label: "Prêt maison", opening_balance: S.d("150000"),
      opened_on: S.date("2026-01-01"))
    loan = Api.create_account(S.parent, input).value!
    loan.balance.should eq(S.d("150000"))
    loan.debt?.should be_true
    S.balance("164001").should eq(S.d("-150000"))
    S.balance("10").should eq(S.d("150000"))
    car = Api.create_account(S.parent, Api::AccountInput.new(nature: "property", label: "Voiture", asset_kind: "vehicle",
      opening_balance: S.d("12000"), opened_on: S.date("2026-01-01"))).value!
    Acc.account(S.system, "2182001").parent_number.should eq("2182")
    car.value.should eq(S.d("12000"))
  end

  it "refuse une nature inconnue, un bien sans genre, un PEA en Belgique" do
    S.setup
    Api.create_account(S.parent, Api::AccountInput.new(nature: "crypto", label: "X")).error_keys
      .should contain("perso.errors.account.nature.invalid")
    Api.create_account(S.parent, Api::AccountInput.new(nature: "property", label: "Maison")).error_keys
      .should eq(["perso.errors.account.asset_kind.invalid"])
  end

  it "ne reprend pas deux fois le même journal" do
    S.setup
    Api.available_ledgers(S.parent).should be_empty
    Api.create_account(S.parent, Api::AccountInput.new(nature: "current", label: "Encore",
      ledger_id: S.current_account.ledger_id)).error_keys.should eq(["perso.errors.account.ledger.taken"])
  end

  it "range les comptes par titulaire et ne montre à un membre que ses comptes (droits par journal)" do
    S.setup
    alice = Api.save_member(S.parent, Api::MemberInput.new(S.user_id("alice@example.com"), "Alice")).value!
    profile = PartiduoUi::Accounts.profile("Mineur du foyer", [Api::READ, Api::WRITE, "accounting.ledger.read",
                                                               "accounting.entry.read", "accounting.entry.post"])
    PartiduoUi::Accounts.create("teen@example.com", profile: nil, profile_id: profile)
    bruno = Api.save_member(S.parent, Api::MemberInput.new(S.user_id("teen@example.com"), "Bruno", "minor")).value!
    livret = S.livret
    Api.update_account(S.parent, livret.id, Api::AccountUpdateInput.new(label: "Livret de Bruno", holder_ids: [bruno.id])).value!
      .holders.map(&.display_name).should eq(["Bruno"])
    Api.set_member_accounts(S.parent, bruno.id, [livret.id]).success?.should be_true
    teen = S.actor("teen@example.com", [Api::READ, Api::WRITE, "accounting.ledger.read", "accounting.entry.read",
                                        "accounting.entry.post"])
    Api.accounts(teen).map(&.label).should eq(["Livret de Bruno"])
    expect_raises(Partiduo::Api::NotFound) { Api.account(teen, S.current_account.id) }
    Api.members(S.parent).map(&.display_name).should eq(["Alice", "Bruno"])
    Api.save_member(S.parent, Api::MemberInput.new(alice.user_id, "Alice bis")).error_keys
      .should eq(["perso.errors.member.user.taken"])
  end

  it "exporte les comptes en CSV" do
    S.setup
    S.livret
    csv = String.new(Api.export_accounts(S.system).content)
    csv.should contain("Livret A;Livret")
    csv.should contain("Compte courant;Compte courant")
  end
end
