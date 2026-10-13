# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Api
    # --- Opérations (D4) ----------------------------------------------------------------

    # Opérations des comptes visibles, de la plus récente à la plus
    # ancienne. Exige aussi `accounting.entry.read`.
    def self.operations(actor : Actor, query : OperationQuery = OperationQuery.new) : Array(OperationView)
      authorize!(actor, READ)
      Operations.list(actor, query)
    end

    # Une opération, ses versions successives (auteur, date) et ses
    # justificatifs (D11).
    def self.operation(actor : Actor, entry_id : Int64) : OperationDetailView
      authorize!(actor, READ)
      entry = Acc.entry(actor, entry_id)
      context = Operations::Context.new
      row = Operation.filter(entry_id: entry_id).first || Operation.filter(transfer_entry_id: entry_id).first
      account = context.accounts_by_ledger[entry.ledger_id]? || raise Partiduo::Api::NotFound.new("perso_operation", entry_id)
      writable = Records.ledgers(actor)[entry.ledger_id]?.try(&.access.writable?) || false
      view = Operations.view(context, entry, row, writable && !account.closed && !entry.cancelled? && !entry.reversal?) ||
             raise Partiduo::Api::NotFound.new("perso_operation", entry_id)
      head = row.try(&.entry_id.try(&.to_i64)) || entry_id
      ids = Operations.versions(head).map(&.entry_id)
      documents = Document.filter(entry_id__in: ids).order(:id).to_a.map { |item| Operations.document_view(item) }
      OperationDetailView.new(view, Operations.versions(head), documents)
    end

    # Requête de contrôle : les règles de `record_operation`, sans écrire.
    def self.check_operation(actor : Actor, input : OperationInput) : Result(Nil)
      authorize!(actor, WRITE)
      _account, _target, _parts, errors = Operations.check(actor, input)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    # Saisit une opération (D4) par le service d'écriture de la Comptabilité.
    # Exige aussi `accounting.entry.post` et l'écriture dans le journal du
    # compte (et du compte de destination d'un virement). Rend l'opération
    # telle qu'elle se présente.
    def self.record_operation(actor : Actor, input : OperationInput) : Result(OperationView)
      authorize!(actor, WRITE)
      Transaction.run do
        row, errors = Operations.record(actor, input)
        next Result(OperationView).failure(errors) if row.nil?
        Result(OperationView).success(present(actor, row.entry_id!.to_i64))
      end
    end

    # Corrige une opération (D4, D11) : ses écritures sont extournées, puis
    # la saisie corrigée est passée ; la nouvelle version cite l'ancienne.
    # Une écriture transférée d'un relevé ou passée dans la Comptabilité se
    # corrige de même. Exige aussi `accounting.entry.cancel`.
    def self.update_operation(actor : Actor, entry_id : Int64, input : OperationInput) : Result(OperationView)
      authorize!(actor, WRITE)
      _account, _target, _parts, errors = Operations.check(actor, input)
      return Result(OperationView).failure(errors) unless errors.empty?
      Transaction.run do
        row, entries = Operations.active!(actor, entry_id)
        reversal, failures = Operations.reverse(actor, entries, I18n.t("perso.labels.correction"))
        next Result(OperationView).failure(failures) unless failures.empty?
        created, failures = Operations.record(actor, input, entries.first.id)
        next Result(OperationView).failure(failures) if created.nil?
        Operations.retire(row, entries.first, "replaced", reversal, actor)
        Result(OperationView).success(present(actor, created.entry_id!.to_i64))
      end
    end

    # Supprime une opération : ses écritures sont extournées (D4) ; elle
    # reste dans l'historique.
    def self.delete_operation(actor : Actor, entry_id : Int64) : Result(Nil)
      authorize!(actor, WRITE)
      Transaction.run do
        row, entries = Operations.active!(actor, entry_id)
        reversal, failures = Operations.reverse(actor, entries, I18n.t("perso.labels.deletion"))
        next Result(Nil).failure(failures) unless failures.empty?
        Operations.retire(row, entries.first, "deleted", reversal, actor)
        Result(Nil).success(nil)
      end
    end

    private def self.present(actor : Actor, entry_id : Int64) : OperationView
      entry = Acc.entry(actor, entry_id)
      row = Operation.filter(entry_id: entry_id).first
      Operations.view(Operations::Context.new, entry, row, true) || raise Partiduo::Api::NotFound.new("perso_operation", entry_id)
    end

    # --- Justificatifs (D4) ---------------------------------------------------------------

    def self.documents(actor : Actor, account_id : Int64? = nil, year : Int32? = nil) : Array(DocumentView)
      authorize!(actor, READ)
      rows = Document.all
      if id = account_id
        Records.account!(actor, id)
        rows = rows.filter(account_id: id)
      elsif year
        rows = rows.filter(year: year)
      else
        visible = Records.visible_accounts(actor).map(&.[0].id!.to_i64)
        rows = rows.filter(account_id__in: visible)
      end
      rows.order("-created_at").to_a.map { |row| Operations.document_view(row) }
    end

    # Range un justificatif par le socle et le rattache à une opération, à un
    # compte ou à une année. Exige aussi `core.attachment.write`.
    def self.attach_document(actor : Actor, input : DocumentInput) : Result(DocumentView)
      authorize!(actor, WRITE)
      errors = [] of FieldError
      targets = [input.entry_id, input.account_id, input.year].count { |item| !item.nil? }
      errors << Records.error("target", "document.target.one") unless targets == 1
      errors << Records.error("kind", "document.kind.invalid") unless DOCUMENT_KINDS.includes?(input.kind)
      errors << Records.error("label", "document.label.too_long") if input.label.size > 255
      if entry_id = input.entry_id
        begin
          entry = Acc.entry(actor, entry_id)
          errors << Records.error("entry_id", "document.entry.invalid") unless Account.filter(ledger_id: entry.ledger_id).exists?
        rescue Partiduo::Api::NotFound
          errors << Records.error("entry_id", "document.entry.invalid")
        end
      end
      input.account_id.try { |id| Records.account!(actor, id) }
      input.year.try { |year| errors << Records.error("year", "document.year.invalid") unless 1900 <= year <= 2999 }
      return Result(DocumentView).failure(errors) unless errors.empty?
      Transaction.run do
        stored = Partiduo::Api::Core.store_attachment(actor, Partiduo::Api::Core::AttachmentInput.new(
          input.filename.strip, input.content_type, IO::Memory.new(input.content)))
        next Result(DocumentView).failure(stored.errors) if stored.failure?
        row = Document.create!(attachment_id: stored.value!.id, entry_id: input.entry_id, account_id: input.account_id,
          year: input.year, kind: input.kind, label: input.label.strip, created_by_id: actor.user_id)
        Result(DocumentView).success(Operations.document_view(row))
      end
    end

    # Contenu d'un justificatif : nom, type, octets. Exige aussi
    # `core.attachment.read`.
    def self.document_content(actor : Actor, id : Int64) : {String, String, Bytes}
      authorize!(actor, READ)
      row = Document.filter(id: id).first || raise Partiduo::Api::NotFound.new("perso_document", id)
      row.account_id.try { |account_id| Records.account!(actor, account_id.to_i64) }
      row.entry_id.try { |entry_id| Acc.entry(actor, entry_id.to_i64) }
      attachment_id = row.attachment_id!.to_i64
      view = Partiduo::Api::Core.attachment(actor, attachment_id)
      {view.filename, view.content_type, Partiduo::Api::Core.attachment_content(actor, attachment_id)}
    end

    def self.delete_document(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, WRITE)
      Transaction.run do
        row = Document.filter(id: id).first || raise Partiduo::Api::NotFound.new("perso_document", id)
        row.account_id.try { |account_id| Records.account!(actor, account_id.to_i64) }
        row.delete
        Result(Nil).success(nil)
      end
    end

    # --- Exports (D11) -----------------------------------------------------------------------

    def self.export_operations(actor : Actor, query : OperationQuery = OperationQuery.new(limit: MAX_LIMIT * 10)) : FileView
      authorize!(actor, READ)
      Exports.operations(actor, query)
    end

    def self.export_accounts(actor : Actor) : FileView
      authorize!(actor, READ)
      Exports.accounts(actor)
    end

    def self.export_valuations(actor : Actor) : FileView
      authorize!(actor, READ)
      Exports.valuations(actor)
    end
  end
end
