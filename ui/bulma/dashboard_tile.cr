# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Ui
    # Tuiles du foyer sur les tableaux de bord du dossier (ADR-011 D4, D8,
    # D9) : trésorerie, patrimoine net, échéancier (retards, échéances des
    # trente jours), budget (catégories dépassées). Rien si l'extension est
    # inactive, le dossier celui d'une entreprise ou l'acteur sans droit.
    module Tile
      def self.all(actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) : Array(PartiduoUi::Dashboard::Tile)
        view = Api.tile(actor) || return [] of PartiduoUi::Dashboard::Tile
        tiles = [] of PartiduoUi::Dashboard::Tile
        tiles << PartiduoUi::Dashboard::Tile.new(Perso::CODE, I18n.t("perso_ui.tile.cash"), fmt.amount(view.cash),
          sub: I18n.t("perso_ui.tile.accounts", count: view.account_count), url: Ui.url("accounts"))
        tiles << PartiduoUi::Dashboard::Tile.new(Perso::CODE, I18n.t("perso_ui.tile.net_worth"), fmt.amount(view.net_worth),
          url: Ui.url("wealth"))
        alert = view.overdue.zero? ? nil : I18n.t("perso_ui.tile.overdue", count: view.overdue)
        tiles << PartiduoUi::Dashboard::Tile.new(Perso::CODE, I18n.t("perso_ui.tile.schedule"), view.upcoming.to_s,
          sub: I18n.t("perso_ui.tile.upcoming"), alert: alert, url: Ui.url("schedule"))
        unless view.over_budget.empty?
          tiles << PartiduoUi::Dashboard::Tile.new(Perso::CODE, I18n.t("perso_ui.tile.budget"), view.over_budget.size.to_s,
            sub: I18n.t("perso_ui.tile.over_budget"), alert: view.over_budget.first(3).join(", "), url: Ui.url("budgets"))
        end
        tiles
      end
    end
  end
end

# Point d'accroche de l'interface commune (`PartiduoUi::Extensions.tile`) :
# appelé seulement quand l'extension est active, dans l'interface
# « Comptabilité » ; l'interface « Recettes et dépenses » reçoit les mêmes
# tuiles par sa variante (`simple_mode`).
PartiduoUi::Extensions.tile Perso::CODE do |actor, fmt|
  Perso::Ui::Tile.all(actor, fmt)
end
