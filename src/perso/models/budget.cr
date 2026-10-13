# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Budget d'une année civile (D8, D-PER-012) : une prévision budgétaire de
  # la Comptabilité (`forecast_id`, relue par le contrat) que l'extension
  # présente sous ce nom. Interne.
  class Budget < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :year, :int, unique: true
    field :forecast_id, :big_int

    with_timestamp_fields
  end

  # Montant budgété d'une catégorie : mensuel (chaque mois) ou annuel
  # (l'année entière) ; `forecast_item_id` : l'élément de la prévision qui
  # le porte, avec sa formule du réel sur le compte de la catégorie.
  # Interne.
  class BudgetLine < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :budget_id, :big_int
    field :category_id, :big_int
    field :period_kind, :string, max_size: 8, default: "monthly"
    field :amount, :decimal, max_digits: 20, decimal_places: 2
    field :forecast_item_id, :big_int

    with_timestamp_fields
  end
end
