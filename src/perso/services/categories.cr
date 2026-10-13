# SPDX-License-Identifier: AGPL-3.0-or-later

module Perso
  # Catégories de recettes et de dépenses (D3, D-PER-005) : chacune est un
  # compte des classes 6 et 7 créé par `Partiduo::Api::Accounting
  # .create_account` ; l'utilisateur n'en voit que le libellé. Interne.
  module Categories
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError

    # Étiquettes fiscales posées d'office sur les catégories du plan réduit
    # (numéros communs aux plans `fr` et `be` du foyer).
    DEFAULT_TAGS = {"601" => "donation", "602" => "home_employment", "703" => "rental_income"}

    # Racine des comptes d'une catégorie selon son sens.
    ROOTS = {"expense" => "6", "income" => "7"}

    # Suffixe des numéros des catégories de premier niveau créées par le
    # foyer (`6P01`, `7P01`) : les numéros à deux chiffres du plan réduit
    # sont tous pris, et un numéro qui n'est le préfixe d'aucun autre garde
    # juste la formule du réel d'un budget (D-PER-005).
    TOP_PREFIX = "P"

    MAX_LABEL = 120

    # Reprend les comptes des classes 6 et 7 du plan comme catégories (deux
    # niveaux), sans toucher à celles qui existent : données initiales d'un
    # dossier foyer, ou reprise après l'activation de l'extension. Rend le
    # nombre de catégories créées.
    def self.load_defaults(actor : Partiduo::Api::Actor) : Int32
      created = 0
      ROOTS.each do |kind, root|
        lines = begin
          Acc.chart(actor, root)
        rescue Partiduo::Api::NotFound
          next
        end
        by_number = {} of String => Category
        Category.filter(kind: kind).each { |row| by_number[row.account.to_s] = row }
        lines.each do |line|
          next if line.depth == 0
          number = line.account.number
          next if by_number.has_key?(number)
          parent = line.account.parent_number.try { |parent_number| by_number[parent_number]? }
          next if line.depth > 1 && parent.nil?
          parent = nil if parent.try(&.parent_id)
          row = Category.new(account: number, label: line.account.label[0, MAX_LABEL], kind: kind,
            parent_id: parent.try(&.id), tax_tag: DEFAULT_TAGS[number]? || "", position: 100, active: true)
          row.save!
          by_number[number] = row
          created += 1
        end
      end
      created
    end

    # --- Vues ----------------------------------------------------------------------

    def self.views(include_inactive : Bool = true) : Array(Api::CategoryView)
      rows = Category.all.to_a
      by_id = rows.index_by(&.id!.to_i64)
      children = rows.group_by(&.parent_id.try(&.to_i64))
      ordered = [] of Api::CategoryView
      Api::CATEGORY_KINDS.each do |kind|
        tops = (children[nil]? || [] of Category).select(&.kind.==(kind)).sort_by! { |row| {row.position!, row.label.to_s.downcase} }
        tops.each do |top|
          next if !include_inactive && !top.active
          ordered << view(top, nil, children)
          (children[top.id!.to_i64]? || [] of Category).sort_by { |row| {row.position!, row.label.to_s.downcase} }.each do |child|
            next if !include_inactive && !child.active
            ordered << view(child, by_id[child.parent_id!.to_i64]?, children)
          end
        end
      end
      ordered
    end

    def self.view(row : Category, parent : Category? = nil, children = nil) : Api::CategoryView
      parent ||= row.parent_id.try { |id| Category.filter(id: id).first }
      count = children ? (children[row.id!.to_i64]?.try(&.size) || 0) : Category.filter(parent_id: row.id).count.to_i32
      Api::CategoryView.new(
        id: row.id!.to_i64, label: row.label.to_s, kind: row.kind.to_s, parent_id: parent.try(&.id!.to_i64),
        parent_label: parent.try(&.label.to_s), tax_tag: row.tax_tag.to_s, position: row.position!.to_i32,
        active: row.active!, depth: parent ? 1 : 0, children_count: count.to_i32)
    end

    # Libellés complets (« Logement › Énergie ») par numéro de compte.
    def self.labels_by_account : Hash(String, {Int64, String})
      rows = Category.all.to_a
      by_id = rows.index_by(&.id!.to_i64)
      rows.to_h do |row|
        parent = row.parent_id.try { |id| by_id[id.to_i64]? }
        label = parent ? "#{parent.label} › #{row.label}" : row.label.to_s
        {row.account.to_s, {row.id!.to_i64, label}}
      end
    end

    # --- Contrôles --------------------------------------------------------------------

    def self.errors(input : Api::CategoryInput, current : Category? = nil) : Array(FieldError)
      errors = [] of FieldError
      label_errors(input.label.strip, errors)
      errors << Records.error("kind", "category.kind.invalid") unless Api::CATEGORY_KINDS.includes?(input.kind)
      unless input.tax_tag.empty? || Api::TAX_TAGS.includes?(input.tax_tag)
        errors << Records.error("tax_tag", "category.tax_tag.invalid")
      end
      errors << Records.error("kind", "category.kind.locked") if current && current.kind != input.kind
      input.parent_id.try { |parent_id| parent_errors(parent_id, input.kind, current, errors) }
      errors
    end

    # Catégorie où ranger une opération du sens `kind` : active, de ce sens,
    # sans sous-catégorie ; rend la clé d'erreur, ou `nil`.
    def self.posting_error(row : Category?, kind : String) : String?
      if row.nil? || !row.active
        "operation.category.invalid"
      elsif row.kind != kind
        "operation.category.kind"
      elsif Category.filter(parent_id: row.id).exists?
        "operation.category.has_children"
      end
    end

    private def self.label_errors(label : String, errors : Array(FieldError)) : Nil
      if label.empty?
        errors << Records.error("label", "category.label.blank")
      elsif label.size > MAX_LABEL
        errors << Records.error("label", "category.label.too_long", {"max" => MAX_LABEL.to_s})
      end
    end

    # Parent : une catégorie de premier niveau, du même sens, qui n'est ni
    # la catégorie elle-même ni le parent d'une autre.
    private def self.parent_errors(parent_id : Int64, kind : String, current : Category?, errors : Array(FieldError)) : Nil
      parent = Category.filter(id: parent_id).first
      key = if parent.nil?
              "category.parent.invalid"
            elsif parent.parent_id
              "category.parent.depth"
            elsif parent.kind != kind
              "category.parent.kind"
            elsif current && (parent.id == current.id || Category.filter(parent_id: current.id).exists?)
              "category.parent.depth"
            end
      errors << Records.error("parent_id", key) if key
    end

    # --- Commandes --------------------------------------------------------------------

    # Crée le compte de la catégorie puis la catégorie. Numéro : sous le
    # compte du parent (deux chiffres de plus, premier libre), ou
    # `6P01`, `7P01`… au premier niveau (D-PER-005).
    def self.create(actor : Partiduo::Api::Actor, input : Api::CategoryInput) : {Category?, Array(FieldError)}
      parent = input.parent_id.try { |id| Records.category!(id) }
      number = next_number(input.kind, parent)
      account_kind = input.kind == "expense" ? Acc::AccountKind::Expense : Acc::AccountKind::Income
      parent_account = parent.try(&.account.to_s) || ROOTS[input.kind]
      result = Acc.create_account(actor, Acc::AccountInput.new(number: number, label: input.label.strip,
        parent: parent_account, kind: account_kind, direct_use: true))
      return {nil, result.errors.map { |error| FieldError.new(error.field == "number" ? "label" : error.field, error.key, error.params) }} if result.failure?
      row = Category.new(account: number, label: input.label.strip, kind: input.kind, parent_id: parent.try(&.id),
        tax_tag: input.tax_tag, position: input.position, active: input.active)
      row.save!
      {row, [] of FieldError}
    end

    # Libellé tenu des deux côtés : la catégorie et son compte (D-PER-005).
    def self.update(actor : Partiduo::Api::Actor, row : Category, input : Api::CategoryInput) : Array(FieldError)
      label = input.label.strip
      if label != row.label
        account = Acc.account(actor, row.account.to_s)
        result = Acc.update_account(actor, account.id, Acc::AccountInput.new(number: account.number, label: label,
          parent: account.parent_number, kind: account.kind, direct_use: account.direct_use))
        return result.errors if result.failure?
      end
      row.label = label
      row.tax_tag = input.tax_tag
      row.position = input.position
      row.active = input.active
      row.save!
      [] of FieldError
    end

    # Supprime une catégorie jamais employée (compte sans écriture, ni
    # budget, ni récurrence, ni enfant) avec son compte ; sinon elle se
    # retire des listes (`active` faux).
    def self.delete(actor : Partiduo::Api::Actor, row : Category) : Array(FieldError)
      id = row.id!.to_i64
      if Category.filter(parent_id: id).exists?
        return [Records.error(Partiduo::Api::FieldError::BASE, "category.has_children")]
      end
      if BudgetLine.filter(category_id: id).exists? || Recurring.filter(category_id: id).exists? ||
         Loan.filter(interest_category_id: id).exists? || Loan.filter(insurance_category_id: id).exists?
        return [Records.error(Partiduo::Api::FieldError::BASE, "category.in_use")]
      end
      account = Acc.account(actor, row.account.to_s)
      result = Acc.delete_account(actor, account.id)
      return [Records.error(Partiduo::Api::FieldError::BASE, "category.in_use")] if result.failure?
      row.delete
      [] of FieldError
    end

    private def self.next_number(kind : String, parent : Category?) : String
      base = parent ? parent.account.to_s : "#{ROOTS[kind]}#{TOP_PREFIX}"
      (1..99).each do |index|
        number = "#{base}#{index.to_s.rjust(2, '0')}"
        next if Category.filter(account: number).exists?
        next if account_exists?(number)
        return number
      end
      "#{base}#{Random::Secure.hex(3).upcase}"
    end

    private def self.account_exists?(number : String) : Bool
      Acc.account(Records.system, number)
      true
    rescue Partiduo::Api::NotFound
      false
    end
  end
end
