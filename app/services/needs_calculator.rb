require "csv"

# Colonnes utilisées dans l'export :
#   Type              -> Entrée (achat) / Sortie (vente)
#   Statuts           -> filtre : voir STATUTS ci-dessous
#   Date              -> date d'entrée (achat) ou de départ (vente)
#   CodeArticle       -> produit
#   Qté réceptionnée  -> quantité
#   Supprimer         -> si coché / rempli, la ligne est ignorée
class NeedsCalculator
  class Error < StandardError; end

  Line = Struct.new(:achats, :ventes, :solde, :cumul, keyword_init: true)

  ACHAT = /achat|reception|entree|entrant/
  VENTE = /vente|expedition|sortie|depart|sortant/
  FALSY = %w[false faux non no 0 unchecked].freeze

  # Statuts retenus (comparés sans accents ni majuscules)
  STATUTS = {
    achat: ["Commandé", "Confirmé"],
    vente: ["Commandé", "Confirmé", "Attribué", "A Préparer", "Prêt à être expédié"]
  }.transform_values { |list| list.map { |x| I18n.transliterate(x).downcase.strip } }.freeze

  attr_reader :warnings

  def initialize(raw)
    @data = normalize(raw)
    @warnings = []
  end
  # => { "Produit A" => [["2026-S40", Line], ...], ... }
  def call
    totals = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = { achats: 0.0, ventes: 0.0 } } }

    parse.each do |row|
      totals[row[:produit]][row[:semaine]][row[:type] == :achat ? :achats : :ventes] += row[:qte]
    end

    totals.sort.to_h.transform_values do |weeks|
      cumul = 0.0
      weeks.sort.map do |semaine, t|
        solde = t[:achats] - t[:ventes]
        cumul += solde
        [semaine, Line.new(achats: t[:achats], ventes: t[:ventes], solde: solde, cumul: cumul)]
      end
    end
  end

  def by_week
    per_product = call
    lookup = per_product.transform_values(&:to_h)
    semaines = lookup.values.flat_map(&:keys).uniq.sort
    cumuls = Hash.new(0.0)

    semaines.map do |semaine|
      lines = lookup.map do |produit, weeks|
        if (l = weeks[semaine])
          cumuls[produit] = l.cumul
          [produit, l]
        else
          [produit, Line.new(achats: 0.0, ventes: 0.0, solde: 0.0, cumul: cumuls[produit])]
        end
      end
      [semaine, lines]
    end
  end

  private

  def parse
    first = @data.lines.first.to_s
    sep = first.count(";") > first.count(",") ? ";" : ","
    table = CSV.parse(@data, headers: true, col_sep: sep, header_converters: ->(h) { key(h) })

    missing = { "type" => "Type", "statuts" => "Statuts", "date" => "Date", "codearticle" => "CodeArticle", "qte receptionnee" => "Qté réceptionnée" }
              .reject { |k, _| table.headers.include?(k) }.values
    raise Error, "Colonnes manquantes : #{missing.join(', ')}" if missing.any?

    rows = []
    table.each_with_index do |r, i|
      next if r.fields.all?(&:blank?)
      next if deleted?(r["supprimer"])

      label = key(r["type"])
      type = if label.match?(ACHAT) then :achat
             elsif label.match?(VENTE) then :vente
             else raise Error, "Ligne #{i + 2} : type non reconnu (« #{r['type']} »)"
             end

      next unless STATUTS[type].include?(key(r["statuts"]))
      if r["date"].to_s.strip.empty?
        @warnings << "Ligne #{i + 2} : date vide, ligne ignorée (#{r['type']}, #{r['statuts']}, #{r['codearticle']}, qté #{r['qte receptionnee']})"
        next
      end
      date = begin
        Date.parse(r["date"].to_s)
      rescue ArgumentError
        raise Error, "Ligne #{i + 2} : date invalide (« #{r['date']} »)"
      end

      rows << {
        type: type,
        produit: r["codearticle"].to_s.strip.presence || "(sans code article)",
        semaine: format("%d-S%02d", date.cwyear, date.cweek),
        qte: r["qte receptionnee"].to_s.gsub(/[[:space:]]/, "").tr(",", ".").to_f
      }
    end
    rows
  rescue CSV::MalformedCSVError => e
    raise Error, "CSV illisible : #{e.message}"
  end

  def deleted?(value)
    v = value.to_s.strip.downcase
    v.present? && !FALSY.include?(v)
  end

  # minuscules, sans accents, espaces normalisés
  def key(text)
    I18n.transliterate(text.to_s).downcase.strip.gsub(/\s+/, " ")
  end

  def normalize(raw)
    s = raw.dup.force_encoding("UTF-8")
    s = raw.dup.force_encoding("ISO-8859-1").encode("UTF-8") unless s.valid_encoding?
    s.sub(/\A\uFEFF/, "")
  end
end
