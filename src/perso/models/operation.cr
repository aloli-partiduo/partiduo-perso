# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Opération saisie par l'extension (D4, D-PER-007) : ce que la
  # Comptabilité ne connaît pas d'une écriture — bénéficiaire ou payeur,
  # membre concerné, note — et la suite de ses versions. L'écriture elle-même
  # (`entry_id`, et `transfer_entry_id` pour la seconde jambe d'un virement
  # entre deux comptes du foyer) est relue par le contrat, sans clé
  # étrangère.
  #
  # * `kind` : `expense`, `income`, `transfer` ;
  # * `status` : `active`, `replaced` (corrigée : extournée puis repassée,
  #   la version suivante cite `previous_entry_id`), `deleted` (extournée) ;
  # * `reversal_entry_id` : extourne de l'écriture.
  #
  # Interne.
  class Operation < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :entry_id, :big_int, unique: true
    field :transfer_entry_id, :big_int, blank: true, null: true
    field :account_id, :big_int
    field :to_account_id, :big_int, blank: true, null: true
    field :kind, :string, max_size: 16
    field :payee, :string, max_size: 120, blank: true, default: ""
    field :member_id, :big_int, blank: true, null: true
    field :note, :text, blank: true, default: ""
    field :previous_entry_id, :big_int, blank: true, null: true
    field :status, :string, max_size: 16, default: "active"
    field :reversal_entry_id, :big_int, blank: true, null: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Justificatif rangé par le socle (`Partiduo::Api::Core.store_attachment`)
  # et rattaché à une opération (son écriture), à un compte ou à une année
  # fiscale (D4). Interne.
  class Document < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :attachment_id, :big_int
    field :entry_id, :big_int, blank: true, null: true
    field :account_id, :big_int, blank: true, null: true
    field :year, :int, blank: true, null: true
    field :kind, :string, max_size: 16, default: "other"
    field :label, :string, max_size: 255, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
