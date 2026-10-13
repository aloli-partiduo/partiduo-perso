# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Exports complets en CSV (D11) et récapitulatifs fiscaux en CSV et en PDF
  # (D10). Montants en décimal à point, dates ISO ; séparateur `;`.
  # Interne.
  module Exports
    alias Actor = Partiduo::Api::Actor
    alias Core = Partiduo::Api::Core

    SEPARATOR = ';'

    def self.csv(name : String, &block : CSV::Builder ->) : Api::FileView
      content = CSV.build(separator: SEPARATOR) { |csv| block.call(csv) }
      Api::FileView.new("#{name}.csv", "text/csv", content.to_slice)
    end

    # Montant au centime, toujours deux décimales (`-100.00`).
    def self.amount(value : BigDecimal?) : String
      number = value || return ""
      text = Records.cents(number).to_s
      whole, _, decimals = text.partition('.')
      "#{whole}.#{decimals.ljust(2, '0')[0, 2]}"
    end

    def self.date(value : Time?) : String
      value.try(&.to_s("%Y-%m-%d")) || ""
    end

    def self.operations(actor : Actor, query : Api::OperationQuery) : Api::FileView
      views = Operations.list(actor, query)
      csv("operations") do |csv|
        csv.row I18n.t("perso.csv.operations").split(',')
        views.reverse_each do |view|
          csv.row [date(view.date), view.account_label, I18n.t(view.kind_key), view.payee, view.category_label,
                   amount(view.amount), view.member_name || "", view.note, view.entry_id.to_s, I18n.t("perso.sources.#{view.source}")]
        end
      end
    end

    def self.accounts(actor : Actor) : Api::FileView
      views = Accounts.views(actor)
      csv("comptes") do |csv|
        csv.row I18n.t("perso.csv.accounts").split(',')
        views.each do |view|
          csv.row [view.label, I18n.t(view.nature_key), view.institution, view.holders.map(&.display_name).join(", "),
                   amount(view.balance), amount(view.value), view.last_valued_on.try { |day| date(day) } || "",
                   view.closed ? "1" : "0"]
        end
      end
    end

    def self.valuations(actor : Actor) : Api::FileView
      accounts = Accounts.views(actor).select(&.valued?)
      csv("valorisations") do |csv|
        csv.row I18n.t("perso.csv.valuations").split(',')
        accounts.each do |account|
          Valuation.filter(account_id: account.id).order(:valued_on).each do |row|
            lines = ValuationLine.filter(valuation_id: row.id).order(:id).to_a
            if lines.empty?
              csv.row [account.label, date(row.valued_on), amount(row.amount), "", "", "", row.note.to_s]
            else
              lines.each do |line|
                csv.row [account.label, date(row.valued_on), amount(line.amount), line.security.to_s, line.quantity.to_s,
                         line.price.to_s, row.note.to_s]
              end
            end
          end
        end
      end
    end

    def self.tax_csv(summary : Api::TaxSummaryView) : Api::FileView
      csv("declaration-#{summary.year}") do |csv|
        csv.row I18n.t("perso.csv.tax").split(',')
        summary.sections.each do |section|
          boxes = section.boxes.map(&.code).join(" ")
          section.items.each do |item|
            if item.entries.empty?
              csv.row [I18n.t(section.label_key), boxes, item.label, "", "", amount(item.amount), ""]
            else
              item.entries.each do |entry|
                csv.row [I18n.t(section.label_key), boxes, item.label, date(entry.date), entry.entry_id.to_s,
                         amount(entry.amount), entry.documents.to_s]
              end
            end
          end
          csv.row [I18n.t(section.label_key), boxes, I18n.t("perso.labels.total"), "", "", amount(section.total), ""]
        end
      end
    end

    # Récapitulatif en PDF/A par le tableau neutre du socle (`table_pdf`).
    def self.tax_pdf(actor : Actor, summary : Api::TaxSummaryView, amount_text : Proc(BigDecimal, String)) : Partiduo::Api::Result(Api::FileView)
      columns = [
        Core::TableColumnInput.new(I18n.t("perso.pdf.item"), "text", 4.0),
        Core::TableColumnInput.new(I18n.t("perso.pdf.boxes"), "text", 1.5),
        Core::TableColumnInput.new(I18n.t("perso.pdf.amount"), "amount", 1.5),
      ]
      rows = [] of Core::TableRowInput
      summary.sections.each do |section|
        rows << Core::TableRowInput.new([I18n.t(section.label_key), section.boxes.map(&.code).join(" "), ""], "heading")
        section.items.each do |item|
          rows << Core::TableRowInput.new([item.label, "", amount_text.call(item.amount)], "line", 1)
        end
        rows << Core::TableRowInput.new([I18n.t("perso.labels.total"), "", amount_text.call(section.total)], "subtotal")
      end
      subtitle = [I18n.t("perso.pdf.subtitle", year: summary.year.to_s), I18n.t("perso.pdf.notice")]
      Core.table_pdf(actor, Core::TableInput.new(name: "declaration-#{summary.year}",
        title: I18n.t("perso.pdf.title", year: summary.year.to_s), columns: columns, rows: rows, subtitle: subtitle,
        landscape: false))
    end
  end
end
