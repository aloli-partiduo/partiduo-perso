# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Barème kilométrique daté (D10, D-PER-016), tenu par l'administrateur :
  # pour une année et une puissance fiscale, une tranche de distance
  # (`max_km` : borne haute, nulle pour la dernière) et sa formule
  # `distance × coefficient + constante`. Les valeurs de départ sont dans
  # `data/mileage.yml`. Interne.
  class MileageRate < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :year, :int
    field :fiscal_power, :int
    field :max_km, :int, blank: true, null: true
    field :coefficient, :decimal, max_digits: 10, decimal_places: 4
    field :constant, :decimal, max_digits: 20, decimal_places: 2, default: BigDecimal.new(0)
  end

  # Déplacements professionnels d'un membre sur une année, pour les frais
  # réels (D10). Interne.
  class Trip < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :year, :int
    field :member_id, :big_int, blank: true, null: true
    field :fiscal_power, :int
    field :kilometers, :int
    field :label, :string, max_size: 255, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
