# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Abonnés des événements du cœur (ADR-003 D7), appelés dans la transaction
  # de l'opération, l'extension active. Interne.
  module Subscriptions
    alias Acc = Partiduo::Api::Accounting

    # `entry.cancelled` (D-PER-008) : une écriture d'une opération est
    # extournée — par l'extension (qui précise ensuite l'état), ou hors
    # d'elle, dans la Comptabilité : l'opération est retirée ; une échéance
    # confirmée par cette écriture redevient à traiter.
    def self.entry_cancelled(event : Partiduo::Events::Event) : Nil
      entry_id = event["entry_id"].to_i64
      reversal = event["reversal_entry_id"]?.try(&.to_i64?) || entry_id
      now = Time.utc
      Operation.filter(entry_id: entry_id, status: "active").update(status: "deleted", reversal_entry_id: reversal, updated_at: now)
      Operation.filter(transfer_entry_id: entry_id, status: "active").update(status: "deleted", reversal_entry_id: reversal, updated_at: now)
      Occurrence.filter(entry_id: entry_id).delete
      Installment.filter(entry_id: entry_id).delete
      Installment.filter(transfer_entry_id: entry_id).update(transfer_entry_id: nil, updated_at: now)
    end

    # `entry.posted` (D-PER-011) : une écriture transférée d'un relevé
    # importé (`partiduo-bankimport`) sur un compte du foyer rapproche
    # l'échéance prévue qu'elle règle — opération récurrente ou échéance
    # d'emprunt. Rien n'est écrit en comptabilité.
    def self.entry_posted(event : Partiduo::Events::Event) : Nil
      source = event["source"]? || return
      return unless source.starts_with?(Operations::BANKIMPORT_SOURCE)
      entry = Acc.entry(Records.system, event["entry_id"].to_i64)
      account = Account.filter(ledger_id: entry.ledger_id).first || return
      number = account.account_number.to_s
      amount = entry.lines.select(&.account_number.==(number)).sum(BigDecimal.new(0)) do |line|
        line.side.debit? ? line.amount : -line.amount
      end
      return if amount.zero?
      counterparts = entry.lines.map(&.account_number).reject(&.==(number)).to_set
      Schedule.match(entry, account, amount, counterparts) || Loans.match(entry, account, amount)
    rescue Partiduo::Api::NotFound
      nil
    end
  end
end
