# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"
require "uuid"

require "./manifest"
require "./models/**"
require "./services/calendar"
require "./services/**"
require "./api/types"
require "./api/**"
require "./initial_data"

# Extension des finances personnelles d'un foyer (ADR-011) : un dossier de
# type foyer (`household`, ADR-011 A3) se tient en recettes et dépenses par
# catégories, chacune étant un compte des classes 6 et 7 du plan réduit ;
# chaque compte du foyer (courant, livret, placement, emprunt, bien) est un
# journal financier de la Comptabilité. Toute écriture passe par le service
# d'écriture du module (`post_financial`, `post_entry`), toute correction
# par extourne (`cancel_entry`). Même plan qu'une application du cœur
# (DECISIONS C1 du cœur) : `manifest.cr`, `models/`, `migrations/`,
# `services/` (internes), `api/` (contrat public `Perso::Api`), `locales/`,
# `data/` (barème kilométrique et cases de la déclaration, datés).
module Perso
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Code du registre (ADR-003 D2) : `perso` dans `PARTIDUO_MODULES`.
  CODE = "PERSO"

  # Application Marten du métier : modèles (tables `perso_*`), migrations
  # et libellés.
  class App < Marten::App
    label "perso"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS` et celles de
  # `partiduo-bankimport`.
  INSTALLED_APPS = [Perso::App] of Marten::Apps::Config.class
end
