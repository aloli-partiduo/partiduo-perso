# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-perso` : le métier de l'extension des
# finances personnelles d'un foyer (manifeste, modèles, catégories, comptes,
# opérations, échéancier, emprunts, budgets, patrimoine, aide à la
# déclaration de revenus, contrat `Perso::Api`), sans interface. L'interface
# Bulma est dans `ui/bulma/`, requise à part par la distribution :
# `require "partiduo-perso/ui/bulma"`.
#
# L'extension dépend de l'import des relevés (`partiduo-bankimport`,
# ADR-011 D6), requis ici avant elle. La distribution ajoute ensuite
# `Perso::INSTALLED_APPS` à ses applications Marten, et
# `require "partiduo-perso/cli"` à sa ligne de commande (migrations).
require "partiduo"
require "partiduo-bankimport"

require "./perso/app"
