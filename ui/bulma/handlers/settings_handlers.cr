# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  module Ui
    # `/ext/PERSO/categories` : les catégories (D3), deux niveaux, avec la
    # création d'une catégorie sous la liste. Le numéro de compte n'est
    # jamais montré.
    class CategoriesHandler < Handler
      def get
        render_list(category_form({"kind" => "expense"}))
      end

      def post
        form = category_form(submitted(%w[label kind parent_id tax_tag position]))
        position = int_value(form, "position") || 100
        unless form.invalid
          input = Api::CategoryInput.new(label: field("label"), kind: field("kind").presence || "expense",
            parent_id: id_field("parent_id"), tax_tag: field("tax_tag"), position: position)
          result = Api.create_category(actor, input)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.category_created", label: result.value!.label)
            return go(Ui.url("categories"))
          end
          form.add_errors(result.errors, fmt)
        end
        render_list(form, 422)
      end

      def category_form(values : Hash(String, String), creating : Bool = true) : Form
        value = ->(name : String) { values[name]? || "" }
        fields = [Form::Field.new("label", I18n.t("perso_ui.categories.label"), value: value.call("label"), required: true, maxlength: 120)]
        if creating
          parents = Api.categories(actor).select(&.depth.==(0)).map { |view| option(view.id.to_s, "#{I18n.t(view.kind_key)} · #{view.label}") }
          fields << Form::Field.new("kind", I18n.t("perso_ui.categories.kind"), "select", value.call("kind"),
            options: code_options(Api::CATEGORY_KINDS, "perso.category_kinds"), required: true)
          fields << Form::Field.new("parent_id", I18n.t("perso_ui.categories.parent"), "select", value.call("parent_id"),
            options: [blank_option("perso_ui.categories.top_level")] + parents, help: I18n.t("perso_ui.categories.parent_help"))
        end
        fields << Form::Field.new("tax_tag", I18n.t("perso_ui.categories.tax_tag"), "select", value.call("tax_tag"),
          options: [blank_option] + code_options(Api::TAX_TAGS, "perso.tax_tags"), help: I18n.t("perso_ui.categories.tax_tag_help"))
        fields << Form::Field.new("position", I18n.t("perso_ui.accounts.position"), "number", value.call("position").presence || "100", mono: true)
        fields << Form::Field.new("active", I18n.t("perso_ui.categories.active"), "checkbox", value.call("active")) unless creating
        Form.new([Form::Group.new(nil, fields)])
      end

      private def render_list(form : Form, status : Int32 = 200) : Marten::HTTP::Response
        rows = Api.categories(actor).map do |view|
          actions = [
            link_action("perso_ui.categories.edit", Ui.url("category_edit", id: view.id), "row", "pencil"),
            post_action("perso_ui.categories.delete", Ui.url("category_delete", id: view.id), "perso_ui.categories.confirm_delete", "row-danger", "trash-2"),
          ]
          label = view.depth == 1 ? "— #{view.label}" : view.label
          Table::Row.new([
            Table::Cell.new(label), Table::Cell.new(I18n.t(view.kind_key)),
            Table::Cell.new(view.tax_tag_key.try { |key| I18n.t(key) } || ""),
            Table::Cell.new(view.active ? I18n.t("perso_ui.categories.active") : I18n.t("perso_ui.categories.inactive")),
            Table::Cell.new("", actions: actions),
          ])
        end
        table = Table.new(I18n.t("perso.menu.perso_categories"), [
          Table::Column.new("label", I18n.t("perso_ui.categories.label"), sortable: false),
          Table::Column.new("kind", I18n.t("perso_ui.categories.kind"), sortable: false),
          Table::Column.new("tax_tag", I18n.t("perso_ui.categories.tax_tag"), sortable: false),
          Table::Column.new("state", I18n.t("perso_ui.schedule.status"), sortable: false),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], rows, Ui.url("categories"), empty_message: I18n.t("perso_ui.categories.none"), id: "perso-categories")
        set_form(form, Ui.url("categories"), I18n.t("perso_ui.categories.new"), title: I18n.t("perso_ui.categories.new"))
        actions = [post_action("perso_ui.categories.load", Ui.url("categories_load"), "perso_ui.categories.load_question", "", "refresh-cw")]
        list_page(I18n.t("perso.menu.perso_categories"), table, settings_crumbs({I18n.t("perso.menu.perso_categories"), nil}),
          "perso_ui.categories.csv_name", actions, intro: I18n.t("perso_ui.categories.intro"), status: status, filter: false)
      end
    end

    class CategoriesLoadHandler < Handler
      def get
        go(Ui.url("categories"))
      end

      def post
        result = Api.load_categories(actor)
        after(result, "perso_ui.flash.categories_loaded", Ui.url("categories"), {"count" => result.value?.to_s})
      end
    end

    class CategoryEditHandler < CategoriesHandler
      def get
        view = Api.category(actor, id_param)
        show(view, category_form({"label" => view.label, "tax_tag" => view.tax_tag, "position" => view.position.to_s,
                                  "active" => view.active ? "1" : ""}, false))
      end

      def post
        view = Api.category(actor, id_param)
        form = category_form(submitted(%w[label tax_tag position active]), false)
        position = int_value(form, "position") || 100
        unless form.invalid
          input = Api::CategoryInput.new(label: field("label"), kind: view.kind, tax_tag: field("tax_tag"), position: position,
            active: checkbox("active"))
          result = Api.update_category(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.saved")
            return go(Ui.url("categories"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::CategoryView, form : Form) : Marten::HTTP::Response
        form_page(view.full_label, settings_crumbs({I18n.t("perso.menu.perso_categories"), Ui.url("categories")}, {view.label, nil}),
          form, Ui.url("category_edit", id: view.id), I18n.t("ui.forms.save"), Ui.url("categories"))
      end
    end

    class CategoryDeleteHandler < Handler
      def get
        go(Ui.url("categories"))
      end

      def post
        after(Api.delete_category(actor, id_param), "perso_ui.flash.category_deleted", Ui.url("categories"))
      end
    end

    # `/ext/PERSO/rules` : les règles de catégorisation des relevés importés
    # (D6), tenues par `partiduo-bankimport` : « le libellé contient… »,
    # « le montant vaut… », alors telle catégorie.
    class RulesHandler < Handler
      FIELDS = %w[label_contains amount direction category_id payee account_id position active]

      def get
        render_list(rule_form({"direction" => "any", "position" => "100", "active" => "1"}))
      end

      def post
        form = rule_form(submitted(FIELDS))
        if input = read_input(form)
          result = Api.save_rule(actor, input)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.rule_saved")
            return go(Ui.url("rules"))
          end
          form.add_errors(result.errors, fmt)
        end
        render_list(form, 422)
      end

      def rule_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        Form.new([Form::Group.new(nil, [
          Form::Field.new("label_contains", I18n.t("perso_ui.rules.label_contains"), value: value.call("label_contains"), maxlength: 120),
          Form::Field.new("amount", I18n.t("perso_ui.rules.amount"), "number", value.call("amount"), mono: true),
          Form::Field.new("direction", I18n.t("perso_ui.rules.direction"), "select", value.call("direction"),
            options: code_options(Api::RULE_DIRECTIONS, "bankimport.directions")),
          Form::Field.new("category_id", I18n.t("perso_ui.operations.category"), "select", value.call("category_id"),
            options: category_options, required: true),
          Form::Field.new("payee", I18n.t("perso_ui.operations.payee"), value: value.call("payee"), maxlength: 120,
            help: I18n.t("perso_ui.rules.payee_help")),
          Form::Field.new("account_id", I18n.t("perso_ui.operations.account"), "select", value.call("account_id"),
            options: [option("", I18n.t("perso_ui.operations.all_accounts"))] + account_options(writable_only: false)),
          Form::Field.new("position", I18n.t("perso_ui.accounts.position"), "number", value.call("position"), mono: true),
          Form::Field.new("active", I18n.t("perso_ui.rules.active"), "checkbox", value.call("active")),
        ])])
      end

      def read_input(form : Form) : Api::RuleInput?
        amount = decimal_value(form, "amount")
        position = int_value(form, "position") || 100
        category = id_field("category_id")
        form.add_error("category_id", I18n.t("ui.forms.required")) if category.nil?
        return if form.invalid || category.nil?
        Api::RuleInput.new(category_id: category, label_contains: field("label_contains"), amount: amount,
          direction: field("direction").presence || "any", account_id: id_field("account_id"), position: position,
          active: checkbox("active"), payee: field("payee"))
      end

      private def render_list(form : Form, status : Int32 = 200) : Marten::HTTP::Response
        rows = Api.rules(actor).map do |rule|
          actions = [
            link_action("perso_ui.rules.edit", Ui.url("rule_edit", id: rule.id), "row", "pencil"),
            post_action("perso_ui.rules.delete", Ui.url("rule_delete", id: rule.id), "perso_ui.rules.confirm_delete", "row-danger", "trash-2"),
          ]
          Table::Row.new([
            Table::Cell.new(rule.label_contains), Table::Cell.new(rule.amount.try { |amount| fmt.amount(amount) } || ""),
            Table::Cell.new(I18n.t(rule.direction_key)), Table::Cell.new(rule.category_label), Table::Cell.new(rule.payee),
            Table::Cell.new(rule.learned ? I18n.t("perso_ui.rules.learned") : I18n.t("perso_ui.rules.typed")),
            Table::Cell.new(rule.hits.to_s), Table::Cell.new("", actions: actions),
          ])
        end
        table = Table.new(I18n.t("perso.menu.perso_rules"), [
          Table::Column.new("label", I18n.t("perso_ui.rules.label_contains")),
          Table::Column.new("amount", I18n.t("perso_ui.rules.amount"), "number"),
          Table::Column.new("direction", I18n.t("perso_ui.rules.direction"), secondary: true),
          Table::Column.new("category", I18n.t("perso_ui.operations.category")),
          Table::Column.new("payee", I18n.t("perso_ui.operations.payee"), secondary: true),
          Table::Column.new("origin", I18n.t("perso_ui.rules.origin"), secondary: true),
          Table::Column.new("hits", I18n.t("perso_ui.rules.hits"), "number", secondary: true),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], rows, Ui.url("rules"), empty_message: I18n.t("perso_ui.rules.none"), id: "perso-rules")
        set_form(form, Ui.url("rules"), I18n.t("perso_ui.rules.new"), title: I18n.t("perso_ui.rules.new"))
        list_page(I18n.t("perso.menu.perso_rules"), table, settings_crumbs({I18n.t("perso.menu.perso_rules"), nil}),
          "perso_ui.rules.csv_name", intro: I18n.t("perso_ui.rules.intro"), status: status)
      end
    end

    class RuleEditHandler < RulesHandler
      def get
        rule = Api.rules(actor).find(&.id.==(id_param)) || raise Partiduo::Api::NotFound.new("perso_rule", id_param)
        show(rule_form({"label_contains" => rule.label_contains, "amount" => rule.amount.try { |amount| fmt.input_number(amount) } || "",
                        "direction" => rule.direction, "category_id" => rule.category_id.to_s, "account_id" => rule.account_id.to_s,
                        "position" => rule.position.to_s, "active" => rule.active ? "1" : "", "payee" => rule.payee}))
      end

      def post
        form = rule_form(submitted(FIELDS))
        if input = read_input(form)
          result = Api.save_rule(actor, input, id_param)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.rule_saved")
            return go(Ui.url("rules"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("perso_ui.rules.edit")
        form_page(title, settings_crumbs({I18n.t("perso.menu.perso_rules"), Ui.url("rules")}, {title, nil}), form,
          Ui.url("rule_edit", id: id_param), I18n.t("ui.forms.save"), Ui.url("rules"))
      end
    end

    class RuleDeleteHandler < Handler
      def get
        go(Ui.url("rules"))
      end

      def post
        after(Api.delete_rule(actor, id_param), "perso_ui.flash.rule_deleted", Ui.url("rules"))
      end
    end

    # `/ext/PERSO/members` : les membres du foyer (D12) — prénom
    # d'affichage, rôle (adulte, mineur, conseiller en lecture seule),
    # comptes visibles.
    class MembersHandler < Handler
      def get
        render_list(member_form({"role" => "adult"}, true))
      end

      def post
        form = member_form(submitted(%w[user_id display_name role]), true)
        user = id_field("user_id")
        form.add_error("user_id", I18n.t("ui.forms.required")) if user.nil?
        if !form.invalid && user
          result = Api.save_member(actor, Api::MemberInput.new(user, field("display_name"), field("role").presence || "adult"))
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.member_saved")
            return go(Ui.url("members"))
          end
          form.add_errors(result.errors, fmt)
        end
        render_list(form, 422)
      end

      def member_form(values : Hash(String, String), creating : Bool) : Form
        value = ->(name : String) { values[name]? || "" }
        fields = [] of Form::Field
        if creating
          users = begin
            Api.candidate_users(actor).map { |user| option(user.id.to_s, "#{user.full_name} <#{user.email}>") }
          rescue Partiduo::Api::AccessDenied
            [] of Form::Option
          end
          fields << Form::Field.new("user_id", I18n.t("perso_ui.members.user"), "select", value.call("user_id"),
            options: [blank_option] + users, required: true, help: I18n.t("perso_ui.members.user_help"))
        end
        fields << Form::Field.new("display_name", I18n.t("perso_ui.members.display_name"), value: value.call("display_name"),
          required: true, maxlength: 80)
        fields << Form::Field.new("role", I18n.t("perso_ui.members.role"), "select", value.call("role"),
          options: code_options(Api::MEMBER_ROLES, "perso.member_roles"), help: I18n.t("perso_ui.members.role_help"))
        Form.new([Form::Group.new(nil, fields)])
      end

      private def render_list(form : Form, status : Int32 = 200) : Marten::HTTP::Response
        rows = Api.members(actor).map do |member|
          actions = [
            link_action("perso_ui.members.edit", Ui.url("member_edit", id: member.id), "row", "pencil"),
            link_action("perso_ui.members.accounts", Ui.url("member_accounts", id: member.id), "row", "file-text"),
            post_action("perso_ui.members.delete", Ui.url("member_delete", id: member.id), "perso_ui.members.confirm_delete", "row-danger", "trash-2"),
          ]
          Table::Row.new([Table::Cell.new(member.display_name), Table::Cell.new(member.email), Table::Cell.new(I18n.t(member.role_key)),
                          Table::Cell.new("", actions: actions)])
        end
        table = Table.new(I18n.t("perso.menu.perso_members"), [
          Table::Column.new("name", I18n.t("perso_ui.members.display_name")),
          Table::Column.new("email", I18n.t("perso_ui.members.email"), secondary: true),
          Table::Column.new("role", I18n.t("perso_ui.members.role")),
          Table::Column.new("actions", I18n.t("perso_ui.documents.actions"), "actions", sortable: false),
        ], rows, Ui.url("members"), empty_message: I18n.t("perso_ui.members.none"), id: "perso-members")
        set_form(form, Ui.url("members"), I18n.t("perso_ui.members.new"), title: I18n.t("perso_ui.members.new"))
        list_page(I18n.t("perso.menu.perso_members"), table, settings_crumbs({I18n.t("perso.menu.perso_members"), nil}),
          "perso_ui.members.csv_name", intro: I18n.t("perso_ui.members.intro"), status: status)
      end
    end

    class MemberEditHandler < MembersHandler
      def get
        member = find
        show(member, member_form({"display_name" => member.display_name, "role" => member.role}, false))
      end

      def post
        member = find
        form = member_form(submitted(%w[display_name role]), false)
        unless form.invalid
          result = Api.save_member(actor, Api::MemberInput.new(member.user_id, field("display_name"), field("role")), member.id)
          if result.success?
            flash["success"] = I18n.t("perso_ui.flash.member_saved")
            return go(Ui.url("members"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(member, form)
      end

      private def find : Api::MemberView
        Api.members(actor).find(&.id.==(id_param)) || raise Partiduo::Api::NotFound.new("perso_member", id_param)
      end

      private def show(member : Api::MemberView, form : Form) : Marten::HTTP::Response
        form_page(member.display_name, settings_crumbs({I18n.t("perso.menu.perso_members"), Ui.url("members")}, {member.display_name, nil}),
          form, Ui.url("member_edit", id: member.id), I18n.t("ui.forms.save"), Ui.url("members"))
      end
    end

    class MemberDeleteHandler < Handler
      def get
        go(Ui.url("members"))
      end

      def post
        after(Api.delete_member(actor, id_param), "perso_ui.flash.member_deleted", Ui.url("members"))
      end
    end

    # Comptes que voit un membre (D12) : droits par journal du socle.
    class MemberAccountsHandler < Handler
      def get
        member = Api.members(actor).find(&.id.==(id_param)) || raise Partiduo::Api::NotFound.new("perso_member", id_param)
        fields = accounts.map do |account|
          Form::Field.new("account_#{account.id}", account.label, "checkbox", "1")
        end
        form_page(I18n.t("perso_ui.members.accounts_title", name: member.display_name),
          settings_crumbs({I18n.t("perso.menu.perso_members"), Ui.url("members")}, {member.display_name, nil}),
          Form.new([Form::Group.new(nil, fields)]), Ui.url("member_accounts", id: id_param), I18n.t("ui.forms.save"),
          Ui.url("members"), intro: I18n.t("perso_ui.members.accounts_intro"))
      end

      def post
        chosen = accounts.select { |account| checkbox("account_#{account.id}") }.map(&.id)
        after(Api.set_member_accounts(actor, id_param, chosen), "perso_ui.flash.member_accounts_saved", Ui.url("members"))
      end
    end

    # `/ext/PERSO/settings` : paramètres du foyer — barème kilométrique de
    # l'année (D10), exports complets (D11).
    class SettingsHandler < Handler
      def get
        year = year_param
        chosen, rates = Api.mileage_rates(actor, year)
        fields = rates.map_with_index do |rate, index|
          label = I18n.t("perso_ui.settings.band", power: rate.fiscal_power, max: rate.max_km.try(&.to_s) || "∞")
          [Form::Field.new("power_#{index}", "", "hidden", rate.fiscal_power.to_s),
           Form::Field.new("max_#{index}", "", "hidden", rate.max_km.to_s),
           Form::Field.new("coefficient_#{index}", label, "number", fmt.input_number(rate.coefficient), mono: true),
           Form::Field.new("constant_#{index}", I18n.t("perso_ui.settings.constant"), "number", fmt.input_number(rate.constant), mono: true)]
        end.flatten
        fields << Form::Field.new("count", "", "hidden", rates.size.to_s)
        form_page(I18n.t("perso.menu.perso_settings"), settings_crumbs({I18n.t("perso.menu.perso_settings"), nil}),
          Form.new([Form::Group.new(I18n.t("perso_ui.settings.mileage", year: year), fields)]),
          Ui.url_with("settings", {"year" => year.to_s}), I18n.t("ui.forms.save"), nil,
          [link_action("perso_ui.operations.export_all", Ui.url("export", kind: "operations"), "", "download"),
           link_action("perso_ui.accounts.export", Ui.url("export", kind: "accounts"), "", "download"),
           link_action("perso_ui.wealth.export_valuations", Ui.url("export", kind: "valuations"), "", "download")],
          intro: I18n.t("perso_ui.settings.intro", year: year, chosen: chosen.to_s))
      end

      def post
        year = year_param
        count = field("count").to_i? || 0
        rates = (0...count).compact_map do |index|
          power = field("power_#{index}").to_i? || next
          coefficient = decimal_field("coefficient_#{index}") || next
          Api::MileageRateInput.new(year, power, coefficient, decimal_field("constant_#{index}") || BigDecimal.new(0),
            field("max_#{index}").to_i?)
        end
        after(Api.set_mileage_rates(actor, year, rates), "perso_ui.flash.mileage_saved", Ui.url_with("settings", {"year" => year.to_s}))
      end
    end
  end
end
