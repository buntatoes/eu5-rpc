# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "logger"

module Eu5Rpc
  module Steam
    EU5_APP_ID = "3450310"

    module_function

    def find_user_data_dir(override = nil)
      custom = override.to_s.strip
      if !custom.empty? && File.directory?(custom)
        RpcLogger.info("[eu5] Using configured user_data_folder: #{custom}")
        return custom
      end

      candidate = user_data_candidates.find { |dir| File.directory?(dir) }
      if candidate
        RpcLogger.info("[eu5] Detected Paradox user data folder: #{candidate}")
        return candidate
      end

      fallback = user_data_candidates.first
      RpcLogger.warn("[eu5] Paradox EU5 user data folder not found yet. Monitoring default: #{fallback}")
      fallback
    end

    def user_data_candidates
      if Gem.win_platform?
        candidates = []
        if (docs = windows_documents_dir)
          candidates << File.join(docs, "Paradox Interactive", "Europa Universalis V")
        end
        home = ENV["USERPROFILE"] || Dir.home rescue ""
        unless home.empty?
          candidates << File.join(home, "OneDrive", "Documents", "Paradox Interactive", "Europa Universalis V")
          candidates << File.join(home, "Documents", "Paradox Interactive", "Europa Universalis V")
        end
        candidates.uniq
      else
        home = Dir.home rescue ""
        [
          File.join(home, ".local", "share", "Paradox Interactive", "Europa Universalis V"),
          File.join(home, ".paradoxinteractive", "Europa Universalis V")
        ]
      end
    end

    def windows_documents_dir
      return nil unless Gem.win_platform?

      require "win32/registry"
      Win32::Registry::HKEY_CURRENT_USER.open('Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') do |reg|
        val = reg["Personal"].to_s.strip
        next nil if val.empty?

        expanded = val.gsub(/%([^%]+)%/) { ENV[Regexp.last_match(1)] || Regexp.last_match(0) }
        File.directory?(expanded) ? expanded : nil
      end
    rescue StandardError
      nil
    end

    def steam_exe_path
      if Gem.win_platform?
        root = steam_root_windows
        root ? File.join(root, "steam.exe") : nil
      else
        ENV.fetch("PATH", "").split(":").each do |dir|
          candidate = File.join(dir, "steam")
          return candidate if File.exist?(candidate)
        end
        home = Dir.home rescue ""
        [
          File.join(home, ".local/share/Steam/steam.sh"),
          File.join(home, ".steam/steam.sh"),
          "/usr/bin/steam",
          "/usr/local/bin/steam"
        ].find { |p| File.exist?(p) }
      end
    end

    def steam_root_windows
      if Gem.win_platform?
        begin
          require "win32/registry"
          Win32::Registry::HKEY_CURRENT_USER.open('Software\Valve\Steam') do |reg|
            path = reg["SteamPath"].to_s
            return path if !path.empty? && File.directory?(path)
          end
        rescue StandardError
          # Fallback below
        end
      end

      ['C:\Program Files (x86)\Steam', 'C:\Program Files\Steam'].find { |p| File.directory?(p) }
    end

    def launch_eu5
      steam_exe = steam_exe_path
      unless steam_exe
        RpcLogger.warn("[launcher] Could not locate Steam executable. Launch Europa Universalis V manually.")
        return
      end

      RpcLogger.info("[launcher] Launching Europa Universalis V via Steam (AppID #{EU5_APP_ID})...")
      Process.spawn(steam_exe, "-applaunch", EU5_APP_ID)
    rescue StandardError => e
      RpcLogger.warn("[launcher] Failed to launch EU5 via Steam: #{e.message}")
    end
  end
end
