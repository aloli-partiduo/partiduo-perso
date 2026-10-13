# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension des finances personnelles d'un foyer
# (ADR-005 D4, ADR-011) : opérations en recettes et dépenses, comptes du
# foyer, échéancier et opérations récurrentes, emprunts et tableaux
# d'amortissement, budgets, patrimoine et valorisations, aide à la
# déclaration de revenus ; catégories, règles, membres et barème dans les
# paramètres. Montée par `partiduo-ui-bulma` sous `/ext/PERSO/` (ADR-003
# D3). La distribution la requiert après l'interface et l'import des
# relevés :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-bankimport"
# require "partiduo-bankimport/ui/bulma"
# require "partiduo-perso"
# require "partiduo-perso/ui/bulma"
# ```
#
# puis ajoute `Perso::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Perso::Api`, `Bankimport::Api` et
# `Partiduo::Api` (vérifié par `spec/architecture/conventions_spec.cr`) ;
# le contrôle d'accès est fait par l'interface, avant le handler, à partir
# du montage, puis par le contrat.
require "../../src/partiduo-perso"

require "./presenters"
require "./handlers/base"
require "./handlers/**"
require "./dashboard_tile"

module Perso
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/perso/`), fichiers statiques (`assets/perso/`) et libellés
    # d'écran (`locales/`, clés `perso_ui.*`).
    class App < Marten::App
      label "perso_ui"
    end

    INSTALLED_APPS = [Perso::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/PERSO/`, nommées `perso:<nom>` : celles que
    # citent les menus du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Perso::Ui::IndexHandler, name: "index"
      path "/operations", Perso::Ui::OperationsHandler, name: "operations"
      path "/operations/new", Perso::Ui::OperationNewHandler, name: "operation_new"
      path "/operations/<id:int>", Perso::Ui::OperationHandler, name: "operation"
      path "/operations/<id:int>/edit", Perso::Ui::OperationEditHandler, name: "operation_edit"
      path "/operations/<id:int>/delete", Perso::Ui::OperationDeleteHandler, name: "operation_delete"
      path "/operations/<id:int>/documents", Perso::Ui::OperationDocumentHandler, name: "operation_document"
      path "/documents/<id:int>", Perso::Ui::DocumentHandler, name: "document"
      path "/documents/<id:int>/delete", Perso::Ui::DocumentDeleteHandler, name: "document_delete"
      path "/accounts", Perso::Ui::AccountsHandler, name: "accounts"
      path "/accounts/new", Perso::Ui::AccountNewHandler, name: "account_new"
      path "/accounts/<id:int>", Perso::Ui::AccountHandler, name: "account"
      path "/accounts/<id:int>/edit", Perso::Ui::AccountEditHandler, name: "account_edit"
      path "/accounts/<id:int>/valuations", Perso::Ui::ValuationAddHandler, name: "valuation_add"
      path "/valuations/<id:int>/delete", Perso::Ui::ValuationDeleteHandler, name: "valuation_delete"
      path "/accounts/<id:int>/loan", Perso::Ui::LoanNewHandler, name: "loan_new"
      path "/loans/<id:int>/prepay", Perso::Ui::LoanPrepayHandler, name: "loan_prepay"
      path "/loans/<id:int>/confirm", Perso::Ui::LoanConfirmHandler, name: "loan_confirm"
      path "/schedule", Perso::Ui::ScheduleHandler, name: "schedule"
      path "/schedule/confirm", Perso::Ui::ScheduleConfirmHandler, name: "schedule_confirm"
      path "/schedule/skip", Perso::Ui::ScheduleSkipHandler, name: "schedule_skip"
      path "/schedule/reopen", Perso::Ui::ScheduleReopenHandler, name: "schedule_reopen"
      path "/recurring", Perso::Ui::RecurringsHandler, name: "recurrings"
      path "/recurring/new", Perso::Ui::RecurringNewHandler, name: "recurring_new"
      path "/recurring/<id:int>/edit", Perso::Ui::RecurringEditHandler, name: "recurring_edit"
      path "/recurring/<id:int>/delete", Perso::Ui::RecurringDeleteHandler, name: "recurring_delete"
      path "/budgets", Perso::Ui::BudgetsHandler, name: "budgets"
      path "/budgets/create", Perso::Ui::BudgetCreateHandler, name: "budget_create"
      path "/budgets/<year:int>/lines", Perso::Ui::BudgetLineHandler, name: "budget_line"
      path "/budgets/<year:int>/lines/<id:int>/delete", Perso::Ui::BudgetLineDeleteHandler, name: "budget_line_delete"
      path "/budgets/<year:int>/propose", Perso::Ui::BudgetProposeHandler, name: "budget_propose"
      path "/wealth", Perso::Ui::WealthHandler, name: "wealth"
      path "/tax", Perso::Ui::TaxHandler, name: "tax"
      path "/tax/csv", Perso::Ui::TaxCsvHandler, name: "tax_csv"
      path "/tax/pdf", Perso::Ui::TaxPdfHandler, name: "tax_pdf"
      path "/tax/trips", Perso::Ui::TripAddHandler, name: "trip_add"
      path "/tax/trips/<id:int>/delete", Perso::Ui::TripDeleteHandler, name: "trip_delete"
      path "/exports/<kind:str>", Perso::Ui::ExportHandler, name: "export"
      path "/categories", Perso::Ui::CategoriesHandler, name: "categories"
      path "/categories/load", Perso::Ui::CategoriesLoadHandler, name: "categories_load"
      path "/categories/<id:int>/edit", Perso::Ui::CategoryEditHandler, name: "category_edit"
      path "/categories/<id:int>/delete", Perso::Ui::CategoryDeleteHandler, name: "category_delete"
      path "/rules", Perso::Ui::RulesHandler, name: "rules"
      path "/rules/<id:int>/edit", Perso::Ui::RuleEditHandler, name: "rule_edit"
      path "/rules/<id:int>/delete", Perso::Ui::RuleDeleteHandler, name: "rule_delete"
      path "/members", Perso::Ui::MembersHandler, name: "members"
      path "/members/<id:int>/edit", Perso::Ui::MemberEditHandler, name: "member_edit"
      path "/members/<id:int>/delete", Perso::Ui::MemberDeleteHandler, name: "member_delete"
      path "/members/<id:int>/accounts", Perso::Ui::MemberAccountsHandler, name: "member_accounts"
      path "/settings", Perso::Ui::SettingsHandler, name: "settings"
    end

    # Saisir et corriger des opérations, confirmer des échéances :
    # `perso.write` ; budgets et valorisations : `perso.budget` ; comptes,
    # emprunts, catégories, règles, membres, barème : `perso.admin` ; le
    # reste : `perso.read`. Le contrat vérifie encore les permissions du
    # cœur (écriture, extourne, pièces jointes, prévisions).
    WRITE_ROUTES = %w[operation_new operation_edit operation_delete operation_document document_delete
      schedule_confirm schedule_skip schedule_reopen recurring_new recurring_edit recurring_delete loan_confirm
      trip_add trip_delete]
    BUDGET_ROUTES = %w[valuation_add valuation_delete budget_create budget_line budget_line_delete budget_propose]
    ADMIN_ROUTES  = %w[account_new account_edit loan_new loan_prepay categories categories_load category_edit
      category_delete rules rule_edit rule_delete members member_edit member_delete member_accounts settings]

    # Menu réduit « Recettes et dépenses » du foyer (ADR-011 D4, A2) : les
    # entrées du manifeste dans l'ordre d'ADR-011 D4, et les relevés
    # importés (`partiduo-bankimport`).
    SIMPLE_MENU = [
      PartiduoUi::SimpleMode::Entry.new("DASHBOARD", "perso_ui.menu.dashboard"),
      PartiduoUi::SimpleMode::Entry.new("PERSO_OPERATIONS", "perso.menu.perso_operations"),
      PartiduoUi::SimpleMode::Entry.new("PERSO_ACCOUNTS", "perso.menu.perso_accounts"),
      PartiduoUi::SimpleMode::Entry.new("BANKIMPORT_LINES", "perso_ui.menu.statements"),
      PartiduoUi::SimpleMode::Entry.new("PERSO_SCHEDULE", "perso.menu.perso_schedule"),
      PartiduoUi::SimpleMode::Entry.new("PERSO_BUDGETS", "perso.menu.perso_budgets"),
      PartiduoUi::SimpleMode::Entry.new("PERSO_WEALTH", "perso.menu.perso_wealth"),
      PartiduoUi::SimpleMode::Entry.new("PERSO_TAX", "perso.menu.perso_tax"),
    ]
  end
end

PartiduoUi::Extensions.mount Perso::CODE, Perso::Ui::ROUTES, permission: Perso::Api::READ,
  permissions: Perso::Ui::WRITE_ROUTES.to_h { |route| {route, Perso::Api::WRITE} }
    .merge(Perso::Ui::BUDGET_ROUTES.to_h { |route| {route, Perso::Api::BUDGET} })
    .merge(Perso::Ui::ADMIN_ROUTES.to_h { |route| {route, Perso::Api::ADMIN} })

# Variante « Recettes et dépenses » du foyer (ADR-011 D4, amendement A2) :
# menu réduit, vocabulaire commun, les deux interfaces offertes, menus de la
# Comptabilité propres aux entreprises écartés (TVA, FEC, clôture), tuiles
# du tableau de bord simplifié.
PartiduoUi::Extensions.simple_mode Perso::CODE,
  read: Perso::Api::READ,
  menu: Perso::Ui::SIMPLE_MENU,
  hidden_menus: PartiduoUi::SimpleMode::BUSINESS_ACCOUNTING_MENUS,
  tiles: ->(actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) { Perso::Ui::Tile.all(actor, fmt) },
  settings_route: "perso:settings", settings_permission: Perso::Api::ADMIN, settings_label: "perso.menu.perso_settings"

# Compteur du menu « Échéancier » et ligne de « À traiter » du tableau de
# bord : échéances passées non confirmées (D7).
PartiduoUi::Extensions.counter("PERSO_SCHEDULE", route: "perso:schedule", todo: "perso_ui.todo", tone: "warn") do |actor|
  Perso::Api.overdue_count(actor)
end
