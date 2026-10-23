# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../lib/partiduo-ui-bulma/scripts/api_boundary"

private def source_files(pattern : String) : Array(String)
  Dir.glob(File.join(Perso::SpecSupport::ROOT, pattern)).reject(&.includes?("/lib/")).sort!
end

describe "Conventions de l'extension PERSO" do
  it "ouvre chaque fichier source par l'en-tête SPDX" do
    missing = (source_files("{src,ui,spec,config,scripts}/**/*.cr") + source_files("*.cr")).reject do |path|
      File.read_lines(path).first? == "# SPDX-License-Identifier: AGPL-3.0-or-later"
    end
    missing += source_files("ui/**/*.html").reject do |path|
      File.read(path).starts_with?("{# SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing += source_files("ui/**/*.{js,css}").reject do |path|
      File.read(path).includes?("SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing.should be_empty
  end

  it "ne cite le logiciel d'origine que dans la documentation (*.adoc, *.md)" do
    root = Perso::SpecSupport::ROOT
    name = "noa" + "lyss"
    offenders = Dir.glob(File.join(root, "**", "*")).reject do |path|
      path.includes?("/lib/") || path.includes?("/bin/") || path.includes?("/tmp/") || path.ends_with?(".adoc") ||
        path.ends_with?(".md") || File.directory?(path)
    end.select { |path| File.read(path).downcase.includes?(name) rescue false }
    offenders.should be_empty
  end

  it "a les mêmes clés de traduction dans chaque langue de l'interface, aux mêmes interpolations" do
    %w[src/perso/locales ui/bulma/locales].flat_map do |dir|
      PartiduoUi::Translations.parity_failures(File.join(Perso::SpecSupport::ROOT, dir))
    end.should eq([] of String)
  end

  it "traduit dans chaque langue de l'interface toute clé passée à I18n.t ou {% translate %} (cœur, interface, extension)" do
    PartiduoUi::Translations.unknown_keys(Perso::SpecSupport::ROOT, %w[src/**/*.cr ui/**/*.cr ui/**/*.html]).should eq([] of String)
  end

  it "traduit toute clé citée par le code et les gabarits de l'extension" do
    cited = source_files("{src,ui}/**/*.{cr,html}").flat_map do |path|
      File.read(path).scan(/["'](perso(?:_ui)?\.[a-z_]+(?:\.[a-z_]+)+)["']/).map(&.[1])
    end.uniq! - Partiduo::Modules[Perso::CODE].permissions
    cited.size.should be > 50
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        cited.select { |key| I18n.t(key).includes?("missing") && I18n.t("#{key}.one").includes?("missing") }
          .map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "traduit toute clé d'erreur du contrat (perso.errors.*) dans chaque langue de l'interface" do
    cited = source_files("src/**/*.cr").flat_map do |path|
      text = File.read(path)
      text.scan(/error\([^()]*?, "([a-z_]+(?:\.[a-z_]+)+)"/).map(&.[1]) + text.scan(/issue\(\w+, "([a-z_]+(?:\.[a-z_]+)+)"/).map(&.[1])
    end.uniq!
    cited.size.should be > 30
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        cited.select { |key| I18n.t("perso.errors.#{key}").includes?("missing") }.map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "traduit chaque nature, sorte, état, fréquence, mode, étiquette, rubrique et case" do
    {
      "perso.natures"            => Perso::Api::NATURES,
      "perso.asset_kinds"        => Perso::Api::ASSET_KINDS,
      "perso.category_kinds"     => Perso::Api::CATEGORY_KINDS,
      "perso.tax_tags"           => Perso::Api::TAX_TAGS,
      "perso.member_roles"       => Perso::Api::MEMBER_ROLES,
      "perso.operation_kinds"    => Perso::Api::OPERATION_KINDS,
      "perso.operation_statuses" => Perso::Api::OPERATION_STATUSES,
      "perso.sources"            => Perso::Api::SOURCES,
      "perso.frequencies"        => Perso::Api::FREQUENCIES,
      "perso.due_statuses"       => Perso::Api::DUE_STATUSES,
      "perso.deferral_kinds"     => Perso::Api::DEFERRAL_KINDS,
      "perso.insurance_modes"    => Perso::Api::INSURANCE_MODES,
      "perso.prepayment_modes"   => Perso::Api::PREPAYMENT_MODES,
      "perso.loan_reasons"       => Perso::Api::LOAN_REASONS,
      "perso.period_kinds"       => Perso::Api::PERIOD_KINDS,
      "perso.document_kinds"     => Perso::Api::DOCUMENT_KINDS,
      "perso.tax_sections"       => Perso::Api::TAX_SECTIONS,
      "perso.permissions"        => %w[read write budget admin],
      "perso.tax_boxes"          => Perso::Tax::BOXES["fr"].as_h.values.flat_map(&.as_h.values.flat_map(&.as_a.map(&.as_s.downcase))).uniq!,
      "perso_ui.periods"         => Perso::Ui::OperationsHandler::PERIODS,
    }.each do |scope, codes|
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { codes.each { |code| I18n.t("#{scope}.#{code}").should_not contain("missing") } }
      end
    end
  end

  it "écrit ses montants en BigDecimal, jamais en flottant" do
    source_files("{src,ui}/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).compact_map do |line, number|
        "#{path}:#{number}" if ApiBoundary.strip_comment(line).matches?(/\bFloat(32|64)?\b|\.to_f\b/)
      end
    end.should be_empty
  end

  it "écrit ses feuilles de style en propriétés logiques, avec les jetons du thème (ADR-005 D7)" do
    physical = /(?:margin|padding|border)-(?:left|right|top|bottom)\b|\b(?:left|right)\s*:|text-align:\s*(?:left|right)|float:\s*(?:left|right)/
    source_files("ui/**/*.css").each do |path|
      File.read(path).scan(physical).map(&.[0]).should eq([] of String)
      File.read(path).scan(/#[0-9a-fA-F]{3,6}\b|rgba?\(/).map(&.[0]).should eq([] of String)
    end
  end

  it "ne parle au cœur, depuis ui/bulma, que par Partiduo::Api (ADR-005 D3)" do
    root = Perso::SpecSupport::ROOT
    ApiBoundary.scan([File.join(root, "ui")], base: root).map(&.to_s).should eq([] of String)
  end

  it "ne parle au métier de l'extension, depuis ui/bulma, que par Perso::Api (ADR-005 D4)" do
    allowed = %w[Api Ui CODE VERSION]
    leaks = source_files("ui/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).flat_map do |line, number|
        ApiBoundary.strip_comment(line).scan(/(?<![\w:])Perso::([A-Za-z_]\w*)/).compact_map do |match|
          "#{path.lchop(Perso::SpecSupport::ROOT + "/")}:#{number} Perso::#{match[1]}" unless allowed.includes?(match[1])
        end
      end
    end
    leaks.should be_empty
  end

  it "n'utilise que des icônes de la planche de l'interface (ADR-005 D5)" do
    lucide = File.join(Perso::SpecSupport::ROOT, "lib", "partiduo-ui-bulma", "icons", "lucide")
    known = Dir.glob(File.join(lucide, "*.svg")).map { |path| File.basename(path, ".svg") }
    known.should_not be_empty
    used = source_files("ui/bulma/templates/**/*.html").flat_map do |path|
      File.read(path).scan(/_icon\.html" with name="([a-z0-9-]+)"/).map { |match| "#{path.lchop(Perso::SpecSupport::ROOT + "/")} #{match[1]}" }
    end
    used += source_files("ui/**/*.cr").flat_map do |path|
      File.read(path).scan(/_action\("[^"]+", [^\n]*?, "(?:primary|danger|)", "([a-z0-9-]+)"\)/).map { |match| "#{path} #{match[1]}" }
    end
    used.reject { |item| known.includes?(item.split(' ').last) }.should be_empty
  end
end
