# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension des finances personnelles d'un foyer : membres,
# catégories, comptes et titulaires, opérations et justificatifs, opérations
# récurrentes et échéances traitées, emprunts, versions de leur tableau et
# échéances confirmées, valorisations et leurs lignes, budgets et leurs
# montants, barème kilométrique et déplacements.
#
# Intégrité en base : natures, rôles, sens, fréquences, statuts et modes
# contrôlés ; montants positifs là où le sens est porté ailleurs ; un
# virement a un compte de destination, une dépense ou une recette n'en a
# pas ; une version d'emprunt a au moins une échéance et un taux positif ou
# nul. Les liens vers le cœur (journal, écritures, prévision, pièce jointe)
# sont des identifiants relus par le contrat, sans clé étrangère
# (D-PER-003) ; les liens internes et vers `auth_user` ont les leurs.
class Migration::Perso::V0001 < Marten::Migration
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_member
        ADD CONSTRAINT perso_member_role_check CHECK (role IN ('adult', 'minor', 'advisor')),
        ADD CONSTRAINT perso_member_name_check CHECK (btrim(display_name) <> ''),
        ADD CONSTRAINT perso_member_user_fk FOREIGN KEY (user_id) REFERENCES auth_user (id) ON DELETE CASCADE
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_category
        ADD CONSTRAINT perso_category_kind_check CHECK (kind IN ('expense', 'income')),
        ADD CONSTRAINT perso_category_label_check CHECK (btrim(label) <> ''),
        ADD CONSTRAINT perso_category_tag_check CHECK (tax_tag IN ('', 'donation', 'home_employment',
          'home_employment_aid', 'professional_expenses', 'rental_income', 'rental_charges')),
        ADD CONSTRAINT perso_category_parent_fk FOREIGN KEY (parent_id) REFERENCES perso_category (id) ON DELETE RESTRICT
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_account
        ADD CONSTRAINT perso_account_nature_check CHECK (nature IN ('current', 'savings', 'life_insurance', 'pea',
          'securities', 'mortgage', 'other_debt', 'property')),
        ADD CONSTRAINT perso_account_asset_kind_check CHECK ((nature = 'property') = (asset_kind <> '') AND
          asset_kind IN ('', 'residence', 'real_estate', 'vehicle', 'other')),
        ADD CONSTRAINT perso_account_label_check CHECK (btrim(label) <> ''),
        ADD CONSTRAINT perso_account_rate_check CHECK (rate IS NULL OR rate >= 0),
        ADD CONSTRAINT perso_account_ceiling_check CHECK (ceiling IS NULL OR ceiling > 0)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_account_holder
        ADD CONSTRAINT perso_account_holder_account_fk FOREIGN KEY (account_id) REFERENCES perso_account (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_account_holder_member_fk FOREIGN KEY (member_id) REFERENCES perso_member (id) ON DELETE CASCADE
      SQL
    {"CREATE UNIQUE INDEX perso_account_holder_unique ON perso_account_holder (account_id, member_id)",
     "DROP INDEX IF EXISTS perso_account_holder_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_operation
        ADD CONSTRAINT perso_operation_kind_check CHECK (kind IN ('expense', 'income', 'transfer')),
        ADD CONSTRAINT perso_operation_status_check CHECK (status IN ('active', 'replaced', 'deleted')),
        ADD CONSTRAINT perso_operation_transfer_check CHECK ((kind = 'transfer') = (to_account_id IS NOT NULL)),
        ADD CONSTRAINT perso_operation_reversal_check CHECK ((status = 'active') = (reversal_entry_id IS NULL)),
        ADD CONSTRAINT perso_operation_account_fk FOREIGN KEY (account_id) REFERENCES perso_account (id) ON DELETE RESTRICT,
        ADD CONSTRAINT perso_operation_to_account_fk FOREIGN KEY (to_account_id) REFERENCES perso_account (id) ON DELETE RESTRICT,
        ADD CONSTRAINT perso_operation_member_fk FOREIGN KEY (member_id) REFERENCES perso_member (id) ON DELETE SET NULL,
        ADD CONSTRAINT perso_operation_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_document
        ADD CONSTRAINT perso_document_kind_check CHECK (kind IN ('invoice', 'receipt', 'tax_receipt', 'certificate',
          'tax_notice', 'other')),
        ADD CONSTRAINT perso_document_target_check CHECK (num_nonnulls(entry_id, account_id, year) = 1),
        ADD CONSTRAINT perso_document_account_fk FOREIGN KEY (account_id) REFERENCES perso_account (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_document_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_recurring
        ADD CONSTRAINT perso_recurring_kind_check CHECK (kind IN ('expense', 'income', 'transfer')),
        ADD CONSTRAINT perso_recurring_target_check CHECK ((kind = 'transfer' AND to_account_id IS NOT NULL AND category_id IS NULL)
          OR (kind <> 'transfer' AND to_account_id IS NULL AND category_id IS NOT NULL)),
        ADD CONSTRAINT perso_recurring_frequency_check CHECK (frequency IN ('monthly', 'quarterly', 'yearly', 'days')),
        ADD CONSTRAINT perso_recurring_interval_check CHECK ((frequency = 'days') = (interval_days IS NOT NULL)
          AND (interval_days IS NULL OR interval_days BETWEEN 1 AND 366)),
        ADD CONSTRAINT perso_recurring_amount_check CHECK (amount > 0),
        ADD CONSTRAINT perso_recurring_dates_check CHECK (last_on IS NULL OR last_on >= first_on),
        ADD CONSTRAINT perso_recurring_payee_check CHECK (btrim(payee) <> ''),
        ADD CONSTRAINT perso_recurring_account_fk FOREIGN KEY (account_id) REFERENCES perso_account (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_recurring_to_account_fk FOREIGN KEY (to_account_id) REFERENCES perso_account (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_recurring_category_fk FOREIGN KEY (category_id) REFERENCES perso_category (id) ON DELETE RESTRICT,
        ADD CONSTRAINT perso_recurring_member_fk FOREIGN KEY (member_id) REFERENCES perso_member (id) ON DELETE SET NULL,
        ADD CONSTRAINT perso_recurring_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_occurrence
        ADD CONSTRAINT perso_occurrence_status_check CHECK (status IN ('confirmed', 'matched', 'skipped')),
        ADD CONSTRAINT perso_occurrence_entry_check CHECK ((status = 'skipped') = (entry_id IS NULL)),
        ADD CONSTRAINT perso_occurrence_recurring_fk FOREIGN KEY (recurring_id) REFERENCES perso_recurring (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_occurrence_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {"CREATE UNIQUE INDEX perso_occurrence_unique ON perso_occurrence (recurring_id, due_on)",
     "DROP INDEX IF EXISTS perso_occurrence_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_loan
        ADD CONSTRAINT perso_loan_account_fk FOREIGN KEY (account_id) REFERENCES perso_account (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_loan_payment_fk FOREIGN KEY (payment_account_id) REFERENCES perso_account (id) ON DELETE RESTRICT,
        ADD CONSTRAINT perso_loan_interest_fk FOREIGN KEY (interest_category_id) REFERENCES perso_category (id) ON DELETE RESTRICT,
        ADD CONSTRAINT perso_loan_insurance_fk FOREIGN KEY (insurance_category_id) REFERENCES perso_category (id) ON DELETE RESTRICT,
        ADD CONSTRAINT perso_loan_accounts_check CHECK (account_id <> payment_account_id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_loan_version
        ADD CONSTRAINT perso_loan_version_reason_check CHECK (reason IN ('initial', 'prepayment', 'repaid')),
        ADD CONSTRAINT perso_loan_version_principal_check CHECK (principal >= 0 AND initial_principal > 0),
        ADD CONSTRAINT perso_loan_version_rate_check CHECK (annual_rate >= 0 AND annual_rate < 100),
        ADD CONSTRAINT perso_loan_version_months_check CHECK (months BETWEEN 0 AND 600),
        ADD CONSTRAINT perso_loan_version_deferral_check CHECK (deferral_kind IN ('none', 'partial', 'total')
          AND deferral_months >= 0 AND (deferral_kind <> 'none' OR deferral_months = 0)),
        ADD CONSTRAINT perso_loan_version_insurance_check CHECK (insurance_mode IN ('none', 'fixed', 'initial', 'remaining')
          AND insurance_value >= 0),
        ADD CONSTRAINT perso_loan_version_prepayment_check CHECK (prepayment IS NULL OR prepayment > 0),
        ADD CONSTRAINT perso_loan_version_mode_check CHECK (prepayment_mode IN ('', 'duration', 'installment')),
        ADD CONSTRAINT perso_loan_version_loan_fk FOREIGN KEY (loan_id) REFERENCES perso_loan (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_loan_version_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {"CREATE UNIQUE INDEX perso_loan_version_unique ON perso_loan_version (loan_id, number)",
     "DROP INDEX IF EXISTS perso_loan_version_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_installment
        ADD CONSTRAINT perso_installment_loan_fk FOREIGN KEY (loan_id) REFERENCES perso_loan (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_installment_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {"CREATE UNIQUE INDEX perso_installment_unique ON perso_installment (loan_id, due_on)",
     "DROP INDEX IF EXISTS perso_installment_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_valuation
        ADD CONSTRAINT perso_valuation_amount_check CHECK (amount >= 0),
        ADD CONSTRAINT perso_valuation_account_fk FOREIGN KEY (account_id) REFERENCES perso_account (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_valuation_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {"CREATE UNIQUE INDEX perso_valuation_unique ON perso_valuation (account_id, valued_on)",
     "DROP INDEX IF EXISTS perso_valuation_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_valuation_line
        ADD CONSTRAINT perso_valuation_line_quantity_check CHECK (quantity > 0 AND price >= 0),
        ADD CONSTRAINT perso_valuation_line_valuation_fk FOREIGN KEY (valuation_id) REFERENCES perso_valuation (id) ON DELETE CASCADE
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_budget
        ADD CONSTRAINT perso_budget_year_check CHECK (year BETWEEN 1900 AND 2999)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_budget_line
        ADD CONSTRAINT perso_budget_line_kind_check CHECK (period_kind IN ('monthly', 'annual')),
        ADD CONSTRAINT perso_budget_line_amount_check CHECK (amount >= 0),
        ADD CONSTRAINT perso_budget_line_budget_fk FOREIGN KEY (budget_id) REFERENCES perso_budget (id) ON DELETE CASCADE,
        ADD CONSTRAINT perso_budget_line_category_fk FOREIGN KEY (category_id) REFERENCES perso_category (id) ON DELETE RESTRICT
      SQL
    {"CREATE UNIQUE INDEX perso_budget_line_unique ON perso_budget_line (budget_id, category_id)",
     "DROP INDEX IF EXISTS perso_budget_line_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_mileage_rate
        ADD CONSTRAINT perso_mileage_rate_power_check CHECK (fiscal_power BETWEEN 1 AND 99),
        ADD CONSTRAINT perso_mileage_rate_values_check CHECK (coefficient >= 0 AND (max_km IS NULL OR max_km > 0))
      SQL
    {"CREATE UNIQUE INDEX perso_mileage_rate_unique ON perso_mileage_rate (year, fiscal_power, coalesce(max_km, 0))",
     "DROP INDEX IF EXISTS perso_mileage_rate_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE perso_trip
        ADD CONSTRAINT perso_trip_values_check CHECK (kilometers > 0 AND fiscal_power BETWEEN 1 AND 99),
        ADD CONSTRAINT perso_trip_member_fk FOREIGN KEY (member_id) REFERENCES perso_member (id) ON DELETE SET NULL,
        ADD CONSTRAINT perso_trip_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
  ]

  def plan
    create_table :perso_member do
      column :id, :big_int, primary_key: true, auto: true
      column :user_id, :big_int, unique: true
      column :display_name, :string, max_size: 80
      column :role, :string, max_size: 16, default: "adult"
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_category do
      column :id, :big_int, primary_key: true, auto: true
      column :account, :string, max_size: 40, unique: true
      column :parent_id, :big_int, null: true, index: true
      column :label, :string, max_size: 120
      column :kind, :string, max_size: 8
      column :tax_tag, :string, max_size: 32, default: ""
      column :position, :int, default: 100
      column :active, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_account do
      column :id, :big_int, primary_key: true, auto: true
      column :ledger_id, :big_int, unique: true
      column :account_number, :string, max_size: 40, unique: true
      column :card_code, :string, max_size: 64, default: ""
      column :nature, :string, max_size: 16
      column :asset_kind, :string, max_size: 16, default: ""
      column :label, :string, max_size: 120
      column :institution, :string, max_size: 120, default: ""
      column :rate, :decimal, max_digits: 9, decimal_places: 4, null: true
      column :ceiling, :decimal, max_digits: 20, decimal_places: 2, null: true
      column :opened_on, :date, null: true
      column :closed, :bool, default: false
      column :position, :int, default: 100
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_account_holder do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :big_int, index: true
      column :member_id, :big_int, index: true
    end

    create_table :perso_operation do
      column :id, :big_int, primary_key: true, auto: true
      column :entry_id, :big_int, unique: true
      column :transfer_entry_id, :big_int, null: true, index: true
      column :account_id, :big_int, index: true
      column :to_account_id, :big_int, null: true
      column :kind, :string, max_size: 16
      column :payee, :string, max_size: 120, default: ""
      column :member_id, :big_int, null: true
      column :note, :text, default: ""
      column :previous_entry_id, :big_int, null: true, index: true
      column :status, :string, max_size: 16, default: "active"
      column :reversal_entry_id, :big_int, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_document do
      column :id, :big_int, primary_key: true, auto: true
      column :attachment_id, :big_int
      column :entry_id, :big_int, null: true, index: true
      column :account_id, :big_int, null: true, index: true
      column :year, :int, null: true
      column :kind, :string, max_size: 16, default: "other"
      column :label, :string, max_size: 255, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_recurring do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :big_int, index: true
      column :kind, :string, max_size: 16
      column :category_id, :big_int, null: true
      column :to_account_id, :big_int, null: true
      column :payee, :string, max_size: 120
      column :amount, :decimal, max_digits: 20, decimal_places: 2
      column :estimated, :bool, default: false
      column :frequency, :string, max_size: 16, default: "monthly"
      column :interval_days, :int, null: true
      column :first_on, :date
      column :last_on, :date, null: true
      column :business_days, :bool, default: false
      column :member_id, :big_int, null: true
      column :active, :bool, default: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_occurrence do
      column :id, :big_int, primary_key: true, auto: true
      column :recurring_id, :big_int
      column :due_on, :date
      column :status, :string, max_size: 16
      column :entry_id, :big_int, null: true, index: true
      column :amount, :decimal, max_digits: 20, decimal_places: 2, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_loan do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :big_int, unique: true
      column :payment_account_id, :big_int
      column :interest_category_id, :big_int
      column :insurance_category_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_loan_version do
      column :id, :big_int, primary_key: true, auto: true
      column :loan_id, :big_int
      column :number, :int
      column :effective_on, :date
      column :reason, :string, max_size: 16, default: "initial"
      column :principal, :decimal, max_digits: 20, decimal_places: 2
      column :initial_principal, :decimal, max_digits: 20, decimal_places: 2
      column :annual_rate, :decimal, max_digits: 9, decimal_places: 5
      column :months, :int
      column :first_due_on, :date
      column :deferral_months, :int, default: 0
      column :deferral_kind, :string, max_size: 16, default: "none"
      column :insurance_mode, :string, max_size: 16, default: "none"
      column :insurance_value, :decimal, max_digits: 20, decimal_places: 5, default: 0
      column :prepayment, :decimal, max_digits: 20, decimal_places: 2, null: true
      column :prepayment_mode, :string, max_size: 16, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_installment do
      column :id, :big_int, primary_key: true, auto: true
      column :loan_id, :big_int
      column :due_on, :date
      column :version_number, :int
      column :entry_id, :big_int, null: true, index: true
      column :transfer_entry_id, :big_int, null: true, index: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_valuation do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :big_int
      column :valued_on, :date
      column :amount, :decimal, max_digits: 20, decimal_places: 2
      column :note, :string, max_size: 255, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_valuation_line do
      column :id, :big_int, primary_key: true, auto: true
      column :valuation_id, :big_int, index: true
      column :security, :string, max_size: 120
      column :quantity, :decimal, max_digits: 20, decimal_places: 6
      column :price, :decimal, max_digits: 20, decimal_places: 6
      column :amount, :decimal, max_digits: 20, decimal_places: 2
    end

    create_table :perso_budget do
      column :id, :big_int, primary_key: true, auto: true
      column :year, :int, unique: true
      column :forecast_id, :big_int
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_budget_line do
      column :id, :big_int, primary_key: true, auto: true
      column :budget_id, :big_int
      column :category_id, :big_int, index: true
      column :period_kind, :string, max_size: 8, default: "monthly"
      column :amount, :decimal, max_digits: 20, decimal_places: 2
      column :forecast_item_id, :big_int
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :perso_mileage_rate do
      column :id, :big_int, primary_key: true, auto: true
      column :year, :int
      column :fiscal_power, :int
      column :max_km, :int, null: true
      column :coefficient, :decimal, max_digits: 10, decimal_places: 4
      column :constant, :decimal, max_digits: 20, decimal_places: 2, default: 0
    end

    create_table :perso_trip do
      column :id, :big_int, primary_key: true, auto: true
      column :year, :int
      column :member_id, :big_int, null: true
      column :fiscal_power, :int
      column :kilometers, :int
      column :label, :string, max_size: 255, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
