# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "steam"
require_relative "process_watcher"
require_relative "logger"

module Eu5Rpc
  # Passively reads the local Steam client's live Rich Presence strings for Europa Universalis V
  # via steamclient64.dll (Windows) or steamclient.so (Linux).
  #
  # EU5 publishes live formatted Steam Rich Presence strings such as:
  #   "In Main Menu"
  #   "In Lobby"
  #   "Ruling the realm as Principality of Kyiv, 1337"
  #   "Tributary under the Golden Horde as Principality of Kyiv, 1337"
  #   "At war against Ottomans as Byzantium, 1345 (Multiplayer)"
  #   "Observing how the world unfolds, 1444"
  #
  # These update in real time even when switching countries mid-game, forming a nation,
  # or playing a brand-new unsaved campaign. Only connects while eu5.exe is running and
  # disconnects immediately on exit. Never reads game memory or logs your Steam ID.
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

    # Official EU5 localized Rich Presence strings across all 11 supported languages:
    # English, Brazilian Portuguese, French, German, Japanese, Korean, Polish,
    # Russian, Simplified Chinese, Spanish, and Turkish.
    MAIN_MENU_STRINGS = [
      "in main menu",
      "no menu principal",
      "dans le menu principal",
      "im hauptmenü",
      "メインメニュー",
      "메인 메뉴",
      "w menu głównym",
      "в главном меню",
      "位于主菜单",
      "en el menú principal",
      "ana menüde"
    ].freeze

    LOBBY_STRINGS = [
      "in lobby",
      "no lobby",
      "dans le salon",
      "in der lobby",
      "ロビー",
      "로비",
      "w lobby",
      "в лобби",
      "位于多人游戏大厅",
      "en sala",
      "lobide"
    ].freeze

    MULTIPLAYER_TAG_RE = /(?:\s*[\(（](?:multiplayer|multijogador|multijoueur|mehrspieler|マルチプレイ|멀티플레이어|gra wieloosobowa|многопользовательская игра|多人游戏|multijugador|çok oyunculu)[\)）])\z/i.freeze

    OBSERVER_KEYWORDS = [
      "observing",
      "observando",
      "observe ",
      "beobachtet",
      "観測中",
      "관전 중",
      "obserwuje",
      "наблюдает",
      "观察世界",
      "izliyor"
    ].freeze

    # "<STATUS> <connector> <COUNTRY>, <YEAR>" (EN, PT-BR, FR, DE, PL, ES)
    STATUS_THEN_COUNTRY_RE = /\A(.+?)\s+(?:en tant que|as|como|als|jako)\s+(.+?),\s*(\d{3,4})\z/i.freeze
    # Russian: "<STATUS> за державу <COUNTRY>, <YEAR> год"
    RUSSIAN_PLAYING_RE     = /\A(.+?)\s+за\s+державу\s+(.+?),\s*(\d{3,4})[\s\u00A0]*год\z/i.freeze
    # Turkish: "<COUNTRY> olarak <STATUS>, <YEAR>"
    TURKISH_PLAYING_RE     = /\A(.+?)\s+olarak\s+(.+?),\s*(\d{3,4})\z/i.freeze
    # Japanese: "<COUNTRY>として<STATUS>、<YEAR>"
    JAPANESE_PLAYING_RE    = /\A(.+?)として(.+?)[、,]\s*(\d{3,4})\z/.freeze
    # Korean: "<YEAR>, <COUNTRY>(으)로 <STATUS>" (or "<COUNTRY>으로/로 <STATUS>")
    KOREAN_PLAYING_RE      = /\A(\d{3,4}),\s*(.+?)(?:\(으\)로|으로|로)\s+(.+)\z/.freeze
    # Simplified Chinese: "作为<COUNTRY><STATUS>，<YEAR>年"
    CHINESE_PLAYING_RE     = /\A作为(.+?)[，,]\s*(\d{3,4})年\z/.freeze
    CHINESE_STATUS_RE      = /\A(.+?)(破产|经历.+|输掉对抗.+|赢得对抗.+|与.+交战|处于摄政时期|时代霸主|领导.+|殖民新土地|统治国家|[^\s]+患有.+|[^\s]+隶属于.+)\z/.freeze

    # Observer formats across all 11 languages
    OBSERVER_TAIL_YEAR_RE  = /\A(.+?)[,、，]\s*(\d{3,4})(?:[\s\u00A0]*год|年)?\z/i.freeze
    OBSERVER_HEAD_YEAR_RE  = /\A(\d{3,4}),\s*(.+)\z/.freeze

    def self.parse_presence_hash(raw_map)
      return nil unless raw_map.is_a?(Hash) && !raw_map.empty?

      norm = {}
      raw_map.each { |k, v| norm[k.to_s.downcase] = clean_pdx_text(v.to_s) }

      display = norm["steam_display"].to_s
      status_raw = norm["status"].to_s
      text = !status_raw.empty? ? status_raw : display

      # 1. Check formatted EU5 localized Rich Presence string across all 11 languages
      if !text.empty? && !text.start_with?("#")
        mp = MULTIPLAYER_TAG_RE.match?(text)
        core = text.sub(MULTIPLAYER_TAG_RE, "").strip
        lower = core.downcase

        if MAIN_MENU_STRINGS.include?(lower)
          return { phase: GamePhase::MAIN_MENU, country: nil, year: nil, status: nil, multiplayer: false, observer: false }
        elsif LOBBY_STRINGS.include?(lower)
          return { phase: GamePhase::LOBBY, country: nil, year: nil, status: nil, multiplayer: mp, observer: false }
        elsif (m = RUSSIAN_PLAYING_RE.match(core))
          return playing_result(m[2], m[3], m[1], mp)
        elsif (m = STATUS_THEN_COUNTRY_RE.match(core))
          return playing_result(m[2], m[3], m[1], mp)
        elsif (m = TURKISH_PLAYING_RE.match(core))
          return playing_result(m[1], m[3], m[2], mp)
        elsif (m = JAPANESE_PLAYING_RE.match(core))
          return playing_result(m[1], m[3], m[2], mp)
        elsif (m = KOREAN_PLAYING_RE.match(core))
          return playing_result(m[2], m[1], m[3], mp)
        elsif (m = CHINESE_PLAYING_RE.match(core))
          body = m[1].strip
          year = m[2].to_i
          if (cm = CHINESE_STATUS_RE.match(body))
            return playing_result(cm[1], year, cm[2], mp)
          end
          return playing_result(body, year, nil, mp)
        elsif (m = OBSERVER_TAIL_YEAR_RE.match(core))
          st = m[1].strip
          return {
            phase: GamePhase::IN_GAME,
            status: st,
            country: nil,
            year: m[2].to_i,
            multiplayer: mp,
            observer: observer_text?(st)
          }
        elsif (m = OBSERVER_HEAD_YEAR_RE.match(core))
          st = m[2].strip
          return {
            phase: GamePhase::IN_GAME,
            status: st,
            country: nil,
            year: m[1].to_i,
            multiplayer: mp,
            observer: observer_text?(st)
          }
        end
      end

      # 2. Fallback for raw token-style Steam Rich Presence keys (#playing + COUNTRY/YEAR/STATUS)
      d_lower = display.downcase
      country = norm["country"].to_s
      year_s  = norm["year"].to_s
      year    = year_s.match?(/\A\d{3,4}\z/) ? year_s.to_i : nil

      phase = case d_lower
              when "#main_menu" then GamePhase::MAIN_MENU
              when "#in_lobby"  then GamePhase::LOBBY
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
        status: status_raw.empty? ? nil : status_raw,
        multiplayer: d_lower.end_with?("_mp"),
        observer: d_lower.include?("observer")
      }
    end

    def self.playing_result(country, year, status, mp)
      st = status.to_s.strip
      {
        phase: GamePhase::IN_GAME,
        status: st.empty? ? nil : st,
        country: country.to_s.strip,
        year: year.to_i,
        multiplayer: mp,
        observer: false
      }
    end

    def self.observer_text?(text)
      lower = text.to_s.downcase
      OBSERVER_KEYWORDS.any? { |kw| lower.include?(kw) }
    end

    def self.clean_pdx_text(str)
      s = str.to_s.dup
      s.gsub!(/#[a-zA-Z0-9_]+\s*/, "") unless s.start_with?("#main_menu", "#in_lobby", "#playing")
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

    def poll
      unless ProcessWatcher.eu5_running?
        disconnect if @connected
        return nil
      end

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

      # Scope our passive Steam IPC pipe to Europa Universalis V so ISteamFriends
      # returns EU5's active Rich Presence keys without calling SteamAPI_Init.
      ENV["SteamAppId"]  = Steam::EU5_APP_ID
      ENV["SteamGameId"] = Steam::EU5_APP_ID

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
        fn = vtable_fn(u_vt, VT_USER_GET_STEAM_ID, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
        out = [0].pack("Q")
        fn.call(steam_user, out)
        out.unpack1("Q")
      else
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
