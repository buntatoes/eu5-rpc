# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "json"
require_relative "logger"

module Eu5Rpc
  # Parses EU5 save metadata from continue_game.json and .eu5 save headers/filenames
  # without ever modifying saves or reading game memory.
  module SaveInspector
    SaveMetadata = Struct.new(:country_name, :country_tag, :year, :date_str, :multiplayer, :game_version, keyword_init: true)

    # Example filename: SP_POR_1382_01_11_<uuid>.eu5 or MP_FRA_1453_05_29_<uuid>.eu5
    FILENAME_RE = /\A(SP|MP)_([A-Z0-9]{2,4})_(\d{3,4})_(\d{2})_(\d{2})_/i.freeze
    # Header display string embedded in EU5 save header: "1382.1.11 - Portugal"
    HEADER_DATE_COUNTRY_RE = /(\d{3,4}\.\d{1,2}\.\d{1,2})\s+-\s+([^\x00-\x1f\r\n]{2,64})/.freeze
    HEADER_TAG_RE = /\b([A-Z0-9]{3})=\{/.freeze
    HEADER_VERSION_RE = /\b(\d{1,2}\.\d{1,2}\.\d{1,2})\b/.freeze

    module_function

    def inspect_user_data_dir(user_data_dir)
      return nil unless user_data_dir && File.directory?(user_data_dir)

      version = nil
      continue_path = File.join(user_data_dir, "continue_game.json")
      if File.exist?(continue_path)
        begin
          cj = JSON.parse(File.read(continue_path, encoding: "UTF-8"))
          version = cj["rawGameVersion"].to_s.strip
          version = nil if version.empty?
        rescue StandardError
          # Ignore malformed JSON
        end
      end

      saves_dir = File.join(user_data_dir, "save games")
      newest_save = find_newest_save(saves_dir)
      return version ? SaveMetadata.new(game_version: version) : nil unless newest_save

      meta = parse_save_file(newest_save)
      meta.game_version ||= version
      meta
    end

    def find_newest_save(saves_dir)
      return nil unless File.directory?(saves_dir)

      Dir.glob(File.join(saves_dir, "*.eu5"))
         .select { |p| File.file?(p) }
         .max_by { |p| File.mtime(p) }
    rescue StandardError
      nil
    end

    def parse_save_file(path)
      meta = parse_filename(File.basename(path))
      header = File.binread(path, 2048) rescue ""
      merge_header!(meta, header)
      meta
    end

    def parse_filename(basename)
      meta = SaveMetadata.new
      if (m = FILENAME_RE.match(basename.to_s))
        meta.multiplayer = (m[1].upcase == "MP")
        meta.country_tag = m[2].upcase
        meta.year = m[3].to_i
        meta.date_str = "#{m[3]}.#{m[4].to_i}.#{m[5].to_i}"
      end
      meta
    end

    def merge_header!(meta, raw_bytes)
      text = raw_bytes.to_s.encode("UTF-8", "binary", invalid: :replace, undef: :replace, replace: "\x00")

      if (m = HEADER_DATE_COUNTRY_RE.match(text))
        meta.date_str = m[1]
        meta.year = m[1].split(".").first.to_i
        country = m[2].strip.sub(/\s+#[0-9a-f]+\z/i, "").strip
        meta.country_name = country unless country.empty?
      end

      if meta.country_tag.nil? && (m = HEADER_TAG_RE.match(text))
        meta.country_tag = m[1]
      end

      if meta.game_version.nil? && (m = HEADER_VERSION_RE.match(text))
        meta.game_version = m[1]
      end

      meta
    end
  end
end
