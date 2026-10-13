# SPDX-License-Identifier: AGPL-3.0-or-later

# Ligne de commande Marten de l'extension, composée avec le cœur et
# l'interface, avec l'import des relevés, comme dans une distribution :
# `crystal run manage.cr -- <commande>` (`migrate`…).
require "partiduo-ui-bulma/partiduo_ui"
require "partiduo-bankimport/ui/bulma"
require "./src/partiduo-perso"
require "./ui/bulma/bulma"
require "./config/settings/base"
require "./config/settings/**"
require "partiduo/cli"
require "partiduo-bankimport/cli"
require "./src/partiduo-perso/cli"

Marten.setup
Marten::CLI.run
