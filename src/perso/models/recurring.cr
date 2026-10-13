# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Opération récurrente (D7, D-PER-010) : modèle d'opération (compte, sens,
  # catégorie ou compte de destination d'un virement, bénéficiaire, membre),
  # montant fixe ou estimé, fréquence (`monthly`, `quarterly`, `yearly`,
  # `days` tous les `interval_days` jours), première et dernière dates, report
  # au jour ouvré suivant. Interne.
  class Recurring < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account_id, :big_int
    field :kind, :string, max_size: 16
    field :category_id, :big_int, blank: true, null: true
    field :to_account_id, :big_int, blank: true, null: true
    field :payee, :string, max_size: 120
    field :amount, :decimal, max_digits: 20, decimal_places: 2
    field :estimated, :bool, default: false
    field :frequency, :string, max_size: 16, default: "monthly"
    field :interval_days, :int, blank: true, null: true
    field :first_on, :date
    field :last_on, :date, blank: true, null: true
    field :business_days, :bool, default: false
    field :member_id, :big_int, blank: true, null: true
    field :active, :bool, default: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Échéance d'une opération récurrente qui a été traitée : confirmée (son
  # écriture `entry_id`, à la main ou par le rapprochement d'une ligne
  # importée, `matched`) ou écartée (`skipped`). Une échéance sans ligne est
  # à venir, ou en retard si sa date est passée. Interne.
  class Occurrence < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :recurring_id, :big_int
    field :due_on, :date
    field :status, :string, max_size: 16
    field :entry_id, :big_int, blank: true, null: true
    field :amount, :decimal, max_digits: 20, decimal_places: 2, blank: true, null: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
