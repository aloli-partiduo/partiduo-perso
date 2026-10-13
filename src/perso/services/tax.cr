# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Aide à la déclaration de revenus (D10, D-PER-016) : récapitulatifs
  # d'une année civile tirés des étiquettes fiscales des catégories, frais
  # kilométriques selon le barème daté, correspondance avec les cases de la
  # déclaration (table datée, présentée comme une aide). Pas de
  # télédéclaration, pas de calcul de l'impôt. Interne.
  module Tax
    alias FieldError = Partiduo::Api::FieldError
    alias Actor = Partiduo::Api::Actor

    ZERO = BigDecimal.new(0)

    MILEAGE = YAML.parse({{ read_file("#{__DIR__}/../data/mileage.yml") }})
    BOXES   = YAML.parse({{ read_file("#{__DIR__}/../data/tax_boxes.yml") }})

    # Étiquettes de chaque rubrique : celles qui comptent en plus, celles
    # qui comptent en moins (aides perçues), et leur sens.
    SECTIONS = {
      "donations"             => %w[donation],
      "home_employment"       => %w[home_employment],
      "professional_expenses" => %w[professional_expenses],
      "rental"                => %w[rental_income],
    }
    DEDUCTED = {"home_employment" => %w[home_employment_aid], "rental" => %w[rental_charges]}

    # Tranche du barème kilométrique.
    record Rate, max_km : Int32?, coefficient : BigDecimal, constant : BigDecimal

    # --- Barème kilométrique --------------------------------------------------------------

    # Barème retenu pour une année : celui que l'administrateur a saisi pour
    # la dernière année jusqu'à `year`, sinon les valeurs de départ ; rend
    # l'année retenue et les tranches par puissance.
    def self.rates(year : Int32, regime : String = Records.regime) : {Int32?, Hash(Int32, Array(Rate))}
      stored = MileageRate.filter(year__lte: year).order("-year").first.try(&.year.try(&.to_i32))
      if stored
        rows = MileageRate.filter(year: stored).to_a
        table = rows.group_by(&.fiscal_power!.to_i32).transform_values do |list|
          list.map { |row| Rate.new(row.max_km.try(&.to_i32), row.coefficient!, row.constant || ZERO) }
        end
        return {stored, sort(table)}
      end
      defaults(year, regime)
    end

    def self.defaults(year : Int32, regime : String) : {Int32?, Hash(Int32, Array(Rate))}
      years = MILEAGE[regime]?.try(&.as_h?) || return {nil, {} of Int32 => Array(Rate)}
      keys = years.keys.compact_map(&.as_i?)
      chosen = keys.select { |item| item <= year }.max? || keys.min?
      return {nil, {} of Int32 => Array(Rate)} if chosen.nil?
      table = {} of Int32 => Array(Rate)
      years.each do |key, powers|
        next unless key.as_i? == chosen
        powers.as_h.each do |power, bands|
          table[power.as_i] = bands.as_a.map do |band|
            Rate.new(band["max_km"].as_i?, BigDecimal.new(band["coefficient"].as_s), BigDecimal.new(band["constant"].as_s))
          end
        end
      end
      {chosen, sort(table)}
    end

    private def self.sort(table : Hash(Int32, Array(Rate))) : Hash(Int32, Array(Rate))
      table.transform_values { |list| list.sort_by { |rate| rate.max_km || Int32::MAX } }
    end

    # Indemnité kilométrique d'une distance annuelle : la tranche de la
    # puissance (la plus forte puissance du barème au-delà), arrondie au
    # centime.
    def self.allowance(table : Hash(Int32, Array(Rate)), power : Int32, kilometers : Int32) : BigDecimal
      return ZERO if table.empty?
      key = table.keys.select { |item| item <= power }.max? || table.keys.min
      bands = table[key]
      band = bands.find { |rate| rate.max_km.nil? || kilometers <= (rate.max_km || 0) } || bands.last
      Records.cents(BigDecimal.new(kilometers) * band.coefficient + band.constant)
    end

    # --- Cases ----------------------------------------------------------------------------

    def self.boxes(year : Int32, regime : String = Records.regime) : {Int32?, Hash(String, Array(String))}
      years = BOXES[regime]?.try(&.as_h?) || return {nil, {} of String => Array(String)}
      keys = years.keys.compact_map(&.as_i?)
      chosen = keys.select { |item| item <= year }.max? || keys.min?
      return {nil, {} of String => Array(String)} if chosen.nil?
      entry = years.find { |key, _| key.as_i? == chosen }.try(&.[1]) || return {nil, {} of String => Array(String)}
      {chosen, entry.as_h.to_h { |section, codes| {section.as_s, codes.as_a.map(&.as_s)} }}
    end

    # --- Récapitulatifs ---------------------------------------------------------------------

    def self.summary(actor : Actor, year : Int32) : Api::TaxSummaryView
      regime = Records.regime
      operations = Operations.list(actor, Api::OperationQuery.new(date_from: Calendar.year_start(year),
        date_to: Calendar.year_end(year), limit: Api::MAX_LIMIT * 10))
      tags = Category.all.to_a.to_h { |row| {row.id!.to_i64, row.tax_tag.to_s} }
      documents = Document.filter(entry_id__in: operations.map(&.entry_id)).to_a.group_by(&.entry_id.try(&.to_i64))
      boxes_year, boxes = boxes(year, regime)
      mileage_year, rates = rates(year, regime)

      sections = SECTIONS.map do |code, plus|
        minus = DEDUCTED[code]? || [] of String
        groups = {} of String => Array(Api::TaxEntryView)
        operations.each do |operation|
          operation.splits.each do |split|
            tag = split.category_id.try { |id| tags[id]? } || next
            sign = plus.includes?(tag) ? 1 : (minus.includes?(tag) ? -1 : next)
            amount = split.amount.abs * sign
            key = case code
                  when "donations", "home_employment"
                    sign < 0 ? I18n.t("perso.labels.aids") : operation.payee
                  else
                    split.label
                  end
            (groups[key] ||= [] of Api::TaxEntryView) << Api::TaxEntryView.new(operation.entry_id, operation.date,
              operation.payee, amount, documents[operation.entry_id]?.try(&.size) || 0)
          end
        end
        items = groups.map { |label, entries| Api::TaxItemView.new(label, entries.sum(ZERO, &.amount), entries) }
        if code == "professional_expenses"
          Trip.filter(year: year).order(:id).each do |trip|
            amount = allowance(rates, trip.fiscal_power!.to_i32, trip.kilometers!.to_i32)
            label = I18n.t("perso.labels.mileage", label: trip.label.to_s.presence || "-", power: trip.fiscal_power.to_s,
              km: trip.kilometers.to_s)
            items << Api::TaxItemView.new(label, amount, [] of Api::TaxEntryView)
          end
        end
        items.sort_by! { |item| {item.amount < 0 ? 1 : 0, item.label.downcase} }
        Api::TaxSectionView.new(code, items, (boxes[code]? || [] of String).map { |box| Api::TaxBoxView.new(box, "perso.tax_boxes.#{box.downcase}") },
          items.sum(ZERO, &.amount))
      end
      Api::TaxSummaryView.new(year, sections, boxes_year, mileage_year)
    end
  end
end
