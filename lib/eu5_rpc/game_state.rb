# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "config"

module Eu5Rpc
  module GamePhase
    NOT_RUNNING = :not_running
    LOADING     = :loading
    MAIN_MENU   = :main_menu
    IN_GAME     = :in_game
  end

  module HistoricalAge
    # Europa Universalis V spans six historical Ages beginning in 1337.
    AGES = [
      [1337..1436, "Age of Traditions"],
      [1437..1536, "Age of Renaissance"],
      [1537..1636, "Age of Discovery"],
      [1637..1736, "Age of Reformation"],
      [1737..1836, "Age of Absolutism"],
      [1837..9999, "Age of Revolutions"]
    ].freeze

    module_function

    def for_year(year)
      y = year.to_i
      return nil if y < 1337

      entry = AGES.find { |range, _| range.include?(y) }
      entry ? entry[1] : nil
    end
  end

  class GameState
    attr_accessor :phase, :country_name, :country_tag, :year, :date_str,
                  :game_version, :multiplayer, :multiplayer_host, :observer,
                  :active_event

    def initialize
      reset
    end

    def reset
      @phase = GamePhase::NOT_RUNNING
      @country_name = nil
      @country_tag = nil
      @year = nil
      @date_str = nil
      @game_version = nil
      @multiplayer = false
      @multiplayer_host = false
      @observer = false
      @active_event = nil
      self
    end

    def enter_loading
      @phase = GamePhase::LOADING
      @active_event = nil
    end

    def enter_main_menu
      @phase = GamePhase::MAIN_MENU
      @active_event = nil
    end

    def enter_game
      @phase = GamePhase::IN_GAME
    end

    def mode_label
      if @observer
        @multiplayer ? "Multiplayer Observer" : "Observer"
      elsif @multiplayer
        @multiplayer_host ? "Multiplayer (Host)" : "Multiplayer"
      else
        "Singleplayer"
      end
    end

    def historical_age
      @year ? HistoricalAge.for_year(@year) : nil
    end

    def format_presence(pres_cfg)
      status_cfg = pres_cfg.status
      year_label = @year ? @year.to_s : "1337"
      age_label = historical_age.to_s

      case @phase
      when GamePhase::NOT_RUNNING
        [status_cfg.game_not_running, nil]
      when GamePhase::LOADING
        [status_cfg.loading, version_suffix(pres_cfg)]
      when GamePhase::MAIN_MENU
        [status_cfg.in_main_menu, version_suffix(pres_cfg)]
      when GamePhase::IN_GAME
        vars = {
          country: @country_name.to_s,
          tag: @country_tag.to_s,
          year: year_label,
          date: (@date_str || year_label).to_s,
          age: age_label
        }

        details = if @observer
                    ConfigManager.apply_vars(status_cfg.observing, vars)
                  elsif @country_name && !@country_name.empty?
                    ConfigManager.apply_vars(status_cfg.in_game_with_country, vars)
                  else
                    ConfigManager.apply_vars(status_cfg.in_game_unknown_country, vars)
                  end

        parts = []
        parts << @active_event if pres_cfg.show_live_events && @active_event && !@active_event.empty?
        parts << age_label if pres_cfg.show_historical_age && !age_label.empty? && parts.empty?
        parts << mode_label
        parts << "v#{@game_version}" if pres_cfg.show_game_version && @game_version && !@game_version.empty?

        [details, parts.join(" · ")]
      else
        [status_cfg.game_not_running, nil]
      end
    end

    private

    def version_suffix(pres_cfg)
      if pres_cfg.show_game_version && @game_version && !@game_version.empty?
        "v#{@game_version}"
      end
    end
  end
end
