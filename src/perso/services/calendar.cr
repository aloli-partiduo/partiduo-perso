# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Dates (convention C1 du cœur : minuit UTC), mois et jours ouvrés.
  # Interne.
  module Calendar
    def self.day(time : Time) : Time
      Time.utc(time.year, time.month, time.day)
    end

    def self.today : Time
      day(Partiduo::Api::Core.today)
    end

    def self.end_of_month(year : Int32, month : Int32) : Time
      Time.utc(year, month, Time.days_in_month(year, month))
    end

    def self.end_of_month(time : Time) : Time
      end_of_month(time.year, time.month)
    end

    # Même jour `months` mois plus tard, ramené à la fin d'un mois plus court.
    def self.add_months(time : Time, months : Int32) : Time
      index = time.year * 12 + (time.month - 1) + months
      year = index // 12
      month = index % 12 + 1
      Time.utc(year, month, Math.min(time.day, Time.days_in_month(year, month)))
    end

    # Mois écoulés de `from` à `to` (par numéro de mois).
    def self.months_between(from : Time, to : Time) : Int32
      (to.year - from.year) * 12 + (to.month - from.month)
    end

    def self.year_start(year : Int32) : Time
      Time.utc(year, 1, 1)
    end

    def self.year_end(year : Int32) : Time
      Time.utc(year, 12, 31)
    end

    # Jour ouvré : ni samedi, ni dimanche, ni jour férié du régime
    # (`fr`, `be`).
    def self.business_day?(time : Time, regime : String = "fr") : Bool
      return false if time.day_of_week.saturday? || time.day_of_week.sunday?
      !holidays(time.year, regime).includes?(day(time))
    end

    # Premier jour ouvré à partir de `time` (inclus).
    def self.next_business_day(time : Time, regime : String = "fr") : Time
      current = day(time)
      until business_day?(current, regime)
        current += 1.day
      end
      current
    end

    # Jours fériés légaux d'une année : dates fixes et fêtes mobiles tirées
    # de Pâques (lundi de Pâques, Ascension, lundi de Pentecôte).
    def self.holidays(year : Int32, regime : String = "fr") : Set(Time)
      easter = easter(year)
      fixed = regime == "be" ? [{1, 1}, {5, 1}, {7, 21}, {8, 15}, {11, 1}, {11, 11}, {12, 25}] : [{1, 1}, {5, 1}, {5, 8}, {7, 14}, {8, 15}, {11, 1}, {11, 11}, {12, 25}]
      set = fixed.map { |(month, date)| Time.utc(year, month, date) }.to_set
      set << easter + 1.day
      set << easter + 39.days
      set << easter + 50.days
      set
    end

    # Dimanche de Pâques (calendrier grégorien, algorithme anonyme).
    def self.easter(year : Int32) : Time
      a = year % 19
      b = year // 100
      c = year % 100
      d = b // 4
      e = b % 4
      f = (b + 8) // 25
      g = (b - f + 1) // 3
      h = (19 * a + b - d - g + 15) % 30
      i = c // 4
      k = c % 4
      l = (32 + 2 * e + 2 * i - h - k) % 7
      m = (a + 11 * h + 22 * l) // 451
      month = (h + l - 7 * m + 114) // 31
      date = ((h + l - 7 * m + 114) % 31) + 1
      Time.utc(year, month, date)
    end
  end
end
