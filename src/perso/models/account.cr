# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Compte du foyer (D5, D-PER-006) : un journal financier de la
  # Comptabilité (`ledger_id`, relu par le contrat, sans clé étrangère),
  # adossé au compte de bilan `account_number` par la fiche Banque
  # `card_code`. L'extension en tient la nature, le genre d'un bien,
  # l'établissement, le taux et le plafond d'un livret, la date d'ouverture.
  # Son solde est toujours celui de la Comptabilité. Interne.
  class Account < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :ledger_id, :big_int, unique: true
    field :account_number, :string, max_size: 40, unique: true
    field :card_code, :string, max_size: 64, blank: true, default: ""
    field :nature, :string, max_size: 16
    field :asset_kind, :string, max_size: 16, blank: true, default: ""
    field :label, :string, max_size: 120
    field :institution, :string, max_size: 120, blank: true, default: ""
    field :rate, :decimal, max_digits: 9, decimal_places: 4, blank: true, null: true
    field :ceiling, :decimal, max_digits: 20, decimal_places: 2, blank: true, null: true
    field :opened_on, :date, blank: true, null: true
    field :closed, :bool, default: false
    field :position, :int, default: 100

    with_timestamp_fields
  end

  # Titulaire d'un compte : un membre. Aucun titulaire : le foyer. Interne.
  class AccountHolder < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account_id, :big_int
    field :member_id, :big_int
  end
end
