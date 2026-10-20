# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Api
    # Natures d'un compte du foyer (D5). Libellé : `perso.natures.<code>`.
    NATURES            = %w[current savings life_insurance pea securities mortgage other_debt property]
    CASH_NATURES       = %w[current savings]
    INVESTMENT_NATURES = %w[life_insurance pea securities]
    DEBT_NATURES       = %w[mortgage other_debt]
    # Placements valorisés ligne à ligne (titre, quantité, cours).
    SECURITIES_NATURES = %w[pea securities]

    # Genres d'un bien. Libellé : `perso.asset_kinds.<code>`.
    ASSET_KINDS = %w[residence real_estate vehicle other]

    # Sens d'une catégorie. Libellé : `perso.category_kinds.<code>`.
    CATEGORY_KINDS = %w[expense income]

    # Étiquettes fiscales d'une catégorie (D3, D10). Libellé :
    # `perso.tax_tags.<code>`.
    TAX_TAGS = %w[donation home_employment home_employment_aid professional_expenses rental_income rental_charges]

    # Rôles d'un membre du foyer (D12). Libellé : `perso.member_roles.<code>`.
    MEMBER_ROLES = %w[adult minor advisor]

    # Sortes et états d'une opération (D4). Libellés : `perso.operation_kinds.<code>`,
    # `perso.operation_statuses.<code>`.
    OPERATION_KINDS    = %w[expense income transfer]
    OPERATION_STATUSES = %w[active replaced deleted]

    # Origine d'une écriture vue comme opération : saisie par l'extension,
    # transférée d'un relevé importé, passée ailleurs. Libellé :
    # `perso.sources.<code>`.
    SOURCES = %w[perso bankimport other]

    # Fréquences d'une opération récurrente (D7). Libellé :
    # `perso.frequencies.<code>`.
    FREQUENCIES = %w[monthly quarterly yearly days]

    # États d'une échéance de l'échéancier. Libellé : `perso.due_statuses.<code>`.
    DUE_STATUSES = %w[upcoming overdue confirmed matched skipped]

    # Emprunts (D5). Libellés : `perso.deferral_kinds.<code>`,
    # `perso.insurance_modes.<code>`, `perso.prepayment_modes.<code>`,
    # `perso.loan_reasons.<code>`.
    DEFERRAL_KINDS   = %w[none partial total]
    INSURANCE_MODES  = %w[none fixed initial remaining]
    PREPAYMENT_MODES = %w[duration installment]
    LOAN_REASONS     = %w[initial prepayment repaid]

    # Budget mensuel ou annuel d'une catégorie (D8). Libellé :
    # `perso.period_kinds.<code>`.
    PERIOD_KINDS = %w[monthly annual]

    # Justificatifs (D4). Libellé : `perso.document_kinds.<code>`.
    DOCUMENT_KINDS = %w[invoice receipt tax_receipt certificate tax_notice other]

    # Rubriques de l'aide à la déclaration (D10). Libellé :
    # `perso.tax_sections.<code>`.
    TAX_SECTIONS = %w[donations home_employment professional_expenses rental]

    # Sens d'une règle de catégorisation (contrat de `partiduo-bankimport`).
    RULE_DIRECTIONS = Bankimport::Api::DIRECTIONS

    MAX_LIMIT = 1000

    # --- Entrées ---------------------------------------------------------------

    # Catégorie (D3) : libellé, sens, parent (second niveau ; même sens),
    # étiquette fiscale, rang, active.
    record CategoryInput,
      label : String,
      kind : String = "expense",
      parent_id : Int64? = nil,
      tax_tag : String = "",
      position : Int32 = 100,
      active : Bool = true

    # Compte du foyer (D5). `ledger_id` : reprendre un journal financier
    # existant (le compte courant du plan réduit) ; `account_number` :
    # reprendre un compte du plan existant (sans journal) ; sinon un compte
    # est créé sous celui de la nature. `opening_balance` : solde
    # d'ouverture passé en opérations diverses contre le patrimoine
    # d'ouverture, à `opened_on` (positif : avoir ; pour une dette, capital
    # dû). Titulaires : membres ; aucun : le foyer.
    record AccountInput,
      nature : String,
      label : String,
      institution : String = "",
      asset_kind : String = "",
      rate : BigDecimal? = nil,
      ceiling : BigDecimal? = nil,
      opened_on : Time? = nil,
      holder_ids : Array(Int64) = [] of Int64,
      ledger_id : Int64? = nil,
      account_number : String? = nil,
      opening_balance : BigDecimal? = nil,
      position : Int32 = 100

    # Modification d'un compte : ce qui ne touche pas à la Comptabilité.
    record AccountUpdateInput,
      label : String,
      institution : String = "",
      asset_kind : String = "",
      rate : BigDecimal? = nil,
      ceiling : BigDecimal? = nil,
      opened_on : Time? = nil,
      holder_ids : Array(Int64) = [] of Int64,
      closed : Bool = false,
      position : Int32 = 100

    # Membre du foyer (D12) : un utilisateur du dossier.
    record MemberInput, user_id : Int64, display_name : String, role : String = "adult"

    # Ligne de ventilation d'une opération sur plusieurs catégories.
    record SplitInput, category_id : Int64, amount : BigDecimal

    # Opération (D4) : compte, date, montant positif, sorte (`expense`,
    # `income`, `transfer`), catégorie *ou* ventilation (dépense, recette),
    # compte de destination (virement), bénéficiaire ou payeur, membre, note.
    record OperationInput,
      account_id : Int64,
      date : Time,
      amount : BigDecimal,
      kind : String = "expense",
      category_id : Int64? = nil,
      splits : Array(SplitInput) = [] of SplitInput,
      to_account_id : Int64? = nil,
      payee : String = "",
      member_id : Int64? = nil,
      note : String = ""

    # Recherche d'opérations : compte (tous les comptes visibles sinon),
    # dates, catégorie, membre, texte (libellé, bénéficiaire).
    record OperationQuery,
      account_id : Int64? = nil,
      date_from : Time? = nil,
      date_to : Time? = nil,
      category_id : Int64? = nil,
      member_id : Int64? = nil,
      text : String? = nil,
      limit : Int32 = 500

    # Justificatif rattaché à une opération (son écriture), à un compte ou à
    # une année fiscale — une seule cible.
    record DocumentInput,
      filename : String,
      content_type : String,
      content : Bytes,
      kind : String = "other",
      label : String = "",
      entry_id : Int64? = nil,
      account_id : Int64? = nil,
      year : Int32? = nil

    # Opération récurrente (D7).
    record RecurringInput,
      account_id : Int64,
      payee : String,
      amount : BigDecimal,
      first_on : Time,
      kind : String = "expense",
      category_id : Int64? = nil,
      to_account_id : Int64? = nil,
      estimated : Bool = false,
      frequency : String = "monthly",
      interval_days : Int32? = nil,
      last_on : Time? = nil,
      business_days : Bool = false,
      member_id : Int64? = nil,
      active : Bool = true

    # Confirmation d'une échéance : date et montant réels (ceux de
    # l'échéance par défaut).
    record ConfirmInput, recurring_id : Int64, due_on : Time, date : Time? = nil, amount : BigDecimal? = nil

    # Emprunt (D5) : compte de dette, compte payeur, capital, taux nominal
    # annuel en %, nombre d'échéances mensuelles (différé compris), première
    # échéance, différé, assurance (montant fixe par échéance, ou taux
    # annuel en % sur le capital initial ou restant dû), catégories des
    # intérêts et de l'assurance.
    record LoanInput,
      account_id : Int64,
      payment_account_id : Int64,
      principal : BigDecimal,
      annual_rate : BigDecimal,
      months : Int32,
      first_due_on : Time,
      interest_category_id : Int64,
      insurance_category_id : Int64? = nil,
      deferral_months : Int32 = 0,
      deferral_kind : String = "none",
      insurance_mode : String = "none",
      insurance_value : BigDecimal = BigDecimal.new(0)

    # Remboursement anticipé, partiel ou total, à `date` : la durée
    # (`duration`) ou l'échéance (`installment`) diminue ; `record_operation`
    # passe aussi le virement du compte payeur vers l'emprunt.
    record PrepaymentInput, date : Time, amount : BigDecimal, mode : String = "duration",
      record_operation : Bool = true

    # Valorisation (D9) : valeur saisie, ou lignes (titre, quantité, cours)
    # d'un PEA ou d'un compte-titres.
    record ValuationLineInput, security : String, quantity : BigDecimal, price : BigDecimal

    record ValuationInput,
      account_id : Int64,
      valued_on : Time,
      amount : BigDecimal? = nil,
      lines : Array(ValuationLineInput) = [] of ValuationLineInput,
      note : String = ""

    # Montant budgété d'une catégorie (D8).
    record BudgetLineInput, category_id : Int64, amount : BigDecimal, period_kind : String = "monthly"

    # Règle de catégorisation (D6), tenue par `partiduo-bankimport` : le
    # libellé contient, le montant vaut, sens, compte du foyer (ou tous),
    # alors telle catégorie et tel bénéficiaire (`payee`, facultatif,
    # A-PER-2 ; vide : celui du relevé).
    record RuleInput,
      category_id : Int64,
      label_contains : String = "",
      amount : BigDecimal? = nil,
      direction : String = "any",
      account_id : Int64? = nil,
      position : Int32 = 100,
      active : Bool = true,
      payee : String = ""

    # Déplacements professionnels d'une année (frais réels, D10).
    record TripInput, year : Int32, fiscal_power : Int32, kilometers : Int32, member_id : Int64? = nil,
      label : String = ""

    # Tranche du barème kilométrique d'une année.
    record MileageRateInput, year : Int32, fiscal_power : Int32, coefficient : BigDecimal,
      constant : BigDecimal = BigDecimal.new(0), max_km : Int32? = nil

    # --- Vues ------------------------------------------------------------------

    record MemberView, id : Int64, user_id : Int64, display_name : String, role : String, email : String do
      def role_key : String
        "perso.member_roles.#{role}"
      end
    end

    # Catégorie : `depth` 0 (premier niveau) ou 1 ; `in_use` : citée par une
    # écriture (elle ne se supprime plus, elle se retire).
    record CategoryView,
      id : Int64,
      label : String,
      kind : String,
      parent_id : Int64?,
      parent_label : String?,
      tax_tag : String,
      position : Int32,
      active : Bool,
      depth : Int32,
      children_count : Int32 do
      def full_label : String
        parent_label.try { |parent| "#{parent} › #{label}" } || label
      end

      def kind_key : String
        "perso.category_kinds.#{kind}"
      end

      def tax_tag_key : String?
        tax_tag.empty? ? nil : "perso.tax_tags.#{tax_tag}"
      end
    end

    # Compte du foyer et son solde (celui de la Comptabilité, au jour) :
    # positif pour un avoir, positif aussi pour le capital dû d'une dette.
    # `value` : ce qu'il compte au patrimoine (solde, dernière valorisation
    # d'un placement ou d'un bien, capital restant dû d'un emprunt).
    record AccountView,
      id : Int64,
      ledger_id : Int64,
      ledger_code : String,
      nature : String,
      asset_kind : String,
      label : String,
      institution : String,
      rate : BigDecimal?,
      ceiling : BigDecimal?,
      opened_on : Time?,
      closed : Bool,
      position : Int32,
      balance : BigDecimal,
      value : BigDecimal,
      holders : Array(MemberView),
      writable : Bool,
      loan_id : Int64?,
      last_valued_on : Time? do
      def nature_key : String
        "perso.natures.#{nature}"
      end

      def debt? : Bool
        DEBT_NATURES.includes?(nature)
      end

      def cash? : Bool
        CASH_NATURES.includes?(nature)
      end

      def investment? : Bool
        INVESTMENT_NATURES.includes?(nature)
      end

      def property? : Bool
        nature == "property"
      end

      def valued? : Bool
        investment? || property?
      end
    end

    # Part d'une opération sur une catégorie (ou sur un autre compte du
    # foyer pour un virement, ou sur un compte du plan hors catégorie).
    record SplitView, category_id : Int64?, label : String, amount : BigDecimal

    # Opération : une écriture d'un compte du foyer vue en recettes et
    # dépenses. `amount` : signé pour le compte (positif : entrée).
    record OperationView,
      entry_id : Int64,
      account_id : Int64,
      account_label : String,
      date : Time,
      amount : BigDecimal,
      kind : String,
      splits : Array(SplitView),
      to_account_id : Int64?,
      payee : String,
      member_id : Int64?,
      member_name : String?,
      note : String,
      source : String,
      versions : Int32,
      writable : Bool do
      def category_label : String
        splits.map(&.label).join(", ")
      end

      def inflow? : Bool
        amount > 0
      end

      def kind_key : String
        "perso.operation_kinds.#{kind}"
      end
    end

    # Version d'une opération : écriture, montant, état, auteur et date.
    record VersionView,
      entry_id : Int64,
      date : Time,
      amount : BigDecimal,
      label : String,
      status : String,
      created_by_name : String?,
      created_at : Time,
      reversal_entry_id : Int64? do
      def status_key : String
        "perso.operation_statuses.#{status}"
      end
    end

    record DocumentView,
      id : Int64,
      attachment_id : Int64,
      kind : String,
      label : String,
      filename : String,
      entry_id : Int64?,
      account_id : Int64?,
      year : Int32?,
      created_at : Time do
      def kind_key : String
        "perso.document_kinds.#{kind}"
      end
    end

    record OperationDetailView, operation : OperationView, versions : Array(VersionView), documents : Array(DocumentView)

    record RecurringView,
      id : Int64,
      account_id : Int64,
      account_label : String,
      kind : String,
      category_id : Int64?,
      category_label : String?,
      to_account_id : Int64?,
      to_account_label : String?,
      payee : String,
      amount : BigDecimal,
      estimated : Bool,
      frequency : String,
      interval_days : Int32?,
      first_on : Time,
      last_on : Time?,
      business_days : Bool,
      member_id : Int64?,
      active : Bool,
      next_due_on : Time? do
      def frequency_key : String
        "perso.frequencies.#{frequency}"
      end
    end

    # Échéance de l'échéancier (D7) : d'une opération récurrente
    # (`recurring_id`) ou d'un emprunt (`loan_id`). `due_on` : date prévue ;
    # `date` : reportée au jour ouvré si demandé. `amount` : signé pour le
    # compte.
    record DueView,
      due_on : Time,
      date : Time,
      account_id : Int64,
      account_label : String,
      label : String,
      category_label : String,
      amount : BigDecimal,
      status : String,
      estimated : Bool,
      recurring_id : Int64? = nil,
      loan_id : Int64? = nil,
      entry_id : Int64? = nil do
      def status_key : String
        "perso.due_statuses.#{status}"
      end

      def pending? : Bool
        status.in?("upcoming", "overdue")
      end
    end

    # Solde prévisionnel d'un compte sur la période : solde du jour, solde
    # en fin de période, plus bas solde et sa date.
    record BalanceForecastView,
      account_id : Int64,
      account_label : String,
      balance : BigDecimal,
      projected : BigDecimal,
      lowest : BigDecimal,
      lowest_on : Time

    record ScheduleView,
      date_from : Time,
      date_to : Time,
      dues : Array(DueView),
      balances : Array(BalanceForecastView) do
      def overdue_count : Int32
        dues.count(&.status.==("overdue"))
      end
    end

    # Ligne du tableau d'amortissement.
    record LoanRowView,
      number : Int32,
      due_on : Time,
      capital : BigDecimal,
      interest : BigDecimal,
      insurance : BigDecimal,
      remaining : BigDecimal,
      status : String do
      def payment : BigDecimal
        capital + interest
      end

      def total : BigDecimal
        capital + interest + insurance
      end

      def status_key : String
        "perso.due_statuses.#{status}"
      end
    end

    record LoanVersionView,
      number : Int32,
      effective_on : Time,
      reason : String,
      principal : BigDecimal,
      initial_principal : BigDecimal,
      annual_rate : BigDecimal,
      months : Int32,
      first_due_on : Time,
      deferral_months : Int32,
      deferral_kind : String,
      insurance_mode : String,
      insurance_value : BigDecimal,
      prepayment : BigDecimal?,
      prepayment_mode : String,
      created_at : Time do
      def reason_key : String
        "perso.loan_reasons.#{reason}"
      end
    end

    # Emprunt, sa version en vigueur, ses versions et le tableau de la
    # version en vigueur (les échéances déjà passées des versions
    # antérieures en tête). `remaining` : capital restant dû au jour.
    record LoanView,
      id : Int64,
      account_id : Int64,
      account_label : String,
      payment_account_id : Int64,
      payment_account_label : String,
      interest_category_id : Int64,
      insurance_category_id : Int64?,
      current : LoanVersionView,
      versions : Array(LoanVersionView),
      rows : Array(LoanRowView),
      remaining : BigDecimal do
      def next_row : LoanRowView?
        rows.find(&.status.in?("upcoming", "overdue"))
      end

      def total_interest : BigDecimal
        rows.sum(BigDecimal.new(0), &.interest)
      end

      def total_insurance : BigDecimal
        rows.sum(BigDecimal.new(0), &.insurance)
      end
    end

    record ValuationLineView, security : String, quantity : BigDecimal, price : BigDecimal, amount : BigDecimal

    record ValuationView,
      id : Int64,
      account_id : Int64,
      valued_on : Time,
      amount : BigDecimal,
      note : String,
      lines : Array(ValuationLineView),
      created_at : Time

    # Placement ou bien : historique des valeurs, versements nets (solde de
    # la Comptabilité), dernière valeur et plus-value latente (D9).
    record HoldingView,
      account : AccountView,
      valuations : Array(ValuationView),
      contributions : BigDecimal,
      latest : ValuationView? do
      def latent_gain : BigDecimal?
        latest.try { |valuation| valuation.amount - contributions }
      end
    end

    record AmountView, code : String, label : String, amount : BigDecimal

    # Patrimoine net (D9) au jour : trésorerie, placements, biens, dettes ;
    # répartition par nature et par membre ; fin de chaque mois des douze
    # derniers.
    record WealthView,
      as_of : Time,
      cash : BigDecimal,
      investments : Array(AccountView),
      investments_total : BigDecimal,
      property_total : BigDecimal,
      debts_total : BigDecimal,
      accounts : Array(AccountView),
      by_nature : Array(AmountView),
      by_member : Array(AmountView),
      months : Array(AmountView) do
      def net : BigDecimal
        cash + investments_total + property_total - debts_total
      end
    end

    # Ligne d'un budget : montant budgété (mensuel ou annuel), budget et
    # réalisé à la date du jour et sur l'année, écart (réalisé − budget à
    # date), reste à dépenser ou à recevoir sur l'année, dépassement ; mois
    # par mois (budget, réalisé).
    record BudgetLineView,
      id : Int64,
      category_id : Int64,
      category_label : String,
      kind : String,
      period_kind : String,
      amount : BigDecimal,
      budget_to_date : BigDecimal,
      actual_to_date : BigDecimal,
      budget_year : BigDecimal,
      actual_year : BigDecimal,
      monthly_budget : Array(BigDecimal),
      monthly_actual : Array(BigDecimal) do
      def difference : BigDecimal
        actual_to_date - budget_to_date
      end

      def remaining : BigDecimal
        budget_year - actual_year
      end

      # Dépense au-delà du budget à date (ou de l'année pour un budget
      # annuel) ; une recette ne dépasse jamais.
      def over? : Bool
        return false unless kind == "expense"
        period_kind == "annual" ? actual_year > budget_year : actual_to_date > budget_to_date
      end

      def period_kind_key : String
        "perso.period_kinds.#{period_kind}"
      end
    end

    record BudgetView,
      id : Int64,
      year : Int32,
      forecast_id : Int64,
      months : Array(Time),
      lines : Array(BudgetLineView),
      as_of : Time do
      def over : Array(BudgetLineView)
        lines.select(&.over?)
      end
    end

    # Opération retenue par un récapitulatif fiscal.
    record TaxEntryView, entry_id : Int64, date : Time, label : String, amount : BigDecimal, documents : Int32

    # Ligne d'un récapitulatif : organisme, intervenant, catégorie ou
    # déplacement ; montant ; opérations qui le composent.
    record TaxItemView, label : String, amount : BigDecimal, entries : Array(TaxEntryView)

    # Case de la déclaration (table datée, présentée comme une aide).
    record TaxBoxView, code : String, label_key : String

    record TaxSectionView, code : String, items : Array(TaxItemView), boxes : Array(TaxBoxView), total : BigDecimal do
      def label_key : String
        "perso.tax_sections.#{code}"
      end
    end

    # Aide à la déclaration d'une année (D10) : rubriques, année du barème
    # et de la table des cases retenues.
    record TaxSummaryView, year : Int32, sections : Array(TaxSectionView), boxes_year : Int32?, mileage_year : Int32?

    record TripView, id : Int64, year : Int32, member_name : String?, fiscal_power : Int32, kilometers : Int32,
      label : String, allowance : BigDecimal

    record MileageRateView, id : Int64, year : Int32, fiscal_power : Int32, max_km : Int32?, coefficient : BigDecimal,
      constant : BigDecimal

    # Règle de catégorisation vue par le foyer : celle de `partiduo-bankimport`
    # dont la contrepartie est le compte d'une catégorie.
    record RuleView,
      id : Int64,
      category_id : Int64?,
      category_label : String,
      label_contains : String,
      amount : BigDecimal?,
      direction : String,
      account_id : Int64?,
      position : Int32,
      active : Bool,
      learned : Bool,
      hits : Int32,
      payee : String = "" do
      def direction_key : String
        "bankimport.directions.#{direction}"
      end
    end

    # Tuiles du tableau de bord : trésorerie, patrimoine net, échéances en
    # retard et à venir sous trente jours, catégories dépassées.
    record TileView,
      cash : BigDecimal,
      net_worth : BigDecimal,
      overdue : Int32,
      upcoming : Int32,
      over_budget : Array(String),
      account_count : Int32

    # Fichier produit (CSV, PDF).
    alias FileView = Partiduo::Api::Core::FileView
  end
end
