# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "fileutils"
require "time"

module Eu5Rpc
  module RpcLogger
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze

    @mutex = Mutex.new
    @level = :info
    @log_file = nil
    @log_path = nil

    class << self
      attr_accessor :level
      attr_reader :log_path

      def resolve_data_dir(app_root = File.expand_path("../..", __dir__))
        if directory_writable?(app_root)
          app_root
        elsif Gem.win_platform?
          base = ENV["LOCALAPPDATA"] || File.join(Dir.home, "AppData", "Local")
          dir = File.join(base, "EU5-RPC")
          FileUtils.mkdir_p(dir)
          dir
        else
          base = ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config")
          dir = File.join(base, "eu5-rpc")
          FileUtils.mkdir_p(dir)
          dir
        end
      rescue StandardError
        Dir.pwd
      end

      def directory_writable?(dir)
        return false unless File.directory?(dir)

        probe = File.join(dir, ".eu5_rpc_write_test_#{Process.pid}")
        File.write(probe, "")
        File.delete(probe)
        true
      rescue StandardError
        false
      end

      def init(base_dir = resolve_data_dir)
        logs_dir = File.join(base_dir, "logs")
        FileUtils.mkdir_p(logs_dir)
        @log_path = File.join(logs_dir, "eu5-rpc.log")
        @log_file = File.open(@log_path, "w:UTF-8")
        @log_file.sync = true
        info("eu5-rpc started - log: #{@log_path}")
      rescue StandardError => e
        $stderr.puts("[WARN] Failed to initialize log file: #{e.message}")
      end

      def close
        @mutex.synchronize do
          @log_file&.close
          @log_file = nil
        end
      end

      def debug(msg) = write(:debug, msg)
      def info(msg)  = write(:info, msg)
      def warn(msg)  = write(:warn, msg)
      def error(msg) = write(:error, msg)

      private

      def write(lvl, msg)
        return if LEVELS[lvl] < LEVELS[@level]

        ts = Time.now.utc.iso8601(7)
        line = "#{ts} [#{lvl.to_s.upcase}] #{msg}\n"
        @mutex.synchronize do
          $stdout.print(line)
          $stdout.flush
          @log_file&.print(line)
        end
      rescue StandardError
        # Ignore stdout/log I/O failures under GUI subsystem
      end
    end
  end
end
