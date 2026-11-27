# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "logger"

module Eu5Rpc
  # Resolves 3-letter EU5 country tags (e.g. "POR", "FRA", "BYZ") to official English country names.
  # Automatically loads all ~2,350+ countries from the user's local EU5 installation's
  # localization files (country_names_l_english.yml + formable_countries_l_english.yml) at runtime,
  # with a compact built-in fallback table for common starting tags if the install folder is not found.
  class CountryLookup
    LOC_ENTRY_RE = /^\s+([A-Z0-9_]{2,24}):\d*\s+"([^"]+)"/.freeze

    FALLBACK_TAGS = {
      "ARA" => "Aragon",
      "AUS" => "Austria",
      "AZT" => "Aztec",
      "BAV" => "Bavaria",
      "BOH" => "Bohemia",
      "BRA" => "Brandenburg",
      "BRB" => "Brabant",
      "BUL" => "Bulgaria",
      "BUR" => "Burgundy",
      "BYZ" => "Byzantium",
      "CAS" => "Castile",
      "DAN" => "Denmark",
      "DLH" => "Delhi",
      "ENG" => "England",
      "ETH" => "Ethiopia",
      "FLA" => "Flanders",
      "FLO" => "Florence",
      "FRA" => "France",
      "GEN" => "Genoa",
      "GRA" => "Granada",
      "HAB" => "Austria",
      "HOL" => "Holland",
      "HUN" => "Hungary",
      "INC" => "Inca",
      "IRE" => "Ireland",
      "JAP" => "Japan",
      "KIL" => "Kilwa",
      "KOR" => "Goryeo",
      "LIT" => "Lithuania",
      "MAM" => "Mamluks",
      "MLI" => "Mali",
      "MLO" => "Milan",
      "MNG" => "Ming",
      "MOS" => "Muscovy",
      "NAP" => "Naples",
      "NAV" => "Navarre",
      "NOR" => "Norway",
      "NOV" => "Novgorod",
      "PAP" => "Papal States",
      "POL" => "Poland",
      "POR" => "Portugal",
      "PRU" => "Prussia",
      "RUS" => "Russia",
      "SAV" => "Savoy",
      "SAX" => "Saxony",
      "SCO" => "Scotland",
      "SER" => "Serbia",
      "SPA" => "Spain",
      "SWE" => "Sweden",
      "TEU" => "Teutonic Order",
      "TUR" => "Ottomans",
      "VEN" => "Venice",
      "VIJ" => "Vijayanagar",
      "YUA" => "Yuan"
    }.freeze

    def initialize(game_install_dir = nil)
      @map = FALLBACK_TAGS.dup
      load_from_game_dir(game_install_dir) if game_install_dir
    end

    def size
      @map.size
    end

    def resolve(tag)
      key = tag.to_s.strip.upcase
      return nil if key.empty? || key == "NO" || key == "NONE"

      @map[key] || key
    end

    def load_from_game_dir(game_dir)
      loc_dir = File.join(game_dir.to_s.tr("\\", "/"), "game", "main_menu", "localization", "english")
      return 0 unless File.directory?(loc_dir)

      loaded = 0
      %w[country_names_l_english.yml formable_countries_l_english.yml].each do |fname|
        path = File.join(loc_dir, fname)
        next unless File.file?(path)

        loaded += load_localization_file(path)
      end

      RpcLogger.info("[eu5] Loaded #{loaded} localized country names from EU5 install") if loaded.positive?
      loaded
    rescue StandardError => e
      RpcLogger.debug("[eu5] Failed loading country names: #{e.message}")
      0
    end

    def load_localization_file(path)
      count = 0
      File.foreach(path, encoding: "UTF-8:UTF-8") do |line|
        next unless (m = LOC_ENTRY_RE.match(line))

        tag = m[1].upcase
        name = m[2].strip
        next if name.empty? || name.include?("$")

        @map[tag] = name
        count += 1
      end
      count
    rescue StandardError
      0
    end
  end
end
