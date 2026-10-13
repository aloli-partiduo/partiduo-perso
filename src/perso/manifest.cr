# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension des finances personnelles d'un foyer (ADR-003
# D2, ADR-011).
#
# * Dépendances : `ACCOUNTING` — la partie double en arrière-plan est celle
#   du module, écrite par son service d'écriture (D1) ; `BANKIMPORT` —
#   l'import des relevés et ses règles de catégorisation (D6, décision du
#   9 octobre 2026).
# * Incompatibilités (ADR-011 A1, D2 ; D-PER-002) : les modules propres aux
#   entreprises (Facturation, Micro-entreprise, Profession libérale, Stock,
#   Suivi, Analytique) et les extensions d'entreprise (facturation
#   électronique et ses plateformes, Chorus Pro, télédéclarations,
#   URSSAF, relation client, modèles de factures). Le contrôle joue dans
#   les deux sens. `AMORTIS` se déclare lui-même incompatible avec `PERSO` ;
#   `SEPA` reste admis (virements groupés d'un foyer, D-SEPA-002).
# * Permissions (D12) : `perso.read` (consulter), `perso.write` (saisir et
#   corriger des opérations, confirmer des échéances), `perso.budget`
#   (budgets et valorisations), `perso.admin` (comptes, catégories, règles,
#   membres, barèmes). Le contrat du cœur exige en plus ses propres droits
#   (D-PER-004).
# * Menu : rubrique « Mon foyer » juste après le tableau de bord ;
#   catégories, règles, membres et barème sous « Paramètres ». Le menu
#   réduit « Recettes et dépenses » est déclaré par l'interface
#   (`PartiduoUi::Extensions.simple_mode`, ADR-011 A2).
# * Abonnements : `entry.cancelled` — une écriture extournée hors de
#   l'extension retire l'opération (D-PER-008) ; `entry.posted` — une
#   écriture transférée d'un relevé importé confirme l'échéance prévue
#   qu'elle règle (D-PER-011).
Partiduo::Modules.register do
  code "PERSO"
  name "perso.module.name"
  version Perso::VERSION
  requires_core "~> 0.1"
  depends_on "ACCOUNTING", "BANKIMPORT"
  incompatible_with "INVOICING", "MICRO", "LIBERAL", "STOCK", "FOLLOWUP", "ANALYTIC",
    "EINV", "SUPERPDP", "ESALINK", "CHORUSPRO", "TELEDEC", "URSSAF", "CRM", "MODELES"

  permission "perso.read"
  permission "perso.write"
  permission "perso.budget"
  permission "perso.admin"

  menu "PERSO", order: 15, permission: "perso.read"
  menu "PERSO_OPERATIONS", parent: "PERSO", order: 10, route: "perso:operations", permission: "perso.read"
  menu "PERSO_ACCOUNTS", parent: "PERSO", order: 20, route: "perso:accounts", permission: "perso.read"
  menu "PERSO_SCHEDULE", parent: "PERSO", order: 30, route: "perso:schedule", permission: "perso.read"
  menu "PERSO_BUDGETS", parent: "PERSO", order: 40, route: "perso:budgets", permission: "perso.read"
  menu "PERSO_WEALTH", parent: "PERSO", order: 50, route: "perso:wealth", permission: "perso.read"
  menu "PERSO_TAX", parent: "PERSO", order: 60, route: "perso:tax", permission: "perso.read"
  menu "PERSO_CATEGORIES", parent: "SETTINGS", order: 5, route: "perso:categories", permission: "perso.admin"
  menu "PERSO_RULES", parent: "SETTINGS", order: 6, route: "perso:rules", permission: "perso.admin"
  menu "PERSO_MEMBERS", parent: "SETTINGS", order: 7, route: "perso:members", permission: "perso.admin"
  menu "PERSO_SETTINGS", parent: "SETTINGS", order: 8, route: "perso:settings", permission: "perso.admin"

  ui "bulma", path: "ui/bulma"

  on("entry.cancelled") { |event| Perso::Subscriptions.entry_cancelled(event) }
  on("entry.posted") { |event| Perso::Subscriptions.entry_posted(event) }
end
