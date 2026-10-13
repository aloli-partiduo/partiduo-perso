# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Ui
    # Base des écrans de l'extension, sur celle des écrans du référentiel de
    # l'interface (listes, formulaires et consultations des gabarits
    # `ui/reference/*.html`) : fil d'Ariane « Mon foyer › … », listes de
    # choix, lecture des champs. L'accès a déjà été contrôlé par
    # `PartiduoUi::ExtensionHandler` à partir du montage ; `Perso::Api`
    # vérifie encore la permission de chaque commande.
    abstract class Handler < PartiduoUi::ReferenceHandler
      alias Api = Perso::Api
      alias Acc = Partiduo::Api::Accounting
      alias Form = PartiduoUi::Form
      alias Screen = PartiduoUi::Screen

      def actor : Partiduo::Api::Actor
        current.actor
      end

      def crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("perso.menu.perso", Ui.url("operations"))]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def settings_crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("core.menu.settings")]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def can_write? : Bool
        can?(Api::WRITE)
      end

      def can_budget? : Bool
        can?(Api::BUDGET)
      end

      def can_admin? : Bool
        can?(Api::ADMIN)
      end

      # --- Lecture des champs ---------------------------------------------------------

      def id_field(name : String) : Int64?
        field(name).to_i64?
      end

      def int_field(name : String) : Int32?
        field(name).to_i?
      end

      def decimal_field(name : String) : BigDecimal?
        text = field(name)
        text.empty? ? nil : fmt.parse_decimal(text)
      end

      def date_field(name : String) : Time?
        fmt.parse_date(field(name))
      end

      # Date lue ; erreur de formulaire si elle est illisible (ou absente et
      # exigée).
      def date_value(form : Form, name : String, required : Bool = false) : Time?
        value = date_field(name)
        if value.nil? && (required || !field(name).empty?)
          form.add_error(name, I18n.t(field(name).empty? ? "ui.forms.required" : "ui.forms.invalid_date"))
        end
        value
      end

      def decimal_value(form : Form, name : String, required : Bool = false) : BigDecimal?
        value = decimal_field(name)
        if value.nil? && (required || !field(name).empty?)
          form.add_error(name, I18n.t(field(name).empty? ? "ui.forms.required" : "ui.forms.invalid_number"))
        end
        value
      end

      def int_value(form : Form, name : String, required : Bool = false) : Int32?
        value = int_field(name)
        if value.nil? && (required || !field(name).empty?)
          form.add_error(name, I18n.t(field(name).empty? ? "ui.forms.required" : "ui.forms.invalid_integer"))
        end
        value
      end

      def submitted(names : Array(String)) : Hash(String, String)
        names.to_h { |name| {name, field(name)} }
      end

      def year_param : Int32
        query("year").to_i? || Partiduo::Api::Core.today.year
      end

      # --- Listes de choix --------------------------------------------------------------

      def blank_option(label_key : String = "perso_ui.forms.none") : Form::Option
        option("", I18n.t(label_key))
      end

      def code_options(codes : Array(String), scope : String) : Array(Form::Option)
        codes.map { |code| option(code, I18n.t("#{scope}.#{code}")) }
      end

      @accounts : Array(Api::AccountView)?

      def accounts : Array(Api::AccountView)
        @accounts ||= Api.accounts(actor)
      end

      # Comptes où l'acteur peut saisir.
      def account_options(writable_only : Bool = true, blank : Bool = false) : Array(Form::Option)
        list = accounts.reject(&.closed)
        list = list.select(&.writable) if writable_only
        options = list.map { |view| option(view.id.to_s, view.label) }
        blank ? [blank_option] + options : options
      end

      @categories : Array(Api::CategoryView)?

      def categories : Array(Api::CategoryView)
        @categories ||= Api.categories(actor, include_inactive: false)
      end

      # Catégories où l'on peut ranger une opération : sans sous-catégorie ;
      # `kind` : un seul sens.
      def category_options(kind : String? = nil, blank : Bool = true, postable : Bool = true) : Array(Form::Option)
        list = categories
        list = list.select(&.kind.==(kind)) if kind
        list = list.select(&.children_count.zero?) if postable
        options = list.map { |view| option(view.id.to_s, "#{I18n.t(view.kind_key)} · #{view.full_label}") }
        blank ? [blank_option] + options : options
      end

      def member_options : Array(Form::Option)
        [blank_option] + Api.members(actor).map { |member| option(member.id.to_s, member.display_name) }
      end

      def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      # Redirection après une commande, avec le message du résultat.
      def after(result, success_key : String, url : String, params = {} of String => String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key, params)
        else
          flash["danger"] = messages(result)
        end
        go(url)
      end

      # Consultation (gabarit `perso/detail.html`) : rubriques, actions,
      # onglets facultatifs, dépôt d'un justificatif (`upload_url`),
      # formulaire facultatif (`set_form`). `format=csv` exporte le premier
      # tableau exportable, `format=pdf` tous les tableaux exportables.
      def show_detail(title : String, crumbs : Array(Screen::Crumb), sections : Array(Screen::Section),
                      actions = [] of Screen::Action, intro : String? = nil, status_tag : String? = nil,
                      tabs : Array(Screen::Tab)? = nil, upload_url : String? = nil, status : Int32 = 200) : Marten::HTTP::Response
        tables = sections.compact_map(&.table).select(&.exportable)
        if export? && (first = tables.first?)
          name = Table.fold(title).gsub(/[^a-z0-9]+/, "-").strip('-')
          return pdf? ? sections_pdf_response(title, sections.select { |section| section.table.try(&.exportable) }, name) : csv_response(prepare(first, false), name)
        end
        tables.each(&.pdf=(true))
        context["title"] = title
        context["crumbs"] = crumbs
        context["actions"] = actions
        context["sections"] = sections
        context["intro"] = intro
        context["status"] = status_tag
        context["tabs"] = tabs.try { |list| Screen.listed(list) }
        context["upload_url"] = upload_url
        context["document_kinds"] = code_options(Api::DOCUMENT_KINDS, "perso.document_kinds")
        page("perso/detail.html", status: status)
      end

      def file_response(file : Api::FileView) : Marten::HTTP::Response
        type = file.content_type.starts_with?("text/") ? "#{file.content_type}; charset=utf-8" : file.content_type
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: type)
        response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
        response
      end
    end

    # `/ext/PERSO/` : les opérations.
    class IndexHandler < Handler
      def get
        go(Ui.url("operations"))
      end
    end
  end
end
