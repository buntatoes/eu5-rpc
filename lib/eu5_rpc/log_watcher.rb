# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "game_state"
require_relative "save_inspector"
require_relative "logger"

module Eu5Rpc
  # Watches EU5's live log files (logs/debug.log, logs/game.log, logs/multiplayer.log)
  # and newest save header to maintain accurate live campaign state.
  class LogWatcher
    RESYNC_BYTES = 2 * 1024 * 1024

    TRANSITION_RE    = /Running Transition\s+(\w+)->(\w+)/.freeze
    GAME_VERSION_RE  = /game version\s+(\d+\.\d+\.\d+)/i.freeze
    NEW_YEAR_RE      = /NEW YEAR:\s+(\d{3,4})/.freeze
    WAR_RE           = /WAR:\s+(.+?)\s+declared war on\s+(.+)/.freeze
    CIVIL_WAR_RE     = /CIVIL WAR:\s+(.+?)\s+against\s+(.+)/.freeze
    EXPLORATION_RE   = /EXPLORATION:\s+(.+?)\s+discovered\s+.*?L;\s*([^!]+?)!/.freeze
    DISASTER_RE      = /DISASTER:\s+(\w+)\s+(starts|ends)\s+in\s+([A-Z0-9]{2,4})/i.freeze
    IS_MP_RE         = /Is Multiplayer:\s+(true|false)/i.freeze
    IS_MP_HOST_RE    = /Is Multiplayer Host:\s+(true|false)/i.freeze
    IS_OBSERVER_RE   = /_Player Is Observer:\s+(true|false)/i.freeze

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

    def self.process_multiplayer_line(line, state)
      if (m = IS_MP_RE.match(line))
        state.multiplayer = (m[1].downcase == "true")
      elsif (m = IS_MP_HOST_RE.match(line))
        state.multiplayer_host = (m[1].downcase == "true")
      elsif (m = IS_OBSERVER_RE.match(line))
        state.observer = (m[1].downcase == "true")
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

    def initialize(user_data_dir, poll_interval_ms)
      @user_data_dir = user_data_dir
      @poll_interval_s = [poll_interval_ms.to_f / 1000.0, 0.25].max
      @offsets = {}
      @last_save_mtime = nil
    end

    def run(state, mutex)
      logs_dir = File.join(@user_data_dir, "logs")
      debug_log = File.join(logs_dir, "debug.log")
      game_log  = File.join(logs_dir, "game.log")
      mp_log    = File.join(logs_dir, "multiplayer.log")

      loop do
        refresh_save_metadata(state, mutex)
        tail_log(debug_log, state, mutex) { |line, gs| self.class.process_debug_line(line, gs) }
        tail_log(mp_log, state, mutex)    { |line, gs| self.class.process_multiplayer_line(line, gs) }
        tail_log(game_log, state, mutex)  { |line, gs| self.class.process_game_line(line, gs) }
        sleep(@poll_interval_s)
      end
    end

    private

    def refresh_save_metadata(state, mutex)
      saves_dir = File.join(@user_data_dir, "save games")
      newest = SaveInspector.find_newest_save(saves_dir)
      mtime = newest ? (File.mtime(newest) rescue nil) : nil
      return if mtime && @last_save_mtime == mtime

      meta = SaveInspector.inspect_user_data_dir(@user_data_dir)
      return unless meta

      @last_save_mtime = mtime
      mutex.synchronize do
        state.country_name = meta.country_name if meta.country_name && !meta.country_name.empty?
        state.country_tag  = meta.country_tag  if meta.country_tag  && !meta.country_tag.empty?
        if meta.year && (state.year.nil? || meta.year >= state.year)
          state.year = meta.year
          state.date_str = meta.date_str
        end
        state.game_version = meta.game_version if meta.game_version && !meta.game_version.empty?
        state.multiplayer  = meta.multiplayer unless meta.multiplayer.nil?
      end
    rescue StandardError => e
      RpcLogger.debug("[saves] Metadata check error: #{e.message}")
    end

    def tail_log(path, state, mutex)
      return unless File.exist?(path)

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
