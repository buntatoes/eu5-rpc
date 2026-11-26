# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "json"
require "securerandom"
require "socket"
require_relative "logger"

module Eu5Rpc
  # Pure-Ruby Discord Rich Presence IPC client over Windows Named Pipes and Unix Domain Sockets.
  class DiscordIpcClient
    OP_HANDSHAKE = 0
    OP_FRAME     = 1

    attr_reader :app_id

    def self.build_activity_payload(details:, state:, start_time:, img_cfg:)
      assets = {}
      unless img_cfg.large_image.to_s.empty?
        assets["large_image"] = img_cfg.large_image
        assets["large_text"]  = img_cfg.large_image_tooltip unless img_cfg.large_image_tooltip.to_s.empty?
      end
      unless img_cfg.small_image.to_s.empty?
        assets["small_image"] = img_cfg.small_image
        assets["small_text"]  = img_cfg.small_image_tooltip unless img_cfg.small_image_tooltip.to_s.empty?
      end

      activity = { "details" => details }
      activity["state"] = state if state && !state.empty?
      activity["assets"] = assets unless assets.empty?
      activity["timestamps"] = { "start" => start_time.to_i } if start_time
      activity
    end

    def initialize(app_id)
      @app_id = app_id.to_s
      @io = nil
    end

    def connect
      close
      (0..9).each do |idx|
        io = try_open_pipe(idx)
        next unless io

        @io = io
        send_frame(OP_HANDSHAKE, { "v" => 1, "client_id" => @app_id })
        read_frame
        return true
      rescue StandardError
        close
      end
      raise IOError, "Unable to connect to Discord IPC pipe (0..9)"
    end

    def reconnect
      close
      connect
    end

    def set_activity(activity_hash)
      raise IOError, "Discord IPC not connected" unless @io

      payload = {
        "cmd"   => "SET_ACTIVITY",
        "args"  => { "pid" => Process.pid, "activity" => activity_hash },
        "nonce" => SecureRandom.uuid
      }
      send_frame(OP_FRAME, payload)
      read_frame
      true
    end

    def clear_activity
      return false unless @io

      payload = {
        "cmd"   => "SET_ACTIVITY",
        "args"  => { "pid" => Process.pid, "activity" => nil },
        "nonce" => SecureRandom.uuid
      }
      send_frame(OP_FRAME, payload)
      read_frame
      true
    rescue StandardError
      false
    end

    def close
      @io&.close
    rescue StandardError
      # Ignore close errors
    ensure
      @io = nil
    end

    private

    def try_open_pipe(idx)
      if Gem.win_platform?
        File.open("\\\\.\\pipe\\discord-ipc-#{idx}", "r+b")
      else
        dirs = [ENV["XDG_RUNTIME_DIR"], ENV["TMPDIR"], ENV["TMP"], ENV["TEMP"], "/tmp"].compact.uniq
        dirs.each do |d|
          [
            File.join(d, "discord-ipc-#{idx}"),
            File.join(d, "app/com.discordapp.Discord/discord-ipc-#{idx}"),
            File.join(d, "snap.discord/discord-ipc-#{idx}")
          ].each do |sock_path|
            next unless File.exist?(sock_path)

            return UNIXSocket.new(sock_path)
          rescue StandardError
            next
          end
        end
        nil
      end
    rescue StandardError
      nil
    end

    def send_frame(opcode, data_hash)
      json = JSON.generate(data_hash)
      @io.write([opcode, json.bytesize].pack("V2"))
      @io.write(json)
      @io.flush
    end

    def read_frame
      header = @io.read(8)
      raise EOFError, "Discord IPC closed" unless header && header.bytesize == 8

      opcode, length = header.unpack("V2")
      body = length.positive? ? @io.read(length) : ""
      [opcode, body]
    end
  end
end
