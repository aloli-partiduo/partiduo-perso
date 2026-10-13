# SPDX-License-Identifier: AGPL-3.0-or-later

# Données initiales d'un dossier foyer neuf, l'extension active (ADR-011
# A3, D-PER-001) : après le plan réduit et les journaux de la Comptabilité,
# les catégories reprises des classes 6 et 7, et le compte courant (journal
# financier du plan) repris comme compte du foyer. Rien pour un dossier
# d'entreprise. Les années civiles sont créées à la première saisie qui en
# a besoin (D-PER-015), pas ici : le dossier choisit lui-même ses premiers
# exercices.
Partiduo::Api::InitialData.register(Perso::CODE, "household", order: 30,
  kinds: [Partiduo::Api::InitialData::HOUSEHOLD]) do |context|
  Perso::Categories.load_defaults(context.actor)
  Perso::Api::Acc.ledgers(context.actor, Perso::Api::Acc::LedgerKind::Financial).each do |ledger|
    next if Perso::Account.filter(ledger_id: ledger.id).exists?
    label = I18n.with_locale(context.locale) { I18n.t("perso.labels.current_account") }
    input = Perso::Api::AccountInput.new(nature: "current", label: label, ledger_id: ledger.id, position: 10)
    _row, errors = Perso::Accounts.create(context.actor, input)
    raise "compte courant non repris : #{errors.map(&.key).join(", ")}" unless errors.empty?
  end
end
