# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "socket"
require_relative "eu5_rpc/logger"
require_relative "eu5_rpc/toml"
require_relative "eu5_rpc/config"
require_relative "eu5_rpc/game_state"
require_relative "eu5_rpc/save_inspector"
require_relative "eu5_rpc/log_watcher"
require_relative "eu5_rpc/discord_ipc"
require_relative "eu5_rpc/process_watcher"
require_relative "eu5_rpc/steam"

module Eu5Rpc
  VERSION = "0.2.0"
  # Official public Discord detectable-application ID for Europa Universalis V (not user-specific).
  DEFAULT_DISCORD_APP_ID = "1435327845051400292"
  SINGLE_INSTANCE_PORT = 47_785

  class Application
    def self.try_acquire_single_instance_lock
      TCPServer.new("127.0.0.1", SINGLE_INSTANCE_PORT)
    rescue StandardError
      nil
    end

    def initialize(argv = ARGV)
      @argv = argv.dup
    end

    def run
      flags, game_command = split_args(@argv)

      if flags.include?("--version") || flags.include?("-v")
        puts "eu5-rpc v#{VERSION}"
        return 0
      end

      if flags.include?("--help") || flags.include?("-h")
        print_help
        return 0
      end

      if flags.include?("--generate-config")
        File.write(ConfigManager.config_path, ConfigManager::DEFAULT_TOML)
        puts "Wrote default config.toml"
        return 0
      end

      RpcLogger.init
      cfg = ConfigManager.load
      RpcLogger.info("[config] Loaded from #{ConfigManager.config_path}")

      instance_lock = self.class.try_acquire_single_instance_lock
      no_launch = flags.include?("--no-launch")

      if instance_lock.nil?
        if flags.include?("--launch-with-command") && !game_command.empty?
          pid = Process.spawn(game_command[0], *(game_command[1..] || []))
          Process.wait(pid)
        elsif !no_launch && cfg.general.launch_game_on_start && !ProcessWatcher.eu5_running?
          Steam.launch_eu5
        else
          RpcLogger.info("[eu5-rpc] Another instance is already running. Exiting.")
        end
        return 0
      end

      if flags.include?("--launch-with-command") && !game_command.empty?
        Process.spawn(game_command[0], *(game_command[1..] || []))
      elsif !no_launch && cfg.general.launch_game_on_start && !ProcessWatcher.eu5_running?
        Steam.launch_eu5
      end

      user_data_dir = Steam.find_user_data_dir(cfg.general.user_data_folder)
      state = GameState.new
      mutex = Mutex.new

      Thread.new { LogWatcher.new(user_data_dir, cfg.general.poll_interval_ms).run(state, mutex) }
      Thread.new { ProcessWatcher.run(state, mutex) }

      run_rpc_loop(state, mutex, cfg)
    ensure
      instance_lock&.close rescue nil
    end

    private

    def split_args(argv)
      if (idx = argv.index("--"))
        [argv[0...idx], argv[(idx + 1)..] || []]
      else
        [argv, []]
      end
    end

    def print_help
      puts <<~HELP
        Europa Universalis V Rich Presence for Discord (v#{VERSION}, GPL-3.0)
        Usage: eu5-rpc [OPTIONS] [-- <game command>]

        Options:
          --no-launch                    Skip launching EU5 via Steam on startup
          --launch-with-command -- <cmd> Launch custom command (for Steam %command%)
          --generate-config              Write default config.toml and exit
          -v, --version                  Show version
          -h, --help                     Show this help message
      HELP
    end

    def connect_discord(app_id)
      client = DiscordIpcClient.new(app_id)
      loop do
        client.connect
        RpcLogger.info("[discord] Connected!")
        return client
      rescue StandardError => e
        RpcLogger.warn("[discord] Connect failed: #{e.message}. Retrying in 10s...")
        sleep(10)
      end
    end

    def run_rpc_loop(state, mutex, cfg)
      app_id = cfg.general.discord_app_id.to_s.strip
      app_id = DEFAULT_DISCORD_APP_ID if app_id.empty?

      RpcLogger.info("[discord] Connecting to local Discord session...")
      client = connect_discord(app_id)
      last_payload_key = nil
      game_was_running = false
      session_start_time = Time.now.to_i
      update_interval = [cfg.general.discord_update_interval_s.to_i, 1].max

      trap("INT")  { client.clear_activity; client.close; exit(0) }
      trap("TERM") { client.clear_activity; client.close; exit(0) }

      loop do
        phase, details, state_line = mutex.synchronize do
          d, s = state.format_presence(cfg.presence)
          [state.phase, d, s]
        end

        if phase != GamePhase::NOT_RUNNING
          game_was_running = true
        elsif game_was_running
          RpcLogger.info("[eu5-rpc] Europa Universalis V closed.")
          if cfg.general.exit_when_game_closes
            client.clear_activity
            client.close
            exit(0)
          end
        end

        key = [phase, details, state_line]
        if key != last_payload_key
          RpcLogger.info("[rpc] phase=#{phase} details=\"#{details}\" state=\"#{state_line || 'none'}\"")
          act = DiscordIpcClient.build_activity_payload(
            details: details,
            state: state_line,
            start_time: cfg.presence.show_session_timer ? session_start_time : nil,
            img_cfg: cfg.images
          )
          begin
            client.set_activity(act)
            last_payload_key = key
          rescue StandardError => e
            RpcLogger.warn("[rpc] set_activity error: #{e.message}. Reconnecting...")
            begin
              client.reconnect
            rescue StandardError
              # Retry next cycle
            end
          end
        end

        sleep(update_interval)
      end
    end
  end
end
