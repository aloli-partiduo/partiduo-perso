# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Ui
    # `/ext/PERSO/tax` : l'aide à la déclaration de revenus d'une année
    # (D10) — dons, emploi à domicile, frais réels (avec les frais
    # kilométriques), revenus fonciers ; cases de la déclaration en aide ;
    # éditions PDF et CSV. Pas de télédéclaration.
    class TaxHandler < Handler
      def get
        year = query("year").to_i? || Partiduo::Api::Core.today.year - 1
        summary = Api.tax_summary(actor, year)
        sections = summary.sections.map do |section|
          rows = section.items.map do |item|
            detail = item.entries.map { |entry| "#{fmt.date(entry.date)} #{fmt.amount(entry.amount)}" }.join(" ; ")
            documents = item.entries.sum(&.documents)
            Table::Row.new([Table::Cell.new(item.label), Table::Cell.new(item.entries.size.to_s), Table::Cell.new(documents.to_s),
                            Present.money(fmt, item.amount), Table::Cell.new(detail)])
          end
          footer = [Table::Row.new([Table::Cell.new(I18n.t("perso.labels.total")), Table::Cell.new(""), Table::Cell.new(""),
                                    Present.money(fmt, section.total), Table::Cell.new("")])]
          table = Table.new(I18n.t(section.label_key), [
            Table::Column.new("label", I18n.t("perso_ui.tax.item")),
            Table::Column.new("count", I18n.t("perso_ui.tax.operations"), "number"),
            Table::Column.new("documents", I18n.t("perso_ui.tax.documents"), "number", secondary: true),
            Table::Column.new("amount", I18n.t("perso_ui.tax.amount"), "number"),
            Table::Column.new("detail", I18n.t("perso_ui.tax.detail"), secondary: true),
          ], rows, Ui.url_with("tax", {"year" => year.to_s}), empty_message: I18n.t("perso_ui.tax.empty"),
            id: "perso-tax-#{section.code.gsub('_', '-')}", footer_rows: footer)
          table.exportable = false
          boxes = section.boxes.map { |box| "#{box.code} (#{I18n.t(box.label_key)})" }.join(", ")
          Screen::Section.new(I18n.t(section.label_key), table: table,
            note: boxes.empty? ? nil : I18n.t("perso_ui.tax.boxes", boxes: boxes, year: summary.boxes_year.to_s))
        end
        trips = Api.trips(actor, year)
        trip_table = Table.new(I18n.t("perso_ui.tax.trips"), [
          Table::Column.new("label", I18n.t("perso_ui.tax.trip_label")),
          Table::Column.new("member", I18n.t("perso_ui.operations.member"), secondary: true),
          Table::Column.new("power", I18n.t("perso_ui.tax.fiscal_power"), "number"),
          Table::Column.new("km", I18n.t("perso_ui.tax.kilometers"), "number"),
          Table::Column.new("allowance", I18n.t("perso_ui.tax.allowance"), "number"),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], trips.map do |trip|
          actions = can_write? ? [post_action("perso_ui.tax.delete_trip", Ui.url("trip_delete", id: trip.id), "perso_ui.tax.confirm_delete_trip", "row-danger", "trash-2")] : [] of Screen::Action
          Table::Row.new([Table::Cell.new(trip.label), Table::Cell.new(trip.member_name || ""), Table::Cell.new(trip.fiscal_power.to_s),
                          Table::Cell.new(trip.kilometers.to_s), Present.money(fmt, trip.allowance), Table::Cell.new("", actions: actions)])
        end, Ui.url_with("tax", {"year" => year.to_s}), empty_message: I18n.t("perso_ui.tax.no_trips"), id: "perso-trips")
        trip_table.exportable = false
        sections << Screen::Section.new(I18n.t("perso_ui.tax.trips"), table: trip_table,
          note: I18n.t("perso_ui.tax.mileage_year", year: summary.mileage_year.to_s))
        if can_write?
          set_form(trip_form(year), Ui.url_with("trip_add", {"year" => year.to_s}), I18n.t("perso_ui.tax.add_trip"),
            title: I18n.t("perso_ui.tax.add_trip"))
        end
        current = Partiduo::Api::Core.today.year
        tabs = ((current - 3)..current).to_a.reverse.map do |item|
          Screen::Tab.new(item.to_s, Ui.url_with("tax", {"year" => item.to_s}), item == year)
        end
        actions = [
          link_action("perso_ui.tax.pdf", Ui.url_with("tax_pdf", {"year" => year.to_s}), "primary", "download"),
          link_action("perso_ui.tax.csv", Ui.url_with("tax_csv", {"year" => year.to_s}), "", "download"),
        ]
        show_detail(I18n.t("perso_ui.tax.title", year: year), crumbs({I18n.t("perso.menu.perso_tax"), nil}), sections, actions,
          intro: I18n.t("perso_ui.tax.intro"), tabs: tabs)
      end

      private def trip_form(year : Int32) : Form
        Form.new([Form::Group.new(nil, [
          Form::Field.new("label", I18n.t("perso_ui.tax.trip_label"), maxlength: 255),
          Form::Field.new("member_id", I18n.t("perso_ui.operations.member"), "select", "", options: member_options),
          Form::Field.new("fiscal_power", I18n.t("perso_ui.tax.fiscal_power"), "number", "5", required: true, mono: true),
          Form::Field.new("kilometers", I18n.t("perso_ui.tax.kilometers"), "number", "", required: true, mono: true),
          Form::Field.new("year", "", "hidden", year.to_s),
        ])])
      end
    end

    class TaxCsvHandler < Handler
      def get
        file_response(Api.tax_csv(actor, year_param))
      end
    end

    class TaxPdfHandler < Handler
      def get
        formatter = fmt
        result = Api.tax_pdf(actor, year_param, ->(value : BigDecimal) { formatter.amount(value) })
        if file = result.value?
          return file_response(file)
        end
        Marten::HTTP::Response.new(content: messages(result), content_type: "text/plain; charset=utf-8", status: 422)
      end
    end

    class TripAddHandler < Handler
      def get
        go(Ui.url("tax"))
      end

      def post
        year = query("year").to_i? || field("year").to_i? || Partiduo::Api::Core.today.year
        power = int_field("fiscal_power")
        km = int_field("kilometers")
        if power.nil? || km.nil?
          flash["danger"] = I18n.t("perso_ui.tax.trip_invalid")
          return go(Ui.url_with("tax", {"year" => year.to_s}))
        end
        result = Api.add_trip(actor, Api::TripInput.new(year, power, km, id_field("member_id"), field("label")))
        after(result, "perso_ui.flash.trip_added", Ui.url_with("tax", {"year" => year.to_s}))
      end
    end

    class TripDeleteHandler < Handler
      def get
        go(Ui.url("tax"))
      end

      def post
        after(Api.delete_trip(actor, id_param), "perso_ui.flash.trip_deleted", Ui.url("tax"))
      end
    end
  end
end
