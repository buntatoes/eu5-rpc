# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "steam"
require_relative "logger"

module Eu5Rpc
  # Passively reads the local Steam client's live Rich Presence key-value pairs for the
  # active user via steamclient64.dll (Windows) or steamclient.so (Linux).
  #
  # Why this works cleanly:
  # - EU5 pushes live Steam Rich Presence (#main_menu, #in_lobby, #playing, COUNTRY, YEAR, STATUS)
  #   whenever you pick a country, swap countries mid-game, form a nation, or advance the year.
  # - Uses ISteamClient::ConnectToGlobalUser (passive read-only pipe, no SteamAPI_Init or AppID conflict).
  # - Never reads game memory, never modifies game files, and never logs or persists your Steam ID.
  class SteamRichPresence
    STEAM_CLIENT_IFACE  = "SteamClient021"
    STEAM_USER_IFACE    = "SteamUser023"
    STEAM_FRIENDS_IFACE = "SteamFriends017"

    # Verified x64 vtable indices for ISteamClient021 / ISteamUser023 / ISteamFriends017
    VT_CREATE_PIPE         = 0
    VT_RELEASE_PIPE        = 1
    VT_CONNECT_GLOBAL_USER = 2
    VT_RELEASE_USER        = 4
    VT_GET_STEAM_USER      = 5
    VT_GET_STEAM_FRIENDS   = 8

    VT_USER_GET_STEAM_ID   = 2

    VT_FRIENDS_GET_RP           = 45
    VT_FRIENDS_GET_RP_KEY_COUNT = 46
    VT_FRIENDS_GET_RP_KEY_AT    = 47
    VT_FRIENDS_REQUEST_RP       = 48

    def self.parse_presence_hash(raw_map)
      return nil unless raw_map.is_a?(Hash) && !raw_map.empty?

      norm = {}
      raw_map.each { |k, v| norm[k.to_s.downcase] = v.to_s.strip }

      display = norm["steam_display"].to_s.downcase
      country = norm["country"].to_s
      year_s  = norm["year"].to_s
      status  = norm["status"].to_s

      # Strip Paradox rich-text formatting codes (e.g., #bold ...#! or [tag]) if present
      country = clean_pdx_text(country)
      status  = clean_pdx_text(status)
      year    = year_s.match?(/\A\d{3,4}\z/) ? year_s.to_i : nil

      phase = case display
              when "#main_menu"
                GamePhase::MAIN_MENU
              when "#in_lobby"
                GamePhase::LOBBY
              when "#playing", "#playing_mp", "#playing_observer", "#playing_observer_mp"
                GamePhase::IN_GAME
              else
                !country.empty? ? GamePhase::IN_GAME : nil
              end

      return nil if phase.nil? && country.empty? && year.nil?

      {
        phase: phase,
        country: country.empty? ? nil : country,
        year: year,
        status: status.empty? ? nil : status,
        multiplayer: display.end_with?("_mp"),
        observer: display.include?("observer")
      }
    end

    def self.clean_pdx_text(str)
      s = str.to_s.dup
      s.gsub!(/#[a-zA-Z0-9_]+\s*/, "")
      s.gsub!(/#!/, "")
      s.strip
    end

    def initialize
      @connected = false
      @client_ptr = nil
      @pipe = 0
      @user = 0
      @steam_friends = nil
      @steam_id = 0
      @fns = {}
    end

    def available?
      return false unless Fiddle::SIZEOF_VOIDP == 8

      !find_steamclient_lib.nil?
    rescue StandardError
      false
    end

    def poll
      ensure_connected
      return nil unless @connected && @steam_friends && @steam_id.positive?

      @fns[:request_rp].call(@steam_friends, @steam_id)
      count = @fns[:get_rp_count].call(@steam_friends, @steam_id)
      return nil if count <= 0 || count > 64

      raw = {}
      count.times do |idx|
        kp = @fns[:get_rp_key].call(@steam_friends, @steam_id, idx)
        next if kp.null?

        key = kp.to_s
        next if key.empty?

        vp = @fns[:get_rp_val].call(@steam_friends, @steam_id, key)
        raw[key] = vp.null? ? "" : vp.to_s.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
      end

      self.class.parse_presence_hash(raw)
    rescue StandardError => e
      RpcLogger.debug("[steam-rp] Poll failed: #{e.message}")
      disconnect
      nil
    end

    def disconnect
      if @connected && @client_ptr && !@client_ptr.null?
        @fns[:release_user]&.call(@client_ptr, @pipe, @user) if @pipe.positive? && @user.positive?
        @fns[:release_pipe]&.call(@client_ptr, @pipe) if @pipe.positive?
      end
    rescue StandardError
      # Ignore cleanup errors
    ensure
      @connected = false
      @client_ptr = nil
      @pipe = 0
      @user = 0
      @steam_friends = nil
      @steam_id = 0
      @fns = {}
    end

    private

    def ensure_connected
      return if @connected

      require "fiddle"
      return unless Fiddle::SIZEOF_VOIDP == 8

      lib_path = find_steamclient_lib
      return unless lib_path

      if Gem.win_platform?
        steam_dir = File.dirname(lib_path)
        ENV["PATH"] = "#{steam_dir};#{ENV['PATH']}" unless ENV["PATH"].to_s.include?(steam_dir)
        kernel32 = Fiddle.dlopen("kernel32.dll")
        set_dll_dir = Fiddle::Function.new(kernel32["SetDllDirectoryA"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
        set_dll_dir.call(steam_dir)
      end

      handle = Fiddle.dlopen(lib_path)
      create_iface = Fiddle::Function.new(
        handle["CreateInterface"],
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
        Fiddle::TYPE_VOIDP
      )

      rc = [0].pack("l")
      client_ptr = create_iface.call(STEAM_CLIENT_IFACE, rc)
      return if client_ptr.null?

      c_vt = Fiddle::Pointer.new(client_ptr[0, 8].unpack1("Q"))
      create_pipe  = vtable_fn(c_vt, VT_CREATE_PIPE, [], Fiddle::TYPE_INT)
      release_pipe = vtable_fn(c_vt, VT_RELEASE_PIPE, [Fiddle::TYPE_INT], Fiddle::TYPE_CHAR)
      connect_user = vtable_fn(c_vt, VT_CONNECT_GLOBAL_USER, [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      release_user = vtable_fn(c_vt, VT_RELEASE_USER, [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_VOID)
      get_user     = vtable_fn(c_vt, VT_GET_STEAM_USER, [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      get_friends  = vtable_fn(c_vt, VT_GET_STEAM_FRIENDS, [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)

      pipe = create_pipe.call(client_ptr)
      return if pipe <= 0

      user = connect_user.call(client_ptr, pipe)
      if user <= 0
        release_pipe.call(client_ptr, pipe)
        return
      end

      steam_user    = get_user.call(client_ptr, user, pipe, STEAM_USER_IFACE)
      steam_friends = get_friends.call(client_ptr, user, pipe, STEAM_FRIENDS_IFACE)
      if steam_user.null? || steam_friends.null?
        release_user.call(client_ptr, pipe, user)
        release_pipe.call(client_ptr, pipe)
        return
      end

      u_vt = Fiddle::Pointer.new(steam_user[0, 8].unpack1("Q"))
      f_vt = Fiddle::Pointer.new(steam_friends[0, 8].unpack1("Q"))

      sid = read_steam_id(u_vt, steam_user)
      if sid <= 0
        release_user.call(client_ptr, pipe, user)
        release_pipe.call(client_ptr, pipe)
        return
      end

      @client_ptr = client_ptr
      @pipe = pipe
      @user = user
      @steam_friends = steam_friends
      @steam_id = sid
      @fns = {
        release_pipe: release_pipe,
        release_user: release_user,
        get_rp_val:   vtable_fn(f_vt, VT_FRIENDS_GET_RP, [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP),
        get_rp_count: vtable_fn(f_vt, VT_FRIENDS_GET_RP_KEY_COUNT, [Fiddle::TYPE_LONG_LONG], Fiddle::TYPE_INT),
        get_rp_key:   vtable_fn(f_vt, VT_FRIENDS_GET_RP_KEY_AT, [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP),
        request_rp:   vtable_fn(f_vt, VT_FRIENDS_REQUEST_RP, [Fiddle::TYPE_LONG_LONG], Fiddle::TYPE_VOID)
      }
      @connected = true
      RpcLogger.info("[steam-rp] Connected passively to local Steam client for live EU5 Rich Presence")
    rescue StandardError => e
      RpcLogger.debug("[steam-rp] Unavailable: #{e.message}")
      disconnect
    end

    def read_steam_id(u_vt, steam_user)
      if Gem.win_platform?
        # MSVC x64 returns 8-byte CSteamID struct via hidden second pointer argument
        fn = vtable_fn(u_vt, VT_USER_GET_STEAM_ID, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
        out = [0].pack("Q")
        fn.call(steam_user, out)
        out.unpack1("Q")
      else
        # System V AMD64 ABI returns 8-byte CSteamID struct in RAX
        fn = vtable_fn(u_vt, VT_USER_GET_STEAM_ID, [], Fiddle::TYPE_LONG_LONG)
        fn.call(steam_user)
      end
    end

    def vtable_fn(vt, idx, args, ret)
      addr = vt[idx * 8, 8].unpack1("Q")
      Fiddle::Function.new(addr, [Fiddle::TYPE_VOIDP] + args, ret)
    end

    def find_steamclient_lib
      if Gem.win_platform?
        root = Steam.steam_root_windows
        return nil unless root

        candidate = File.join(root, "steamclient64.dll")
        File.file?(candidate) ? candidate : nil
      else
        home = Dir.home rescue ""
        [
          File.join(home, ".steam/sdk64/steamclient.so"),
          File.join(home, ".local/share/Steam/linux64/steamclient.so"),
          File.join(home, ".steam/steam/linux64/steamclient.so")
        ].find { |p| File.file?(p) }
      end
    end
  end
end
