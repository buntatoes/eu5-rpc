# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "toml"
require_relative "logger"

module Eu5Rpc
  GeneralConfig = Struct.new(
    :discord_app_id,
    :launch_game_on_start,
    :exit_when_game_closes,
    :poll_interval_ms,
    :discord_update_interval_s,
    :user_data_folder,
    :config_version,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = {
        discord_app_id: "",
        launch_game_on_start: true,
        exit_when_game_closes: true,
        poll_interval_ms: 1000,
        discord_update_interval_s: 5,
        user_data_folder: nil,
        config_version: 1
      }
      super(defaults.merge(kwargs))
    end
  end

  StatusStrings = Struct.new(
    :game_not_running,
    :loading,
    :in_main_menu,
    :in_game_with_country,
    :in_game_unknown_country,
    :observing,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = {
        game_not_running: "Not Running",
        loading: "Loading Europa Universalis V...",
        in_main_menu: "Browsing the Main Menu",
        in_game_with_country: "Playing as {country} ({year})",
        in_game_unknown_country: "In Campaign ({year})",
        observing: "Observing the World ({year})"
      }
      super(defaults.merge(kwargs))
    end
  end

  PresenceConfig = Struct.new(
    :show_game_version,
    :show_historical_age,
    :show_live_events,
    :show_session_timer,
    :status,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = {
        show_game_version: true,
        show_historical_age: true,
        show_live_events: true,
        show_session_timer: true,
        status: StatusStrings.new
      }
      super(defaults.merge(kwargs))
    end
  end

  ImagesConfig = Struct.new(
    :large_image,
    :large_image_tooltip,
    :small_image,
    :small_image_tooltip,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      defaults = {
        large_image: "https://raw.githubusercontent.com/buntatoes/eu5-rpc/main/assets/icon.png",
        large_image_tooltip: "Europa Universalis V",
        small_image: "",
        small_image_tooltip: "EU5 RPC"
      }
      super(defaults.merge(kwargs))
    end
  end

  Config = Struct.new(:general, :presence, :images, keyword_init: true) do
    def initialize(**kwargs)
      super(
        general: kwargs[:general] || GeneralConfig.new,
        presence: kwargs[:presence] || PresenceConfig.new,
        images: kwargs[:images] || ImagesConfig.new
      )
    end
  end

  module ConfigManager
    CURRENT_CONFIG_VERSION = 1

    DEFAULT_TOML = <<~TOML
      [general]
      # Leave blank to automatically link with Discord's built-in Europa Universalis V application.
      discord_app_id = ""
      launch_game_on_start = true
      exit_when_game_closes = true
      poll_interval_ms = 1000
      discord_update_interval_s = 5
      # Override Paradox user data folder if auto-detection fails.
      # Example: Documents\\Paradox Interactive\\Europa Universalis V
      user_data_folder = ""
      config_version = 1

      [presence]
      show_game_version = true
      show_historical_age = true
      show_live_events = true
      show_session_timer = true

      [presence.status]
      game_not_running = "Not Running"
      loading = "Loading Europa Universalis V..."
      in_main_menu = "Browsing the Main Menu"
      # Supports {country}, {tag}, {year}, {date}, {age}
      in_game_with_country = "Playing as {country} ({year})"
      in_game_unknown_country = "In Campaign ({year})"
      observing = "Observing the World ({year})"

      [images]
      # Direct HTTPS image URL or Discord Art Asset key.
      large_image = "https://raw.githubusercontent.com/buntatoes/eu5-rpc/main/assets/icon.png"
      large_image_tooltip = "Europa Universalis V"
      small_image = ""
      small_image_tooltip = "EU5 RPC"
    TOML

    module_function

    def config_path(base_dir = RpcLogger.resolve_data_dir)
      File.join(base_dir, "config.toml")
    end

    def apply_vars(template, vars)
      result = template.to_s.dup
      vars.each { |k, v| result.gsub!("{#{k}}", v.to_s) }
      result
    end

    def load(path = config_path)
      unless File.exist?(path)
        File.write(path, DEFAULT_TOML)
        return from_hash(Toml.parse(DEFAULT_TOML))
      end

      raw = File.read(path, encoding: "UTF-8")
      from_hash(Toml.parse(raw))
    rescue StandardError => e
      RpcLogger.warn("[config] Failed to load #{path} (#{e.message}), using defaults")
      from_hash(Toml.parse(DEFAULT_TOML))
    end

    def from_hash(h)
      gen_h = h["general"] || {}
      pres_h = h["presence"] || {}
      stat_h = pres_h["status"] || {}
      img_h = h["images"] || {}

      udf = gen_h["user_data_folder"].to_s.strip
      general = GeneralConfig.new(
        discord_app_id: gen_h["discord_app_id"].to_s.strip,
        launch_game_on_start: bool_or(gen_h["launch_game_on_start"], true),
        exit_when_game_closes: bool_or(gen_h["exit_when_game_closes"], true),
        poll_interval_ms: int_or(gen_h["poll_interval_ms"], 1000),
        discord_update_interval_s: int_or(gen_h["discord_update_interval_s"], 5),
        user_data_folder: udf.empty? ? nil : udf,
        config_version: int_or(gen_h["config_version"], CURRENT_CONFIG_VERSION)
      )

      status = StatusStrings.new(
        game_not_running: str_or(stat_h["game_not_running"], "Not Running"),
        loading: str_or(stat_h["loading"], "Loading Europa Universalis V..."),
        in_main_menu: str_or(stat_h["in_main_menu"], "Browsing the Main Menu"),
        in_game_with_country: str_or(stat_h["in_game_with_country"], "Playing as {country} ({year})"),
        in_game_unknown_country: str_or(stat_h["in_game_unknown_country"], "In Campaign ({year})"),
        observing: str_or(stat_h["observing"], "Observing the World ({year})")
      )

      presence = PresenceConfig.new(
        show_game_version: bool_or(pres_h["show_game_version"], true),
        show_historical_age: bool_or(pres_h["show_historical_age"], true),
        show_live_events: bool_or(pres_h["show_live_events"], true),
        show_session_timer: bool_or(pres_h["show_session_timer"], true),
        status: status
      )

      images = ImagesConfig.new(
        large_image: str_or(img_h["large_image"], "https://raw.githubusercontent.com/buntatoes/eu5-rpc/main/assets/icon.png"),
        large_image_tooltip: str_or(img_h["large_image_tooltip"], "Europa Universalis V"),
        small_image: str_or(img_h["small_image"], ""),
        small_image_tooltip: str_or(img_h["small_image_tooltip"], "EU5 RPC")
      )

      Config.new(general: general, presence: presence, images: images)
    end

    def bool_or(val, default)
      val.is_a?(TrueClass) || val.is_a?(FalseClass) ? val : default
    end

    def int_or(val, default)
      val.is_a?(Integer) ? val : default
    end

    def str_or(val, default)
      val.is_a?(String) ? val : default
    end
  end
end
