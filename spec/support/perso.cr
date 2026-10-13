# SPDX-License-Identifier: AGPL-3.0-or-later

# Valeur attendue présente : échoue clairement sinon (plutôt que `not_nil!`).
def present(value : T?) : T forall T
  value.nil? ? raise("valeur attendue, nil obtenu") : value
end

module Perso
  # Outils des specs : dossier foyer provisionné par le contrat du cœur
  # (type `household`, plan réduit, journal financier F01 du compte courant,
  # catégories et compte courant repris par les données initiales de
  # l'extension), années civiles 2025 à 2027, membres, acteurs.
  module SpecSupport
    alias Api = Perso::Api
    alias Acc = Partiduo::Api::Accounting

    # Permissions du cœur qu'emploie un membre adulte du foyer.
    CORE_PERMISSIONS = ["accounting.ledger.read", "accounting.ledger.write", "accounting.entry.read", "accounting.entry.post",
                        "accounting.entry.cancel", "accounting.account.read", "accounting.account.write",
                        "accounting.report.read", "accounting.report.write", "accounting.matching.write",
                        "cards.card.read", "cards.card.write", "core.attachment.read", "core.attachment.write",
                        "bankimport.read", "bankimport.import", "bankimport.admin"]

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    # Dossier foyer du régime, années 2025 à 2027, utilisateurs de test.
    def self.setup(regime : String = "fr") : Nil
      provision(regime)
      [2025, 2026, 2027].each { |year| PartiduoUi::Reference.fiscal_year(year) }
      user("alice@example.com", "Alice")
      user("bruno@example.com", "Bruno")
    end

    def self.provision(regime : String = "fr") : Nil
      settings = if regime == "be"
                   Partiduo::Api::Core::SettingsInput.new(company_name: "Foyer Peeters", tax_regime: "be", country_code: "BE",
                     domain: "foyer.partiduo.localhost")
                 else
                   Partiduo::Api::Core::SettingsInput.new(company_name: "Foyer Martin", tax_regime: "fr", country_code: "FR",
                     domain: "foyer.partiduo.localhost")
                 end
      input = Partiduo::Api::Core::ProvisionInput.new(settings: settings, kind: "household")
      result = Partiduo::Api::Core.provision(system, input)
      raise "provisionnement refusé : #{result.error_keys.join(", ")}" if result.failure?
    end

    def self.user(email : String, first_name : String) : Int64
      input = Partiduo::Api::Auth::UserInput.new(email: email, first_name: first_name, last_name: "Test", role: "member",
        profile_id: PartiduoUi::Accounts.profile_id("ADMIN"), password: PartiduoUi::Accounts::PASSWORD)
      Partiduo::Api::Auth.create_user(system, input).value!.user.id
    end

    def self.user_id(email : String) : Int64
      Partiduo::Api::Auth.user_by_email(system, email).try(&.id) || raise "utilisateur #{email} absent"
    end

    def self.actor(email : String, permissions : Array(String)) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id(email), permissions, level: 3)
    end

    # Parent : toute l'extension et les droits du cœur qu'elle emploie.
    def self.parent : Partiduo::Api::Actor
      actor("alice@example.com", [Api::READ, Api::WRITE, Api::BUDGET, Api::ADMIN, "auth.users.manage"] + CORE_PERMISSIONS)
    end

    # Conseiller extérieur : lecture seule.
    def self.advisor : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, "accounting.ledger.read", "accounting.entry.read", "accounting.account.read",
                                  "accounting.report.read"])
    end

    def self.category(label : String) : Api::CategoryView
      Api.categories(system).find { |view| view.label == label } || raise "catégorie #{label} absente"
    end

    def self.account(label : String) : Api::AccountView
      Api.accounts(system).find { |view| view.label == label } || raise "compte #{label} absent"
    end

    def self.current_account : Api::AccountView
      Api.accounts(system).find(&.nature.==("current")) || raise "compte courant absent"
    end

    def self.livret : Api::AccountView
      result = Api.create_account(parent, Api::AccountInput.new(nature: "savings", label: "Livret A", institution: "Banque",
        rate: d("3"), ceiling: d("22950")))
      raise "livret refusé : #{result.error_keys.join(", ")}" if result.failure?
      result.value!
    end

    def self.spend(label : String, amount : String, day : String, category : String = "Alimentation",
                   account : Api::AccountView = current_account, kind : String = "expense") : Api::OperationView
      input = Api::OperationInput.new(account_id: account.id, date: date(day), amount: d(amount), kind: kind,
        category_id: category(category).id, payee: label)
      result = Api.record_operation(parent, input)
      raise "opération refusée : #{result.error_keys.join(", ")}" if result.failure?
      result.value!
    end

    # Importe un relevé CSV d'une ligne dans le compte courant
    # (`partiduo-bankimport`), choisit sa contrepartie et la transfère.
    def self.import_line(label : String, amount : String, account : String, day : String = "15/09/2026") : Nil
      format = Bankimport::Api.formats(parent).first? || Bankimport::Api.create_format(parent,
        Bankimport::Api::FormatInput.new(name: "Banque", date_column: 1, label_column: 2, amount_column: 3)).value!
      content = "Date;Libellé;Montant\n#{day};#{label};#{amount.sub('.', ',')}\n".to_slice
      Bankimport::Api.import_file(parent, Bankimport::Api::ImportInput.new(ledger_id: current_account.ledger_id,
        filename: "releve-#{Random.rand(100_000)}.csv", content: content, kind: "csv", format_id: format.id,
        allow_same_file: true)).value!
      line = Bankimport::Api.lines(parent).last
      Bankimport::Api.set_counterpart(parent, line.id, Bankimport::Api::CounterpartInput.new(account: account, learn: false)).value!
      report = Bankimport::Api.transfer(parent, [line.id]).value!
      raise "transfert refusé" unless report.failed.empty?
    end

    # Lignes d'une écriture : `{compte, sens, montant}` triés.
    def self.lines(entry_id : Int64) : Array({String, String, BigDecimal})
      Acc.entry(system, entry_id).lines.map { |line| {line.account_number, line.side.code, line.amount} }.sort_by! { |line| {line[0], line[1]} }
    end

    def self.balance(number : String) : BigDecimal
      Acc.account_statement(system, Acc::StatementQuery.new(account: number)).balance
    end
  end
end

# Exécute le bloc avec une autre liste de modules actifs (`PARTIDUO_MODULES`),
# puis restaure la configuration.
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end
