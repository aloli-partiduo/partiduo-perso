# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Valorisation saisie à la main d'un placement ou d'un bien (D9,
  # D-PER-014) : valeur à une date, historique gardé. Ce n'est pas une
  # écriture : la Comptabilité garde les flux réels. Interne.
  class Valuation < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account_id, :big_int
    field :valued_on, :date
    field :amount, :decimal, max_digits: 20, decimal_places: 2
    field :note, :string, max_size: 255, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Ligne d'une valorisation d'un PEA ou d'un compte-titres : titre,
  # quantité, cours saisi ; montant = quantité × cours, au centime. Interne.
  class ValuationLine < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :valuation_id, :big_int
    field :security, :string, max_size: 120
    field :quantity, :decimal, max_digits: 20, decimal_places: 6
    field :price, :decimal, max_digits: 20, decimal_places: 6
    field :amount, :decimal, max_digits: 20, decimal_places: 2
  end
end
