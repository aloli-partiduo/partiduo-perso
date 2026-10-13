# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Ui
    alias Table = PartiduoUi::Table

    def self.url(name : String, **params) : String
      Marten.routes.reverse("perso:#{name}", **params)
    end

    # URL avec paramètres de requête.
    def self.url_with(name : String, query : Hash(String, String), **params) : String
      base = Marten.routes.reverse("perso:#{name}", **params)
      query.empty? ? base : "#{base}?#{URI::Params.encode(query)}"
    end

    # Premier jour du mois `months` mois plus tard (le jour donné est le
    # premier d'un mois).
    def self.add_months(first : Time, months : Int32) : Time
      index = first.year * 12 + (first.month - 1) + months
      Time.utc(index // 12, index % 12 + 1, 1)
    end

    def self.end_of_month(time : Time) : Time
      Time.utc(time.year, time.month, Time.days_in_month(time.year, time.month))
    end

    # Présentation des vues du contrat (interne à l'interface).
    module Present
      alias Api = Perso::Api

      def self.money(fmt : PartiduoUi::Format, value : BigDecimal) : Table::Cell
        Table::Cell.new(fmt.amount(value), sort: value, csv: fmt.csv_amount(value))
      end

      def self.date(fmt : PartiduoUi::Format, value : Time?) : Table::Cell
        Table::Cell.new(fmt.date(value), sort: value.try(&.to_s("%Y-%m-%d")) || "")
      end

      def self.percent(fmt : PartiduoUi::Format, value : BigDecimal?) : String
        value.try { |rate| "#{fmt.number(rate, 4)} %" } || ""
      end

      def self.holders(view : Api::AccountView) : String
        view.holders.empty? ? I18n.t("perso.labels.household") : view.holders.map(&.display_name).join(", ")
      end
    end
  end
end
