# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Emprunt (D5, D-PER-009) : rattaché au compte de dette du foyer
  # (`account_id`, nature `mortgage` ou `other_debt`), réglé depuis le compte
  # `payment_account_id` ; intérêts et assurance rangés dans leurs
  # catégories. Ses conditions sont dans ses versions. Interne.
  class Loan < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :account_id, :big_int, unique: true
    field :payment_account_id, :big_int
    field :interest_category_id, :big_int
    field :insurance_category_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Version du tableau d'amortissement : conditions en vigueur à partir de
  # `effective_on` — capital restant à cette date, taux nominal annuel,
  # nombre d'échéances restantes, première échéance, différé (`none`,
  # `partial` : intérêts seuls, `total` : intérêts capitalisés), assurance
  # (`none`, `fixed` : montant par échéance, `initial` : taux annuel sur le
  # capital initial, `remaining` : taux annuel sur le capital restant dû).
  # Un remboursement anticipé (`reason` `prepayment`, montant `prepayment`)
  # crée une version ; les précédentes sont gardées (D5). Interne.
  class LoanVersion < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :loan_id, :big_int
    field :number, :int
    field :effective_on, :date
    field :reason, :string, max_size: 16, default: "initial"
    field :principal, :decimal, max_digits: 20, decimal_places: 2
    field :initial_principal, :decimal, max_digits: 20, decimal_places: 2
    field :annual_rate, :decimal, max_digits: 9, decimal_places: 5
    field :months, :int
    field :first_due_on, :date
    field :deferral_months, :int, default: 0
    field :deferral_kind, :string, max_size: 16, default: "none"
    field :insurance_mode, :string, max_size: 16, default: "none"
    field :insurance_value, :decimal, max_digits: 20, decimal_places: 5, default: BigDecimal.new(0)
    field :prepayment, :decimal, max_digits: 20, decimal_places: 2, blank: true, null: true
    field :prepayment_mode, :string, max_size: 16, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Échéance d'emprunt confirmée : ses écritures (règlement sur le compte
  # payeur, diminution de la dette sur le compte de l'emprunt). Interne.
  class Installment < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :loan_id, :big_int
    field :due_on, :date
    field :version_number, :int
    field :entry_id, :big_int, blank: true, null: true
    field :transfer_entry_id, :big_int, blank: true, null: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
