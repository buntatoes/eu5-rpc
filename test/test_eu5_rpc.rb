# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/eu5_rpc"

class TestEu5Rpc < Minitest::Test
  def test_toml_and_config_defaults
    parsed = Eu5Rpc::Toml.parse(Eu5Rpc::ConfigManager::DEFAULT_TOML)
    assert_equal true, parsed.dig("general", "launch_game_on_start")
    assert_equal 1000, parsed.dig("general", "poll_interval_ms")
    assert_equal "Playing as {country} ({year})", parsed.dig("presence", "status", "in_game_with_country")

    dumped = Eu5Rpc::Toml.dump(parsed)
    assert_equal parsed, Eu5Rpc::Toml.parse(dumped)
  end

  def test_historical_ages
    assert_equal "Age of Traditions", Eu5Rpc::HistoricalAge.for_year(1337)
    assert_equal "Age of Renaissance", Eu5Rpc::HistoricalAge.for_year(1453)
    assert_equal "Age of Discovery", Eu5Rpc::HistoricalAge.for_year(1550)
    assert_equal "Age of Reformation", Eu5Rpc::HistoricalAge.for_year(1648)
    assert_equal "Age of Absolutism", Eu5Rpc::HistoricalAge.for_year(1750)
    assert_equal "Age of Revolutions", Eu5Rpc::HistoricalAge.for_year(1837)
    assert_nil Eu5Rpc::HistoricalAge.for_year(1200)
  end

  def test_save_inspector_parses_filename_and_header
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "continue_game.json"), '{"rawGameVersion":"1.4.7"}')
      saves = File.join(dir, "save games")
      Dir.mkdir(saves)
      sample_save = File.join(saves, "SP_FRA_1453_05_29_00000000-0000-0000-0000-000000000000.eu5")
      File.binwrite(sample_save, "SAV0303\x00\x011453.5.29 - France #112233\x001.4.7\x00FRA={\n}\n")

      meta = Eu5Rpc::SaveInspector.inspect_user_data_dir(dir)
      assert_equal "France", meta.country_name
      assert_equal "FRA", meta.country_tag
      assert_equal 1453, meta.year
      assert_equal "1453.5.29", meta.date_str
      assert_equal false, meta.multiplayer
      assert_equal "1.4.7", meta.game_version
    end
  end

  def test_log_watcher_transitions_and_live_events
    state = Eu5Rpc::GameState.new
    cfg = Eu5Rpc::Config.new

    Eu5Rpc::LogWatcher.process_debug_line("[14:55:33][pdx_transition_task.cpp:138]: Running Transition Empty->SplashScreen", state)
    assert_equal Eu5Rpc::GamePhase::LOADING, state.phase

    Eu5Rpc::LogWatcher.process_debug_line("[14:55:35][dlc_reloadable.cpp:390]: Mod Sample version 1.4.* successfully matched game version 1.4.7.", state)
    assert_equal "1.4.7", state.game_version

    Eu5Rpc::LogWatcher.process_debug_line("[14:55:38][pdx_transition_task.cpp:138]: Running Transition LoadingScreen->MainMenu", state)
    assert_equal Eu5Rpc::GamePhase::MAIN_MENU, state.phase

    Eu5Rpc::LogWatcher.process_debug_line("[14:55:48][pdx_transition_task.cpp:138]: Running Transition MainMenu->Game", state)
    assert_equal Eu5Rpc::GamePhase::IN_GAME, state.phase

    state.country_name = "France"
    state.country_tag = "FRA"
    state.year = 1453

    Eu5Rpc::LogWatcher.process_multiplayer_line("Is Multiplayer: true", state)
    Eu5Rpc::LogWatcher.process_multiplayer_line("Is Multiplayer Host: true", state)
    assert_equal "Multiplayer (Host)", state.mode_label

    Eu5Rpc::LogWatcher.process_game_line("[16:17:52][gamestate.cpp:1005]: NEW YEAR: 1454", state)
    assert_equal 1454, state.year

    Eu5Rpc::LogWatcher.process_game_line("[16:18:05][diplomatic_action_war.cpp:482]: WAR: France declared war on Burgundy", state)
    assert_equal "At War with Burgundy", state.active_event

    details, status_line = state.format_presence(cfg.presence)
    assert_equal "Playing as France (1454)", details
    assert_equal "At War with Burgundy · Multiplayer (Host) · v1.4.7", status_line

    Eu5Rpc::LogWatcher.process_game_line("[16:18:25][country.cpp:6312]: DISASTER: succession_crisis starts in FRA", state)
    assert_equal "Disaster: Succession Crisis", state.active_event

    Eu5Rpc::LogWatcher.process_game_line("[16:18:25][country.cpp:6312]: DISASTER: succession_crisis ends in FRA", state)
    assert_nil state.active_event

    Eu5Rpc::LogWatcher.process_debug_line("[16:18:39][pdx_transition_task.cpp:138]: Running Transition SplashScreen->Empty", state)
    assert_equal Eu5Rpc::GamePhase::NOT_RUNNING, state.phase
  end

  def test_native_process_watcher
    expected_self = Gem.win_platform? ? "ruby.exe" : "ruby"
    assert_equal true, Eu5Rpc::ProcessWatcher.process_running?(expected_self)
    assert_equal false, Eu5Rpc::ProcessWatcher.process_running?("definitely_not_running_eu5_99999.exe")
  end

  def test_default_discord_app_id_and_payload
    assert_equal "1435327845051400292", Eu5Rpc::DEFAULT_DISCORD_APP_ID
    cfg = Eu5Rpc::Config.new
    payload = Eu5Rpc::DiscordIpcClient.build_activity_payload(
      details: "Playing as France (1454)",
      state: "Age of Renaissance · Singleplayer · v1.4.7",
      start_time: 1_700_000_000,
      img_cfg: cfg.images
    )
    assert_equal "Playing as France (1454)", payload["details"]
    assert_equal "https://raw.githubusercontent.com/buntatoes/eu5-rpc/main/assets/icon.png", payload.dig("assets", "large_image")
  end

  def test_country_lookup_and_live_multiplayer_country_selection
    Dir.mktmpdir do |dir|
      loc_dir = File.join(dir, "game", "main_menu", "localization", "english")
      FileUtils.mkdir_p(loc_dir)
      File.write(
        File.join(loc_dir, "country_names_l_english.yml"),
        "l_english:\n POR: \"Portugal\"\n CUSTOM: \"Custom Empire\"\n"
      )

      lookup = Eu5Rpc::CountryLookup.new(dir)
      assert_equal "Portugal", lookup.resolve("POR")
      assert_equal "Custom Empire", lookup.resolve("CUSTOM")
      assert_nil lookup.resolve("No")

      state = Eu5Rpc::GameState.new
      Eu5Rpc::LogWatcher.process_multiplayer_line("New Country: POR", state, lookup)
      assert_equal "POR", state.country_tag
      assert_equal "Portugal", state.country_name
      assert_equal Eu5Rpc::GamePhase::IN_GAME, state.phase

      Eu5Rpc::LogWatcher.process_game_line("[17:54:09][situation_manager.cpp:384]: SITUATION: Rise of the Turks starts on 1 May, 1337", state)
      assert_equal 1337, state.year

      cfg = Eu5Rpc::Config.new
      details, _status = state.format_presence(cfg.presence)
      assert_equal "Playing as Portugal (1337)", details
    end
  end

  def test_steam_rich_presence_dynamic_country_swap
    state = Eu5Rpc::GameState.new
    state.game_version = "1.4.9"
    cfg = Eu5Rpc::Config.new

    # Start playing as Principality of Kyiv (real EU5 formatted Steam Rich Presence string)
    rp1 = Eu5Rpc::SteamRichPresence.parse_presence_hash(
      "status" => "Tributary under the Golden Horde as Principality of Kyiv, 1337",
      "steam_display" => "Tributary under the Golden Horde as Principality of Kyiv, 1337"
    )
    state.apply_steam_rich_presence(rp1)
    details1, status1 = state.format_presence(cfg.presence)
    assert_equal "Playing as Principality of Kyiv (1337)", details1
    assert_equal "Tributary under the Golden Horde · Singleplayer · v1.4.9", status1

    # Dynamically swap countries mid-game to Byzantium at war in Multiplayer
    rp2 = Eu5Rpc::SteamRichPresence.parse_presence_hash(
      "status" => "At war against Ottomans as Byzantium, 1345 (Multiplayer)"
    )
    state.apply_steam_rich_presence(rp2)
    details2, status2 = state.format_presence(cfg.presence)
    assert_equal "Playing as Byzantium (1345)", details2
    assert_equal "At war against Ottomans · Multiplayer · v1.4.9", status2

    # Lobby and Main Menu strings
    rp_lobby = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "In Lobby")
    state.apply_steam_rich_presence(rp_lobby)
    assert_equal Eu5Rpc::GamePhase::LOBBY, state.phase

    rp3 = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "In Main Menu")
    state.apply_steam_rich_presence(rp3)
    assert_equal Eu5Rpc::GamePhase::MAIN_MENU, state.phase
    assert_nil state.country_name
  end

  def test_steam_rich_presence_non_english_languages
    # French
    fr = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "En guerre contre l'Angleterre en tant que France, 1340 (multijoueur)")
    assert_equal "France", fr[:country]
    assert_equal 1340, fr[:year]
    assert_equal "En guerre contre l'Angleterre", fr[:status]
    assert_equal true, fr[:multiplayer]

    # German
    de = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "Herrscht über das Reich als Österreich, 1453 (Mehrspieler)")
    assert_equal "Österreich", de[:country]
    assert_equal 1453, de[:year]
    assert_equal true, de[:multiplayer]

    # Spanish
    es = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "En guerra contra Granada como Castilla, 1444")
    assert_equal "Castilla", es[:country]
    assert_equal 1444, es[:year]
    assert_equal "En guerra contra Granada", es[:status]

    # Brazilian Portuguese
    pt = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "Falência como Portugal, 1500 (Multijogador)")
    assert_equal "Portugal", pt[:country]
    assert_equal 1500, pt[:year]
    assert_equal "Falência", pt[:status]
    assert_equal true, pt[:multiplayer]

    # Polish
    pl = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "Rządzi królestwem jako Polska, 1410 (gra wieloosobowa)")
    assert_equal "Polska", pl[:country]
    assert_equal 1410, pl[:year]
    assert_equal true, pl[:multiplayer]

    # Russian
    ru = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "Банкрот за державу Московия, 1380\u00A0год (многопользовательская игра)")
    assert_equal "Московия", ru[:country]
    assert_equal 1380, ru[:year]
    assert_equal "Банкрот", ru[:status]
    assert_equal true, ru[:multiplayer]

    # Turkish
    tr = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "Osmanlı olarak Ülkeyi idare ediyor, 1453 (Çok Oyunculu)")
    assert_equal "Osmanlı", tr[:country]
    assert_equal 1453, tr[:year]
    assert_equal "Ülkeyi idare ediyor", tr[:status]
    assert_equal true, tr[:multiplayer]

    # Japanese
    ja = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "日本として破産、1467（マルチプレイ）")
    assert_equal "日本", ja[:country]
    assert_equal 1467, ja[:year]
    assert_equal "破産", ja[:status]
    assert_equal true, ja[:multiplayer]

    # Korean
    ko = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "1392, 조선(으)로 부도(멀티플레이어)")
    assert_equal "조선", ko[:country]
    assert_equal 1392, ko[:year]
    assert_equal "부도", ko[:status]
    assert_equal true, ko[:multiplayer]

    # Simplified Chinese
    zh = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "作为大明与元朝交战，1368年（多人游戏）")
    assert_equal "大明", zh[:country]
    assert_equal 1368, zh[:year]
    assert_equal "与元朝交战", zh[:status]
    assert_equal true, zh[:multiplayer]

    # Non-English Main Menu, Lobby, and Observer
    assert_equal Eu5Rpc::GamePhase::MAIN_MENU, Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "メインメニュー")[:phase]
    assert_equal Eu5Rpc::GamePhase::LOBBY, Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "В лобби")[:phase]
    obs = Eu5Rpc::SteamRichPresence.parse_presence_hash("status" => "世界の行く末を観測中、1444")
    assert_equal true, obs[:observer]
    assert_equal 1444, obs[:year]
  end
end
