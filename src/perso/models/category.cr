# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Catégorie de recettes ou de dépenses (D3, D-PER-005) : un compte du plan
  # (`account`, classe 6 ou 7), jamais montré par son numéro ; parent pour
  # le second niveau ; sens (`expense`, `income`) ; étiquette fiscale
  # facultative (`tax_tag`, D10) ; rang ; active ou retirée des listes.
  # Interne.
  class Category < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account, :string, max_size: 40, unique: true
    field :parent_id, :big_int, blank: true, null: true
    field :label, :string, max_size: 120
    field :kind, :string, max_size: 8
    field :tax_tag, :string, max_size: 32, blank: true, default: ""
    field :position, :int, default: 100
    field :active, :bool, default: true

    with_timestamp_fields
  end
end
