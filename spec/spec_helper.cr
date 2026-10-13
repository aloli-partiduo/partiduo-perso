# SPDX-License-Identifier: AGPL-3.0-or-later

ENV["MARTEN_ENV"] = "test"
# Un dossier foyer n'admet aucun module d'entreprise (ADR-011 D2) : les
# specs partent de la Comptabilité, de l'import des relevés et de
# l'extension, sans la Facturation ni l'Analytique actives par défaut.
ENV["PARTIDUO_MODULES"] ||= "accounting,bankimport,perso"

require "spec"

# Composition d'une distribution : l'interface (qui charge le cœur), l'import
# des relevés et son interface, le métier de l'extension, son interface
# Bulma, puis les réglages.
require "partiduo-ui-bulma/partiduo_ui"
require "partiduo-bankimport/ui/bulma"
require "../src/partiduo-perso"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"
# Migrations du cœur, de l'import des relevés et de l'extension.
require "partiduo/cli"
require "partiduo-bankimport/cli"
require "../src/partiduo-perso/cli"

require "marten/spec"
require "marten_auth/spec"

# Comptes, navigateur et dossier de test de l'interface, créés par le
# contrat `Partiduo::Api` (DECISIONS D-SKEL-004 du squelette).
require "../lib/partiduo-ui-bulma/spec/support/accounts"
require "../lib/partiduo-ui-bulma/spec/support/browser"
require "../lib/partiduo-ui-bulma/spec/support/reference"
require "../lib/partiduo-ui-bulma/spec/support/books"

require "./support/**"

# Date du jour figée : les opérations d'exemple sont de 2026, dans les
# années civiles créées par les specs.
SPEC_NOW = Time.utc(2026, 9, 28, 10, 0, 0)
Partiduo::Config.clock = -> { SPEC_NOW }
