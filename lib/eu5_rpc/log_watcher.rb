# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "json"
require_relative "game_state"
require_relative "country_lookup"
require_relative "save_inspector"
require_relative "process_watcher"
require_relative "steam"
require_relative "logger"

module Eu5Rpc
  # Watches EU5's live log files (logs/debug.log, logs/game.log, logs/multiplayer.log)
  # and newest save header to maintain accurate live campaign state and country selection.
  class LogWatcher
    RESYNC_BYTES = 2 * 1024 * 1024

    TRANSITION_RE       = /Running Transition\s+(\w+)->(\w+)/.freeze
    GAME_VERSION_RE     = /game version\s+(\d{1,2}\.\d{1,2}\.\d{1,2})/i.freeze
    NEW_YEAR_RE         = /NEW YEAR:\s+(\d{3,4})/.freeze
    SITUATION_DATE_RE   = /SITUATION:.*?\s+starts on\s+(\d{1,2}\s+[A-Za-z]+,\s+(\d{3,4}))/i.freeze
    WAR_RE              = /WAR:\s+(.+?)\s+declared war on\s+(.+)/.freeze
    CIVIL_WAR_RE        = /CIVIL WAR:\s+(.+?)\s+against\s+(.+)/.freeze
    EXPLORATION_RE      = /EXPLORATION:\s+(.+?)\s+discovered\s+.*?L;\s*([^!]+?)!/.freeze
    DISASTER_RE         = /DISASTER:\s+(\w+)\s+(starts|ends)\s+in\s+([A-Z0-9]{2,5})/i.freeze
    IS_MP_RE            = /Is Multiplayer:\s+(true|false)/i.freeze
    IS_MP_HOST_RE       = /Is Multiplayer Host:\s+(true|false)/i.freeze
    IS_OBSERVER_RE      = /_Player Is Observer:\s+(true|false)/i.freeze
    NEW_COUNTRY_RE      = /\A\s*New Country:\s+([A-Za-z0-9_]+)\s*\z/.freeze
    DESTROY_GAMESTATE_RE = /Destroying gamestate/.freeze

    def self.process_debug_line(line, state)
      if (m = GAME_VERSION_RE.match(line))
        state.game_version = m[1]
      end

      if (m = TRANSITION_RE.match(line))
        target = m[2]
        case target
        when "SplashScreen", "LoadingScreen"
          state.enter_loading
        when "MainMenu"
          state.enter_main_menu
        when "Game"
          state.enter_game
        when "Empty"
          state.reset
        end
      end
    end

    def self.process_multiplayer_line(line, state, country_lookup = nil)
      if (m = IS_MP_RE.match(line))
        state.multiplayer = (m[1].downcase == "true")
      elsif (m = IS_MP_HOST_RE.match(line))
        state.multiplayer_host = (m[1].downcase == "true")
      elsif (m = IS_OBSERVER_RE.match(line))
        state.observer = (m[1].downcase == "true")
      elsif (m = NEW_COUNTRY_RE.match(line))
        raw_tag = m[1].strip
        if raw_tag.casecmp("No").zero? || raw_tag.casecmp("None").zero?
          state.country_tag = nil
          state.country_name = nil
        else
          tag = raw_tag.upcase
          state.country_tag = tag
          resolved = country_lookup ? country_lookup.resolve(tag) : CountryLookup::FALLBACK_TAGS[tag]
          state.country_name = resolved || tag
          state.active_event = nil
          state.enter_game if state.phase != GamePhase::IN_GAME
        end
      elsif DESTROY_GAMESTATE_RE.match?(line)
        state.active_event = nil
      end
    end

    def self.process_game_line(line, state)
      if (m = NEW_YEAR_RE.match(line))
        y = m[1].to_i
        if y >= 1337
          state.year = y
          state.date_str = y.to_s
        end
        return
      end

      if (m = SITUATION_DATE_RE.match(line))
        y = m[2].to_i
        if y >= 1337 && (state.year.nil? || y >= state.year)
          state.year = y
          state.date_str = m[1]
        end
        return
      end

      country = state.country_name
      tag = state.country_tag

      if country && !country.empty?
        if (m = WAR_RE.match(line))
          attacker = m[1].strip
          defender = m[2].strip
          if attacker.casecmp(country).zero?
            state.active_event = "At War with #{defender}"
          elsif defender.casecmp(country).zero?
            state.active_event = "Defending vs. #{attacker}"
          end
        elsif (m = CIVIL_WAR_RE.match(line))
          target = m[2].strip
          state.active_event = "In a Civil War" if target.casecmp(country).zero?
        elsif (m = EXPLORATION_RE.match(line))
          explorer = m[1].strip
          area = m[2].strip
          if explorer.casecmp(country).zero? && !area.empty?
            state.active_event = "Explored #{area}"
          end
        end
      end

      if tag && !tag.empty? && (m = DISASTER_RE.match(line))
        disaster_name = m[1].tr("_", " ").split.map(&:capitalize).join(" ")
        action = m[2].downcase
        affected_tag = m[3].upcase
        if affected_tag == tag.upcase
          state.active_event = (action == "starts") ? "Disaster: #{disaster_name}" : nil
        end
      end
    end

    def initialize(user_data_dir, poll_interval_ms, country_lookup = nil, steam_rp = nil, configured_user_data_dir = nil)
      @user_data_dir = user_data_dir.to_s.tr("\\", "/")
      @configured_user_data_dir = configured_user_data_dir
      @poll_interval_s = [poll_interval_ms.to_f / 1000.0, 0.25].max
      @country_lookup = country_lookup || CountryLookup.new
      @steam_rp = steam_rp
      @offsets = {}
      @last_save_key = nil
      @session_started_at = Time.now.to_f
    end

    def run(state, mutex)
      seed_initial_log_offsets(@user_data_dir)

      loop do
        ensure_user_data_dir!

        logs_dir  = File.join(@user_data_dir, "logs")
        debug_log = File.join(logs_dir, "debug.log")
        game_log  = File.join(logs_dir, "game.log")
        mp_log    = File.join(logs_dir, "multiplayer.log")

        if ProcessWatcher.eu5_running?
          steam_rp_data = @steam_rp&.poll
          if steam_rp_data
            mutex.synchronize { state.apply_steam_rich_presence(steam_rp_data) }
          end

          tail_log(debug_log, state, mutex) { |line, gs| self.class.process_debug_line(line, gs) }
          tail_log(mp_log, state, mutex)    { |line, gs| self.class.process_multiplayer_line(line, gs, @country_lookup) }
          tail_log(game_log, state, mutex)  { |line, gs| self.class.process_game_line(line, gs) }
          refresh_save_metadata(state, mutex, skip_country: !!(steam_rp_data && steam_rp_data[:country]))
        else
          @steam_rp&.disconnect
        end
        sleep(@poll_interval_s)
      end
    end

    private

    def seed_initial_log_offsets(dir)
      # If EU5 is already running when eu5-rpc starts, read the live session's logs;
      # otherwise skip stale log contents written by previous sessions.
      return if ProcessWatcher.eu5_running?

      logs_dir = File.join(dir, "logs")
      %w[debug.log game.log multiplayer.log].each do |fname|
        p = File.join(logs_dir, fname)
        if File.file?(p) && File.mtime(p).to_f < (@session_started_at - 3.0)
          @offsets[p] = File.size(p) rescue 0
        end
      end
    end

    def ensure_user_data_dir!
      return if File.directory?(File.join(@user_data_dir, "logs"))

      detected = Steam.find_existing_user_data_dir(@configured_user_data_dir)
      return unless detected && detected != @user_data_dir

      @user_data_dir = detected
      @offsets.clear
      @last_save_key = nil
      RpcLogger.info("[eu5] Switched to detected Paradox user data folder: #{@user_data_dir}")
    end

    def refresh_save_metadata(state, mutex, skip_country: false)
      continue_path = File.join(@user_data_dir, "continue_game.json")
      if state.game_version.nil? && File.file?(continue_path)
        begin
          cj = JSON.parse(File.read(continue_path, encoding: "UTF-8"))
          v = cj["rawGameVersion"].to_s.strip
          mutex.synchronize { state.game_version ||= v } unless v.empty?
        rescue StandardError
          # Ignore malformed JSON
        end
      end

      return if skip_country

      saves_dir = File.join(@user_data_dir, "save games")
      newest = SaveInspector.find_newest_save(saves_dir)
      save_mtime = newest ? (File.mtime(newest).to_f rescue nil) : nil
      cont_mtime = File.file?(continue_path) ? (File.mtime(continue_path).to_f rescue nil) : nil

      # Only read saves written or updated during the CURRENT session so old saves from
      # prior days/campaigns never overwrite a newly selected country.
      active_mtime = [save_mtime, cont_mtime].compact.max
      return if active_mtime.nil? || active_mtime < (@session_started_at - 5.0)

      current_key = [newest, save_mtime, cont_mtime]
      return if @last_save_key == current_key

      meta = SaveInspector.inspect_user_data_dir(@user_data_dir)
      return unless meta

      @last_save_key = current_key
      mutex.synchronize do
        state.country_tag = meta.country_tag if meta.country_tag && !meta.country_tag.empty?
        if meta.country_name && !meta.country_name.empty?
          state.country_name = meta.country_name
        elsif state.country_tag
          state.country_name = @country_lookup.resolve(state.country_tag)
        end

        if meta.year && (state.year.nil? || meta.year >= state.year)
          state.year = meta.year
          state.date_str = meta.date_str
        end
        state.game_version = meta.game_version if meta.game_version && !meta.game_version.empty?
      end
    rescue StandardError => e
      RpcLogger.debug("[saves] Metadata check error: #{e.message}")
    end

    def tail_log(path, state, mutex)
      return unless File.file?(path)

      size = File.size(path) rescue 0
      prev = @offsets[path]

      if prev.nil?
        start_offset = [size - RESYNC_BYTES, 0].max
        lines = read_lines_from(path, start_offset, start_offset.positive?)
        mutex.synchronize { lines.each { |line| yield(line, state) } }
        @offsets[path] = size
      elsif size < prev
        lines = read_lines_from(path, 0, false)
        mutex.synchronize { lines.each { |line| yield(line, state) } }
        @offsets[path] = size
      elsif size > prev
        lines = read_lines_from(path, prev, false)
        mutex.synchronize { lines.each { |line| yield(line, state) } }
        @offsets[path] = size
      end
    rescue StandardError => e
      RpcLogger.debug("[watcher] Error tailing #{File.basename(path)}: #{e.message}")
    end

    def read_lines_from(path, offset, skip_partial)
      File.open(path, "rb") do |f|
        f.seek(offset, IO::SEEK_SET)
        raw = f.read.to_s
        text = raw.encode("UTF-8", invalid: :replace, undef: :replace)
        lines = text.lines.map(&:chomp)
        lines.shift if skip_partial && !lines.empty?
        lines
      end
    rescue StandardError
      []
    end
  end
end
