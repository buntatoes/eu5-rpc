# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "game_state"
require_relative "logger"

module Eu5Rpc
  # Native zero-subprocess process watcher (Win32 CreateToolhelp32Snapshot / Linux /proc).
  # Never spawns console executables and never reads game memory.
  module ProcessWatcher
    POLL_INTERVAL_S = 3

    if Gem.win_platform?
      require "fiddle"
      require "fiddle/import"

      module Win32Snapshot
        extend Fiddle::Importer
        dlload "kernel32.dll"

        TH32CS_SNAPPROCESS = 0x00000002
        INVALID_HANDLE_VALUE = -1
        EXE_NAME_OFFSET = (Fiddle::SIZEOF_VOIDP == 8) ? 44 : 36
        PROCESSENTRY32_SIZE = EXE_NAME_OFFSET + 260

        extern "void* CreateToolhelp32Snapshot(unsigned long, unsigned long)"
        extern "int Process32First(void*, void*)"
        extern "int Process32Next(void*, void*)"
        extern "int CloseHandle(void*)"
      end
    end

    module_function

    def process_running?(target_name)
      target = target_name.to_s.downcase
      if Gem.win_platform?
        win32_process_running?(target)
      else
        linux_process_running?(target)
      end
    rescue StandardError
      false
    end

    def linux_process_running?(target_lower)
      stem = target_lower.sub(/\.exe\z/, "")

      Dir.glob("/proc/[0-9]*").any? do |proc_dir|
        comm = (File.read(File.join(proc_dir, "comm")) rescue "").strip.downcase
        next true if comm == target_lower || comm == stem

        raw_cmd = (File.binread(File.join(proc_dir, "cmdline")) rescue "")
        next false if raw_cmd.empty?

        cmdline_matches_target?(raw_cmd, target_lower, stem)
      end
    rescue StandardError
      false
    end

    def cmdline_matches_target?(raw_cmd, target_lower, stem = target_lower.sub(/\.exe\z/, ""))
      args = raw_cmd.to_s.split("\0").reject(&:empty?)
      return false if args.empty?

      argv0 = args[0]
      argv0_base = File.basename(argv0.tr("\\", "/")).downcase
      return true if argv0_base == target_lower || argv0_base == stem
      return true if matches_windows_exe?(argv0, target_lower)

      if argv0_base.start_with?("wine") || argv0_base == "proton" || argv0_base == "reaper" || argv0_base == "python3"
        args[1..].any? do |arg|
          next false if arg.start_with?("-")

          matches_windows_exe?(arg, target_lower)
        end
      else
        false
      end
    end

    def matches_windows_exe?(arg, target_lower)
      s = arg.to_s.tr("\\", "/").strip
      return false if s.empty?

      return true if File.basename(s).downcase == target_lower

      if (idx = s.downcase.index(target_lower))
        before = idx.zero? ? "/" : s[idx - 1]
        after = s[idx + target_lower.length]
        return (before == "/" || before == " " || before == '"') &&
               (after.nil? || after == " " || after == '"' || after == "\t")
      end

      false
    end

    def win32_process_running?(target_lower)
      snapshot = Win32Snapshot.CreateToolhelp32Snapshot(Win32Snapshot::TH32CS_SNAPPROCESS, 0)
      return false if snapshot.null? || snapshot.to_i == Win32Snapshot::INVALID_HANDLE_VALUE

      begin
        buf = +"\0" * Win32Snapshot::PROCESSENTRY32_SIZE
        buf[0, 4] = [Win32Snapshot::PROCESSENTRY32_SIZE].pack("V")
        return false if Win32Snapshot.Process32First(snapshot, buf) == 0

        loop do
          raw_name = buf[Win32Snapshot::EXE_NAME_OFFSET, 260]
          exe_name = raw_name.split("\0", 2).first.to_s.downcase
          return true if exe_name == target_lower

          break if Win32Snapshot.Process32Next(snapshot, buf) == 0
        end
        false
      ensure
        Win32Snapshot.CloseHandle(snapshot)
      end
    end

    def eu5_running?
      process_running?("eu5.exe")
    end

    def run(state, mutex)
      was_running = false

      loop do
        running = eu5_running?

        if running && !was_running
          RpcLogger.info("[process] Europa Universalis V detected (eu5.exe)")
          mutex.synchronize do
            state.enter_loading if state.phase == GamePhase::NOT_RUNNING
          end
        elsif !running && was_running
          RpcLogger.info("[process] Europa Universalis V exited - resetting state")
          mutex.synchronize { state.reset }
        end

        was_running = running
        sleep(POLL_INTERVAL_S)
      end
    end
  end
end
