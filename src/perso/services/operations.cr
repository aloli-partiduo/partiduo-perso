# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Opérations du foyer (D4, D-PER-007) : saisies en recettes et dépenses,
  # passées par le service d'écriture de la Comptabilité dans le journal
  # financier du compte, corrigées par extourne puis nouvelle écriture.
  # Interne.
  module Operations
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError
    alias Actor = Partiduo::Api::Actor

    # Référence des écritures passées par l'extension (`source`).
    SOURCE = "perso:operation"

    # Préfixe de la référence des écritures transférées d'un relevé importé
    # (`partiduo-bankimport`, D-BKI-008).
    BANKIMPORT_SOURCE = "bankimport:line:"

    # Compte de passage d'un virement entre deux comptes du foyer, à défaut
    # du compte par défaut `internal_transfer` du dossier.
    TRANSIT_ACCOUNT = "58"

    MAX_PAYEE =  120
    MAX_NOTE  = 4000

    # Référence propre à une écriture (unique en base) : `perso:operation:<uuid>`.
    def self.source(suffix : String = "") : String
      "#{SOURCE}:#{UUID.random}#{suffix}"
    end

    def self.transit_account : String
      Acc.default_account(Records.system, "internal_transfer").try(&.number) || TRANSIT_ACCOUNT
    end

    # --- Contrôles --------------------------------------------------------------------

    # Contrôle une saisie ; rend le compte, la destination d'un virement et
    # les parts (catégorie, montant), ou les erreurs.
    def self.check(actor : Actor, input : Api::OperationInput) : {Account?, Account?, Array({Category, BigDecimal}), Array(FieldError)}
      errors = [] of FieldError
      parts = [] of {Category, BigDecimal}
      account = Records.writable_account(actor, input.account_id, "account_id", errors)
      target = nil
      header_errors(input, errors)
      if input.kind == "transfer"
        target = Records.writable_account(actor, input.to_account_id, "to_account_id", errors)
        if target && account && target.id == account.id
          errors << Records.error("to_account_id", "operation.transfer.same_account")
        end
      elsif Api::OPERATION_KINDS.includes?(input.kind)
        parts = category_parts(input, errors)
      end
      {account, target, parts, errors}
    end

    # Sorte, montant au centime, longueurs, membre.
    private def self.header_errors(input : Api::OperationInput, errors : Array(FieldError)) : Nil
      errors << Records.error("kind", "operation.kind.invalid") unless Api::OPERATION_KINDS.includes?(input.kind)
      if input.amount <= 0
        errors << Records.error("amount", "operation.amount.positive")
      elsif input.amount != Records.cents(input.amount)
        errors << Records.error("amount", "operation.amount.cents")
      end
      errors << Records.error("payee", "operation.payee.too_long", {"max" => MAX_PAYEE.to_s}) if input.payee.strip.size > MAX_PAYEE
      errors << Records.error("note", "operation.note.too_long", {"max" => MAX_NOTE.to_s}) if input.note.size > MAX_NOTE
      if (member_id = input.member_id) && !Member.filter(id: member_id).exists?
        errors << Records.error("member_id", "operation.member.invalid")
      end
    end

    # Catégorie seule, ou ventilation dont la somme fait le montant ; chaque
    # catégorie active, sans sous-catégorie, du sens de l'opération.
    private def self.category_parts(input : Api::OperationInput, errors : Array(FieldError)) : Array({Category, BigDecimal})
      wanted = input.kind == "income" ? "income" : "expense"
      split = !input.splits.empty?
      entries = if split
                  input.splits.map_with_index { |part, index| {part.category_id, part.amount, "splits[#{index}].category_id"} }
                else
                  input.category_id.try { |id| [{id, input.amount, "category_id"}] } || [] of {Int64, BigDecimal, String}
                end
      if entries.empty?
        errors << Records.error("category_id", "operation.category.blank")
        return [] of {Category, BigDecimal}
      end
      parts = entries.compact_map do |(id, amount, field)|
        row = Category.filter(id: id).first
        if key = Categories.posting_error(row, wanted)
          errors << Records.error(field, key)
          next
        end
        if split && amount <= 0
          errors << Records.error(field.sub("category_id", "amount"), "operation.amount.positive")
          next
        end
        row.try { |found| {found, amount} }
      end
      total = input.splits.sum(Records::ZERO, &.amount)
      if split && total != input.amount
        errors << Records.error("splits", "operation.splits.total", {"total" => total.to_s, "amount" => input.amount.to_s})
      end
      parts
    end

    # --- Écriture ---------------------------------------------------------------------

    # Passe l'opération (D4) : une dépense ou une recette d'une catégorie par
    # `post_financial` ; ventilée, par `post_entry` dans le même journal ; un
    # virement par deux `post_financial`, un dans chaque journal, par le
    # compte de passage (D-PER-007). À appeler dans une transaction.
    def self.record(actor : Actor, input : Api::OperationInput, previous_entry_id : Int64? = nil) : {Operation?, Array(FieldError)}
      account, target, parts, errors = check(actor, input)
      return {nil, errors} unless errors.empty? && account
      date = Calendar.day(input.date)
      unless Years.prepare(date.year)
        return {nil, [Records.error("date", "operation.date.out_of_range")]}
      end
      payee = input.payee.strip
      label = payee.presence || (target ? I18n.t("perso.labels.transfer", label: target.label.to_s) : parts.map(&.[0].label).join(", "))
      label = label[0, 255]

      entry_id, transfer_entry_id, failure = if target
                                               post_transfer(actor, account, target, date, input.amount, label)
                                             elsif parts.size == 1
                                               post_single(actor, account, input, parts.first[0], date, label)
                                             else
                                               post_split(actor, account, input, parts, date, label)
                                             end
      return {nil, failure} if failure
      return {nil, [Records.error(FieldError::BASE, "operation.not_posted")]} unless entry_id

      row = Operation.new(entry_id: entry_id, transfer_entry_id: transfer_entry_id, account_id: account.id,
        to_account_id: target.try(&.id), kind: input.kind, payee: payee, member_id: input.member_id,
        note: input.note.strip, previous_entry_id: previous_entry_id, status: "active", created_by_id: actor.user_id)
      row.save!
      {row, [] of FieldError}
    end

    private def self.post_single(actor : Actor, account : Account, input : Api::OperationInput, category : Category,
                                 date : Time, label : String) : {Int64?, Int64?, Array(FieldError)?}
      amount = input.kind == "income" ? input.amount : -input.amount
      result = Acc.post_financial(actor, Acc::FinancialInput.new(ledger_id: account.ledger_id!.to_i64, date: date,
        lines: [Acc::PaymentLineInput.new(amount, account: category.account.to_s, label: label)], source: source))
      return {nil, nil, core_errors(result.errors)} if result.failure?
      {result.value!.first.id, nil, nil}
    end

    private def self.post_split(actor : Actor, account : Account, input : Api::OperationInput,
                                parts : Array({Category, BigDecimal}), date : Time, label : String) : {Int64?, Int64?, Array(FieldError)?}
      income = input.kind == "income"
      bank_side = income ? Acc::Side::Debit : Acc::Side::Credit
      lines = [Acc::EntryLineInput.new(account: account.account_number.to_s, side: bank_side, amount: input.amount, label: label)]
      parts.each do |(category, amount)|
        lines << Acc::EntryLineInput.new(account: category.account.to_s, side: bank_side.opposite, amount: amount, label: label)
      end
      result = Acc.post_entry(actor, Acc::EntryInput.new(ledger_id: account.ledger_id!.to_i64, date: date, lines: lines,
        label: label, source: source))
      return {nil, nil, core_errors(result.errors)} if result.failure?
      {result.value!.id, nil, nil}
    end

    private def self.post_transfer(actor : Actor, from : Account, to : Account, date : Time, amount : BigDecimal,
                                   label : String) : {Int64?, Int64?, Array(FieldError)?}
      transit = transit_account
      reference = source
      outgoing = Acc.post_financial(actor, Acc::FinancialInput.new(ledger_id: from.ledger_id!.to_i64, date: date,
        lines: [Acc::PaymentLineInput.new(-amount, account: transit, label: label)], source: "#{reference}:out"))
      return {nil, nil, core_errors(outgoing.errors)} if outgoing.failure?
      into = Acc.post_financial(actor, Acc::FinancialInput.new(ledger_id: to.ledger_id!.to_i64, date: date,
        lines: [Acc::PaymentLineInput.new(amount, account: transit, label: label)], source: "#{reference}:in"))
      return {nil, nil, core_errors(into.errors, "to_account_id")} if into.failure?
      {outgoing.value!.first.id, into.value!.first.id, nil}
    end

    # Erreurs de la Comptabilité rangées sous les champs de l'opération.
    private def self.core_errors(errors : Array(FieldError), fallback : String = FieldError::BASE) : Array(FieldError)
      errors.map do |error|
        field = case error.field
                when "date"                 then "date"
                when .starts_with?("lines") then "category_id"
                when "ledger_id"            then "account_id"
                else                             fallback
                end
        FieldError.new(field, error.key, error.params)
      end
    end

    # --- Correction et suppression ----------------------------------------------------

    # Écritures d'une opération active (ou d'une écriture d'un compte du foyer
    # que l'extension n'a pas saisie) : `{ligne de l'extension, écritures}`.
    def self.active!(actor : Actor, entry_id : Int64) : {Operation?, Array(Acc::EntryView)}
      entry = Acc.entry(actor, entry_id)
      raise Partiduo::Api::NotFound.new("perso_operation", entry_id) if entry.cancelled? || entry.reversal?
      row = Operation.filter(entry_id: entry_id).first || Operation.filter(transfer_entry_id: entry_id).first
      if row
        raise Partiduo::Api::NotFound.new("perso_operation", entry_id) unless row.status == "active"
        entries = [Acc.entry(Records.system, row.entry_id!.to_i64)]
        row.transfer_entry_id.try { |id| entries << Acc.entry(Records.system, id.to_i64) }
        return {row, entries}
      end
      raise Partiduo::Api::NotFound.new("perso_operation", entry_id) unless Account.filter(ledger_id: entry.ledger_id).exists?
      {nil, [entry]}
    end

    # Extourne les écritures d'une opération (à leur date). L'abonné de
    # `partiduo-bankimport` rend alors à traiter la ligne d'un relevé dont
    # l'écriture est extournée (D-BKI-009) : une suppression l'écarte
    # (`discard_bank_lines`), une correction la rattache à la nouvelle
    # écriture (`relink_bank_lines`, D-PER-022). Rend l'extourne de la
    # première écriture.
    def self.reverse(actor : Actor, entries : Array(Acc::EntryView), label : String) : {Int64?, Array(FieldError)}
      first = nil
      entries.each do |entry|
        result = Acc.cancel_entry(actor, Acc::CancelEntryInput.new(entry_id: entry.id, label: label))
        return {nil, result.errors} if result.failure?
        first ||= result.value!.id
      end
      {first, [] of FieldError}
    end

    # Ligne de relevé importé d'une écriture transférée (`bankimport:line:<id>`).
    def self.bank_line_id(entry : Acc::EntryView) : Int64?
      return unless entry.source.starts_with?(BANKIMPORT_SOURCE)
      entry.source.lchop(BANKIMPORT_SOURCE).to_i64?
    end

    # Opération supprimée : les lignes de relevé de ses écritures sont
    # écartées, pour qu'un nouveau transfert ne refasse pas l'écriture
    # (elles restent pour la détection des doublons).
    def self.discard_bank_lines(actor : Actor, entries : Array(Acc::EntryView)) : Nil
      ids = entries.compact_map { |entry| bank_line_id(entry) }
      return if ids.empty? || !actor.can?(Bankimport::Api::IMPORT)
      Bankimport::Api.discard(actor, ids)
    rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
      nil
    end

    # Opération corrigée (A-PER-3, D-PER-022) : la ligne de relevé de chaque
    # écriture extournée est rattachée à la nouvelle écriture du même
    # journal (`Bankimport::Api.relink`) — elle reste transférée, son relevé
    # pointé est refait. Si le rattachement est refusé (montant ou date
    # changés, compte changé, droits), la ligne est écartée comme avant.
    def self.relink_bank_lines(actor : Actor, entries : Array(Acc::EntryView), created : Operation) : Nil
      return unless actor.can?(Bankimport::Api::IMPORT)
      fresh = [created.entry_id, created.transfer_entry_id].compact.map { |id| Acc.entry(Records.system, id.to_i64) }
      entries.each do |entry|
        line_id = bank_line_id(entry) || next
        target = fresh.find(&.ledger_id.==(entry.ledger_id))
        relinked = target && Bankimport::Api.relink(actor, line_id, target.id).success?
        Bankimport::Api.discard(actor, [line_id]) unless relinked
      end
    rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
      nil
    end

    # Marque l'ancienne version (en la créant pour une écriture que
    # l'extension n'avait pas saisie).
    def self.retire(row : Operation?, entry : Acc::EntryView, status : String, reversal_id : Int64?, actor : Actor) : Nil
      row ||= Operation.new(entry_id: entry.id, account_id: Account.filter(ledger_id: entry.ledger_id).first!.id,
        kind: "expense", payee: entry.label[0, MAX_PAYEE], created_by_id: entry.created_by_id)
      row.status = status
      row.reversal_entry_id = reversal_id
      row.save!
    end

    # --- Vues -------------------------------------------------------------------------

    # Contexte de présentation : comptes du foyer, catégories, membres.
    class Context
      getter accounts_by_number : Hash(String, Account)
      getter accounts_by_ledger : Hash(Int64, Account)
      getter categories : Hash(String, {Int64, String})
      getter members : Hash(Int64, String)
      getter transit : String

      def initialize
        rows = Account.all.to_a
        @accounts_by_number = rows.to_h { |row| {row.account_number.to_s, row} }
        @accounts_by_ledger = rows.to_h { |row| {row.ledger_id!.to_i64, row} }
        @categories = Categories.labels_by_account
        @members = Records.member_names
        @transit = Operations.transit_account
      end
    end

    # Bénéficiaires des lignes de relevé transférées vers ces écritures
    # (`Bankimport::Api.lines_by_entry`, A-PER-2), par écriture ; vide si
    # l'acteur ne lit pas les relevés.
    def self.bank_payees(actor : Actor, entries : Array(Acc::EntryView)) : Hash(Int64, String)
      ids = entries.select(&.source.starts_with?(BANKIMPORT_SOURCE)).map(&.id)
      return {} of Int64 => String if ids.empty? || !actor.can?(Bankimport::Api::READ)
      Bankimport::Api.lines_by_entry(actor, ids).transform_values(&.payee).reject { |_, payee| payee.empty? }
    rescue Partiduo::Api::AccessDenied
      {} of Int64 => String
    end

    # Bénéficiaire présenté (D-PER-017) : celui de l'opération saisie, sinon
    # celui de la ligne de relevé transférée (`bank_payee`), sinon le
    # libellé de l'écriture.
    def self.view(context : Context, entry : Acc::EntryView, row : Operation?, writable : Bool,
                  bank_payee : String? = nil) : Api::OperationView?
      account = context.accounts_by_ledger[entry.ledger_id]? || return
      amount, splits, to_account = parts(context, entry, account, row)
      kind = to_account ? "transfer" : (row.try(&.kind.to_s) || (amount >= 0 ? "income" : "expense"))
      member_id = row.try(&.member_id.try(&.to_i64))
      Api::OperationView.new(
        entry_id: entry.id, account_id: account.id!.to_i64, account_label: account.label.to_s, date: entry.date,
        amount: amount, kind: kind, splits: splits, to_account_id: to_account.try(&.id!.to_i64),
        payee: row.try(&.payee.to_s).presence || bank_payee.presence || entry.label, member_id: member_id,
        member_name: member_id.try { |id| context.members[id]? }, note: row.try(&.note.to_s) || "",
        source: source_of(entry), versions: version_count(row), writable: writable)
    end

    # Montant pour le compte, parts (catégories, autre compte du foyer,
    # compte du plan hors catégorie) et compte de destination d'un virement.
    private def self.parts(context : Context, entry : Acc::EntryView, account : Account,
                           row : Operation?) : {BigDecimal, Array(Api::SplitView), Account?}
      number = account.account_number.to_s
      amount = Records::ZERO
      splits = [] of Api::SplitView
      to_account = nil
      postings = entry.lines
      postings.each do |line|
        signed = line.side.debit? ? line.amount : -line.amount
        if line.account_number == number
          amount += signed
        elsif found = context.categories[line.account_number]?
          splits << Api::SplitView.new(found[0], found[1], -signed)
        elsif other = context.accounts_by_number[line.account_number]? || transfer_target(context, line, entry, row)
          to_account = other
          splits << Api::SplitView.new(nil, other.label.to_s, -signed)
        else
          splits << Api::SplitView.new(nil, line.account_label, -signed)
        end
      end
      {amount, splits, to_account}
    end

    # Autre jambe d'un virement passé par le compte de passage.
    private def self.transfer_target(context : Context, line : Acc::EntryLineView, entry : Acc::EntryView, row : Operation?) : Account?
      return unless row && line.account_number == context.transit
      target_id = row.entry_id == entry.id ? row.to_account_id : row.account_id
      target_id.try { |id| Account.filter(id: id).first }
    end

    private def self.source_of(entry : Acc::EntryView) : String
      if entry.source.starts_with?(SOURCE)
        "perso"
      elsif entry.source.starts_with?(BANKIMPORT_SOURCE)
        "bankimport"
      else
        "other"
      end
    end

    # Nombre de versions : celle-ci et celles qu'elle a remplacées.
    private def self.version_count(row : Operation?) : Int32
      versions = 1
      previous = row.try(&.previous_entry_id)
      while previous && versions < 50
        versions += 1
        previous = Operation.filter(entry_id: previous).first.try(&.previous_entry_id)
      end
      versions
    end

    # Opérations des comptes visibles (D4), de la plus récente à la plus
    # ancienne ; les écritures extournées et les extournes n'en sont pas.
    def self.list(actor : Actor, query : Api::OperationQuery) : Array(Api::OperationView)
      context = Context.new
      accounts = Records.visible_accounts(actor)
      query.account_id.try { |id| accounts = accounts.select { |(row, _)| row.id == id } }
      wanted_categories = query.category_id.try { |id| category_accounts(id) }
      text = query.text.try(&.strip.downcase).presence
      views = [] of Api::OperationView
      accounts.each do |(account, ledger)|
        entries = fetch(actor, ledger.id, query.date_from, query.date_to)
        rows = Operation.filter(entry_id__in: entries.map(&.id)).to_a.index_by(&.entry_id!.to_i64)
        legs = Operation.filter(transfer_entry_id__in: entries.map(&.id)).to_a.index_by(&.transfer_entry_id!.to_i64)
        payees = bank_payees(actor, entries)
        entries.each do |entry|
          row = rows[entry.id]? || legs[entry.id]?
          view = view(context, entry, row, ledger.access.writable? && !account.closed, payees[entry.id]?) || next
          next if wanted_categories && view.splits.none? { |split| split.category_id.try { |id| wanted_categories.includes?(id) } }
          next if query.member_id && view.member_id != query.member_id
          next if text && !(view.payee.downcase.includes?(text) || view.category_label.downcase.includes?(text) ||
                  view.note.downcase.includes?(text))
          views << view
        end
      end
      views.sort_by! { |view| {view.date, view.entry_id} }.reverse!
      views.first(query.limit.clamp(1, Api::MAX_LIMIT * 10))
    end

    # Catégorie et ses sous-catégories.
    def self.category_accounts(id : Int64) : Set(Int64)
      ids = Set{id}
      Category.filter(parent_id: id).each { |child| ids << child.id!.to_i64 }
      ids
    end

    # Écritures non annulées d'un journal sur la période, par pages.
    def self.fetch(actor : Actor, ledger_id : Int64, from : Time?, to : Time?) : Array(Acc::EntryView)
      list = [] of Acc::EntryView
      offset = 0
      loop do
        page = Acc.entries(actor, Acc::EntryQuery.new(ledger_id: ledger_id, date_from: from, date_to: to,
          include_cancelled: false, offset: offset, limit: 500))
        list.concat(page)
        break if page.size < 500
        offset += 500
      end
      list
    end

    # Versions d'une opération, de la plus récente à la plus ancienne.
    def self.versions(entry_id : Int64) : Array(Api::VersionView)
      list = [] of Api::VersionView
      current = entry_id
      seen = Set(Int64).new
      while current && !seen.includes?(current) && list.size < 50
        seen << current
        entry = begin
          Acc.entry(Records.system, current)
        rescue Partiduo::Api::NotFound
          break
        end
        row = Operation.filter(entry_id: current).first
        status = row.try(&.status.to_s) || (entry.cancelled? ? "deleted" : "active")
        amount = entry.lines.select { |line| Account.filter(account_number: line.account_number).exists? }
          .sum(Records::ZERO) { |line| line.side.debit? ? line.amount : -line.amount }
        list << Api::VersionView.new(entry_id: current, date: entry.date, amount: amount, label: entry.label,
          status: status, created_by_name: Records.member_name_for_user(entry.created_by_id), created_at: entry.created_at,
          reversal_entry_id: entry.reversed_by_id)
        current = row.try(&.previous_entry_id.try(&.to_i64))
      end
      list
    end

    def self.document_view(row : Document) : Api::DocumentView
      filename = begin
        Partiduo::Api::Core.attachment(Records.system, row.attachment_id!.to_i64).filename
      rescue Partiduo::Api::NotFound
        ""
      end
      Api::DocumentView.new(id: row.id!.to_i64, attachment_id: row.attachment_id!.to_i64, kind: row.kind.to_s,
        label: row.label.to_s, filename: filename, entry_id: row.entry_id.try(&.to_i64),
        account_id: row.account_id.try(&.to_i64), year: row.year.try(&.to_i32), created_at: row.created_at || Time.utc)
    end
  end
end
