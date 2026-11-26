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
end
