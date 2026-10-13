# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Membre du foyer (D12, D-PER-013) : un utilisateur du dossier, son
  # prénom d'affichage et son rôle dans le foyer (`adult`, `minor` — rôle
  # restreint, `advisor` — conseiller extérieur en lecture seule). Les
  # droits restent ceux du cœur (profil, droits par journal). Interne.
  class Member < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :user_id, :big_int, unique: true
    field :display_name, :string, max_size: 80
    field :role, :string, max_size: 16, default: "adult"

    with_timestamp_fields
  end
end
