# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Perso::SpecSupport
private alias Api = Perso::Api
private alias Acc = Partiduo::Api::Accounting

describe "Opérations du foyer (ADR-011 D4, D11)" do
  it "passe une dépense par post_financial dans le journal du compte, sans numéro de compte montré" do
    S.setup
    view = S.spend("Carrefour", "84.30", "2026-09-10")
    view.amount.should eq(S.d("-84.30"))
    view.kind.should eq("expense")
    view.category_label.should eq("Alimentation")
    view.payee.should eq("Carrefour")
    view.source.should eq("perso")
    S.lines(view.entry_id).should eq([{"512001", "credit", S.d("84.30")}, {"62", "debit", S.d("84.30")}])
    Acc.entry(S.system, view.entry_id).source.should start_with("perso:operation:")
    S.balance("512001").should eq(S.d("-84.30"))
  end

  it "ventile une dépense sur plusieurs catégories en une écriture" do
    S.setup
    input = Api::OperationInput.new(account_id: S.current_account.id, date: S.date("2026-09-12"), amount: S.d("150"),
      payee: "Hypermarché", splits: [Api::SplitInput.new(S.category("Alimentation").id, S.d("110")),
                                     Api::SplitInput.new(S.category("Habillement").id, S.d("40"))])
    view = Api.record_operation(S.parent, input).value!
    view.splits.map(&.label).sort!.should eq(["Alimentation", "Habillement"])
    S.lines(view.entry_id).should eq([{"512001", "credit", S.d("150")}, {"62", "debit", S.d("110")}, {"67", "debit", S.d("40")}])

    wrong = Api.record_operation(S.parent, input.copy_with(amount: S.d("151")))
    wrong.error_keys.should eq(["perso.errors.operation.splits.total"])
  end

  it "refuse une catégorie de l'autre sens, un groupe de catégories, un montant nul" do
    S.setup
    base = Api::OperationInput.new(account_id: S.current_account.id, date: S.date("2026-09-12"), amount: S.d("10"),
      category_id: S.category("Salaires").id)
    Api.record_operation(S.parent, base).error_keys.should eq(["perso.errors.operation.category.kind"])
    Api.record_operation(S.parent, base.copy_with(category_id: S.category("Logement").id)).error_keys
      .should eq(["perso.errors.operation.category.has_children"])
    Api.record_operation(S.parent, base.copy_with(amount: S.d("0"), category_id: S.category("Alimentation").id)).error_keys
      .should eq(["perso.errors.operation.amount.positive"])
  end

  it "passe un virement entre deux comptes du foyer par le compte de passage, une écriture dans chaque journal" do
    S.setup
    livret = S.livret
    input = Api::OperationInput.new(account_id: S.current_account.id, date: S.date("2026-09-15"), amount: S.d("200"),
      kind: "transfer", to_account_id: livret.id)
    view = Api.record_operation(S.parent, input).value!
    view.kind.should eq("transfer")
    view.to_account_id.should eq(livret.id)
    S.balance("512001").should eq(S.d("-200"))
    S.balance("514001").should eq(S.d("200"))
    S.balance("58").should eq(S.d("0"))
    into = Api.operations(S.system, Api::OperationQuery.new(account_id: livret.id)).first
    into.amount.should eq(S.d("200"))
    into.category_label.should eq("Compte courant")
  end

  it "corrige une opération par extourne puis nouvelle écriture, et garde ses versions" do
    S.setup
    first = S.spend("EDF", "60", "2026-09-05", "Énergie")
    corrected = Api.update_operation(S.parent, first.entry_id, Api::OperationInput.new(account_id: S.current_account.id,
      date: S.date("2026-09-05"), amount: S.d("65.40"), category_id: S.category("Énergie").id, payee: "EDF")).value!
    corrected.entry_id.should_not eq(first.entry_id)
    Acc.entry(S.system, first.entry_id).cancelled?.should be_true
    S.balance("512001").should eq(S.d("-65.40"))
    list = Api.operations(S.system)
    list.size.should eq(1)
    list.first.versions.should eq(2)
    detail = Api.operation(S.system, corrected.entry_id)
    detail.versions.map(&.status).should eq(["active", "replaced"])
    detail.versions.last.amount.should eq(S.d("-60"))
    detail.versions.first.created_by_name.should be_nil

    Api.delete_operation(S.parent, corrected.entry_id).success?.should be_true
    Api.operations(S.system).should be_empty
    S.balance("512001").should eq(S.d("0"))
  end

  it "retire une opération extournée dans la Comptabilité (entry.cancelled)" do
    S.setup
    view = S.spend("Pharmacie", "12", "2026-09-06", "Santé")
    Acc.cancel_entry(S.system, Acc::CancelEntryInput.new(entry_id: view.entry_id)).success?.should be_true
    Perso::Operation.filter(entry_id: view.entry_id).first!.status.should eq("deleted")
    Api.operations(S.system).should be_empty
  end

  it "présente une écriture transférée d'un relevé importé, et rattache sa ligne à l'écriture qui la corrige" do
    S.setup
    S.import_line("CB BOULANGERIE DU MARCHE", "-8.40", "62")
    imported = Api.operations(S.system).first
    imported.source.should eq("bankimport")
    imported.category_label.should eq("Alimentation")
    imported.payee.should eq("CB BOULANGERIE DU MARCHE")

    corrected = Api.update_operation(S.parent, imported.entry_id, Api::OperationInput.new(account_id: S.current_account.id,
      date: imported.date, amount: S.d("8.40"), category_id: S.category("Loisirs et vacances").id, payee: "Boulangerie")).value!
    corrected.category_label.should eq("Loisirs et vacances")
    line = Bankimport::Api.lines(S.system, Bankimport::Api::LineQuery.new(status: nil)).first
    {line.status, line.entry_id}.should eq({"transferred", corrected.entry_id})
    Bankimport::Api.count_lines(S.system).should eq(0)
    Api.operation(S.system, corrected.entry_id).versions.size.should eq(2)
    Bankimport::Api.transfer(S.parent, [line.id]).value!.transferred.should be_empty
  end

  it "garde le relevé pointé de l'import, complété de l'écriture qui corrige, sans en changer l'identifiant (D-PER-024)" do
    S.setup
    S.import_line("CB BOULANGERIE DU MARCHE", "-8.40", "62")
    line = Bankimport::Api.lines(S.system, Bankimport::Api::LineQuery.new(status: nil)).last
    pointed = Bankimport::Api.reconcile(S.parent, line.import_id,
      Bankimport::Api::ReconcileInput.new("RELEVE-09", S.d("100"), S.d("91.60"))).value!
    statement_id = pointed.statement_id || raise "relevé pointé attendu"
    imported = Api.operations(S.system).first

    corrected = Api.update_operation(S.parent, imported.entry_id, Api::OperationInput.new(account_id: S.current_account.id,
      date: imported.date, amount: S.d("8.40"), category_id: S.category("Loisirs et vacances").id, payee: "Boulangerie")).value!
    Bankimport::Api.import_detail(S.system, line.import_id).statement_id.should eq(statement_id)
    statement = Acc.bank_statement(S.system, statement_id)
    statement.lines.map(&.entry_id).should contain(corrected.entry_id)
    statement.statement.amount.should eq(S.d("-8.40"))
    Bankimport::Api.lines(S.system, Bankimport::Api::LineQuery.new(status: nil)).last.entry_id.should eq(corrected.entry_id)
  end

  it "écarte la ligne du relevé quand la correction change le montant, ou quand on supprime l'opération" do
    S.setup
    S.import_line("CB BOULANGERIE DU MARCHE", "-8.40", "62")
    imported = Api.operations(S.system).first
    corrected = Api.update_operation(S.parent, imported.entry_id, Api::OperationInput.new(account_id: S.current_account.id,
      date: imported.date, amount: S.d("9.40"), category_id: S.category("Alimentation").id, payee: "Boulangerie")).value!
    Bankimport::Api.lines(S.system, Bankimport::Api::LineQuery.new(status: "discarded")).size.should eq(1)

    S.import_line("CB PRIMEUR", "-5.00", "62", "16/09/2026")
    primeur = Api.operations(S.system).find! { |view| view.payee == "CB PRIMEUR" }
    Api.delete_operation(S.parent, primeur.entry_id).value!
    Bankimport::Api.lines(S.system, Bankimport::Api::LineQuery.new(status: "discarded")).size.should eq(2)
    Bankimport::Api.count_lines(S.system).should eq(0)
    corrected.amount.should eq(S.d("-9.40"))
  end

  it "présente le bénéficiaire que la règle du foyer pose sur la ligne importée (A-PER-2)" do
    S.setup
    rule = Api.save_rule(S.parent, Api::RuleInput.new(category_id: S.category("Alimentation").id, label_contains: "boulangerie",
      payee: "Au bon pain")).value!
    rule.payee.should eq("Au bon pain")
    S.import_line("CB BOULANGERIE DU MARCHE 14/09", "-8.40", "62")
    imported = Api.operations(S.system).first
    imported.payee.should eq("Au bon pain")
    Api.operation(S.system, imported.entry_id).operation.payee.should eq("Au bon pain")
    Acc.entry(S.system, imported.entry_id).label.should eq("Au bon pain · CB BOULANGERIE DU MARCHE 14/09")
  end

  it "filtre par compte, catégorie, texte et membre ; un conseiller lit sans écrire" do
    S.setup
    member = Api.save_member(S.parent, Api::MemberInput.new(S.user_id("alice@example.com"), "Alice")).value!
    S.spend("Carrefour", "50", "2026-09-10")
    Api.record_operation(S.parent, Api::OperationInput.new(account_id: S.current_account.id, date: S.date("2026-09-11"),
      amount: S.d("30"), category_id: S.category("Santé").id, payee: "Docteur", member_id: member.id)).value!
    Api.operations(S.system, Api::OperationQuery.new(category_id: S.category("Santé").id)).map(&.payee).should eq(["Docteur"])
    Api.operations(S.system, Api::OperationQuery.new(text: "carre")).map(&.payee).should eq(["Carrefour"])
    Api.operations(S.system, Api::OperationQuery.new(member_id: member.id)).first.member_name.should eq("Alice")
    Api.operations(S.advisor).size.should eq(2)
    expect_raises(Partiduo::Api::Forbidden) do
      Api.record_operation(S.advisor, Api::OperationInput.new(account_id: S.current_account.id, date: S.date("2026-09-11"),
        amount: S.d("1"), category_id: S.category("Santé").id))
    end
  end

  it "range un justificatif sur une opération et l'exporte" do
    S.setup
    view = S.spend("Restos du cœur", "100", "2026-03-01", "Dons")
    document = Api.attach_document(S.parent, Api::DocumentInput.new(filename: "recu.pdf", content_type: "application/pdf",
      content: "%PDF-1.4\n%fin\n".to_slice, kind: "tax_receipt", label: "Reçu fiscal", entry_id: view.entry_id)).value!
    document.kind.should eq("tax_receipt")
    Api.operation(S.system, view.entry_id).documents.map(&.label).should eq(["Reçu fiscal"])
    _name, type, content = Api.document_content(S.parent, document.id)
    type.should eq("application/pdf")
    String.new(content).should start_with("%PDF")
    csv = String.new(Api.export_operations(S.system).content)
    csv.should contain("Restos du cœur")
    csv.should contain("-100.00")
  end
end
