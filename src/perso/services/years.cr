# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Années civiles (D11, D-PER-015) : les exercices du socle d'un foyer sont
  # des années civiles, créées d'avance par l'extension et jamais
  # clôturées. Une opération, une échéance ou un budget d'une année encore
  # absente la fait créer (douze périodes mensuelles), par l'acteur système :
  # le découpage en années n'est pas une décision du foyer. Interne.
  module Years
    # Années créées autour de l'année en cours : la précédente et la
    # suivante.
    AROUND = 1

    # Plus vieille et plus lointaine année qu'une saisie fait créer.
    PAST   = 30
    FUTURE =  2

    def self.prepare(year : Int32) : Bool
      return true if exists?(year)
      current = Calendar.today.year
      return false unless (current - PAST) <= year <= (current + FUTURE)
      input = Partiduo::Api::Core::FiscalYearInput.new(year: year, start_year: year)
      Partiduo::Api::Core.create_fiscal_year(Records.system, input).success?
    end

    def self.ensure_around(today : Time = Calendar.today) : Array(Int32)
      ((today.year - AROUND)..(today.year + AROUND)).select { |year| prepare(year) }.to_a
    end

    def self.exists?(year : Int32) : Bool
      !fiscal_year(year).nil?
    end

    def self.fiscal_year(year : Int32) : Partiduo::Api::Core::FiscalYearView?
      Partiduo::Api::Core.fiscal_years(Records.system).find { |item| item.starts_on.try(&.year) == year && item.periods.size >= 12 }
    end

    # Périodes mensuelles d'une année civile, dans l'ordre ; `nil` si
    # l'exercice n'existe pas ou n'est pas une année civile.
    def self.periods(year : Int32) : Array(Partiduo::Api::Core::PeriodView)?
      found = fiscal_year(year) || return
      months = found.periods.reject(&.single_day?)
      return unless months.size == 12 && months.first.starts_on == Calendar.year_start(year)
      months
    end
  end
end
