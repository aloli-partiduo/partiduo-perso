# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Tableau d'amortissement d'un emprunt à échéances mensuelles constantes
  # (D5, D-PER-009), calculé en `BigDecimal` : différé partiel (intérêts
  # seuls) ou total (intérêts capitalisés), puis échéances constantes
  # `A = C × r / (1 − (1 + r)^−n)` arrondies au centime, intérêts du mois
  # arrondis au centime, dernière échéance ajustée au capital restant ;
  # assurance fixe ou proportionnelle (capital initial ou restant dû).
  # Calcul pur, sans base. Interne.
  module Amortization
    ZERO = BigDecimal.new(0)

    # Conditions d'une version.
    record Terms,
      principal : BigDecimal,
      initial_principal : BigDecimal,
      annual_rate : BigDecimal,
      months : Int32,
      first_due_on : Time,
      deferral_months : Int32 = 0,
      deferral_kind : String = "none",
      insurance_mode : String = "none",
      insurance_value : BigDecimal = BigDecimal.new(0)

    # Échéance calculée : `capital` négatif pour des intérêts capitalisés
    # (différé total).
    record Row, index : Int32, due_on : Time, capital : BigDecimal, interest : BigDecimal, insurance : BigDecimal,
      remaining : BigDecimal

    # Arrondi au centime (demi-centime au-dessus), échelle ramenée à deux
    # décimales au plus : la valeur s'enregistre dans une colonne à deux
    # décimales.
    def self.cents(value : BigDecimal) : BigDecimal
      text = value.round(2, mode: :ties_away).to_s
      text = text.rstrip('0').rstrip('.') if text.includes?('.')
      BigDecimal.new(text.empty? || text == "-" ? "0" : text)
    end

    # Taux mensuel : taux nominal annuel en % ÷ 1 200.
    def self.monthly_rate(annual_rate : BigDecimal) : BigDecimal
      (annual_rate / BigDecimal.new(1200)).round(PRECISION)
    end

    # Décimales gardées dans les calculs intermédiaires (taux, puissances) :
    # bien au-delà du centime, sans laisser grandir les nombres.
    PRECISION = 30

    # `(1 + rate)^n`, arrondi à chaque produit.
    def self.growth(rate : BigDecimal, n : Int32) : BigDecimal
      factor = BigDecimal.new(1) + rate
      value = BigDecimal.new(1)
      n.times { value = (value * factor).round(PRECISION) }
      value
    end

    # Échéance constante (hors assurance) pour rembourser `capital` en `n`
    # mois au taux mensuel `rate`.
    def self.installment(capital : BigDecimal, rate : BigDecimal, n : Int32) : BigDecimal
      return ZERO if n <= 0 || capital <= 0
      return cents(capital / BigDecimal.new(n)) if rate.zero?
      growth = growth(rate, n)
      cents(capital * rate * growth / (growth - BigDecimal.new(1)))
    end

    def self.insurance(terms : Terms, remaining : BigDecimal) : BigDecimal
      case terms.insurance_mode
      when "fixed"     then cents(terms.insurance_value)
      when "initial"   then cents(terms.initial_principal * monthly_rate(terms.insurance_value))
      when "remaining" then cents(remaining * monthly_rate(terms.insurance_value))
      else                  ZERO
      end
    end

    def self.rows(terms : Terms) : Array(Row)
      rate = monthly_rate(terms.annual_rate)
      remaining = cents(terms.principal)
      rows = [] of Row
      return rows if remaining <= 0 || terms.months <= 0
      deferral = terms.deferral_kind == "none" ? 0 : terms.deferral_months.clamp(0, terms.months - 1)
      deferral.times do |index|
        insurance = insurance(terms, remaining)
        interest = cents(remaining * rate)
        capital = ZERO
        if terms.deferral_kind == "total"
          capital = -interest
          remaining = cents(remaining + interest)
        end
        rows << Row.new(index + 1, due(terms, index), capital, interest, insurance, remaining)
      end
      count = terms.months - deferral
      payment = installment(remaining, rate, count)
      count.times do |offset|
        index = deferral + offset
        insurance = insurance(terms, remaining)
        interest = cents(remaining * rate)
        capital = offset == count - 1 ? remaining : Math.min(payment - interest, remaining)
        capital = ZERO if capital < 0
        remaining = cents(remaining - capital)
        rows << Row.new(index + 1, due(terms, index), capital, interest, insurance, remaining)
      end
      rows
    end

    # Nombre d'échéances qui remboursent `capital` en gardant l'échéance
    # `payment` (remboursement anticipé qui réduit la durée).
    def self.months_for(capital : BigDecimal, annual_rate : BigDecimal, payment : BigDecimal, limit : Int32 = 600) : Int32
      rate = monthly_rate(annual_rate)
      remaining = capital
      count = 0
      while remaining > 0 && count < limit
        interest = cents(remaining * rate)
        principal_part = payment - interest
        return limit if principal_part <= 0
        remaining -= principal_part
        count += 1
      end
      count
    end

    private def self.due(terms : Terms, index : Int32) : Time
      Calendar.add_months(terms.first_due_on, index)
    end
  end
end
