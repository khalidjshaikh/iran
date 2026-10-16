#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tempfile"
require_relative "annualized"

class AnnualizedTest < Minitest::Test
  A = Iran::Annualized
  Projection = Iran::PopulationProjection

  def run_cli(*argv)
    out = StringIO.new
    status = A.run(argv, out: out)
    assert_equal 0, status, "command #{argv.inspect} failed"
    out.string
  end

  def exponential(years)
    Projection::Exponential.new(start_population: 93.2, target_population: 10_000.0, years: years)
  end

  # -- rate functions and simulation -------------------------------------------

  def test_rate_function_constant
    rate_at = A.rate_function(initial_rate: 0.05)
    assert_in_delta 0.05, rate_at.call(0), 1e-12
    assert_in_delta 0.05, rate_at.call(123), 1e-12
  end

  def test_rate_function_drop_floors_at_zero
    # The rule value is in percentage points, so 1.0 means 1 pp per year.
    rate_at = A.rate_function(initial_rate: 0.05, rule: [:drop, 1.0])
    assert_in_delta 0.05, rate_at.call(0), 1e-12
    assert_in_delta 0.03, rate_at.call(2), 1e-12
    assert_in_delta 0.0, rate_at.call(10), 1e-12
  end

  def test_rate_function_half_life
    rate_at = A.rate_function(initial_rate: 0.08, rule: [:half, 20.0])
    assert_in_delta 0.08, rate_at.call(0), 1e-12
    assert_in_delta 0.04, rate_at.call(20), 1e-12
    assert_in_delta 0.02, rate_at.call(40), 1e-12
  end

  def test_simulate_constant_required_rate_arrives_at_the_horizon
    rate = Projection.cagr(93.2, 10_000.0, 100)
    simulation = A.simulate(start_population: 93.2, rate_at: A.rate_function(initial_rate: rate),
                            target_population: 10_000.0, max_years: 200)
    assert_in_delta 100, simulation.arrival_year, 1
    assert_in_delta 10_000.0, simulation.series[100], 1.0
  end

  def test_simulate_drop_schedule_stalls_below_the_target
    rate = Projection.cagr(93.2, 10_000.0, 100)
    simulation = A.simulate(start_population: 93.2,
                            rate_at: A.rate_function(initial_rate: rate, rule: [:drop, 0.10]),
                            target_population: 10_000.0, max_years: 500)
    assert_nil simulation.arrival_year
    assert_operator simulation.final_population, :<, 400
    assert_operator simulation.final_population, :>, 250
  end

  def test_simulate_half_life_schedule_arrives_eventually
    simulation = A.simulate(start_population: 93.2,
                            rate_at: A.rate_function(initial_rate: 0.12, rule: [:half, 30.0]),
                            target_population: 10_000.0, max_years: 500)
    assert simulation.arrival_year
    assert_operator simulation.arrival_year, :>, 100
    assert_operator simulation.arrival_year, :<, 200
  end

  # -- trajectory rows ----------------------------------------------------------

  def test_trajectory_row_rates_are_all_equal_for_exponential
    model = exponential(100)
    row = A.trajectory_row(model, 50, 100, 10)
    assert_in_delta model.annual_rate, row.segment_rate, 1e-9
    assert_in_delta model.annual_rate, row.cagr_to_date, 1e-9
    assert_in_delta model.annual_rate, row.remaining_rate, 1e-9
  end

  def test_trajectory_row_edges_are_undefined
    model = exponential(100)
    first = A.trajectory_row(model, 0, 100, 10)
    assert_nil first.segment_rate
    assert_nil first.cagr_to_date
    assert_nil A.trajectory_row(model, 100, 100, 10).remaining_rate
  end

  def test_trajectory_rates_decline_for_logistic
    model = Projection::Logistic.new(start_population: 93.2, target_population: 10_000.0, years: 100)
    early = A.trajectory_row(model, 10, 100, 10)
    late = A.trajectory_row(model, 100, 100, 10)
    assert_operator late.segment_rate, :<, early.segment_rate
    assert_in_delta 10_000.0, late.population, 1e-6
  end

  # -- windows and CSV parsing --------------------------------------------------

  def test_windows_absorbs_the_remainder_into_the_final_window
    points = [[2026, 93.2], [2036, 148.8], [2126, 10_000.0]]
    assert_equal [[[2026, 93.2], [2036, 148.8]], [[2036, 148.8], [2126, 10_000.0]]],
                 A.windows(points, 10)
  end

  def test_annualized_between_recovers_a_constant_rate
    model = exponential(100)
    rate = A.annualized_between([2026, 93.2], [2036, model.population_at(10)])
    assert_in_delta model.annual_rate, rate, 1e-9
    assert_nil A.annualized_between([2026, 93.2], [2026, 93.2])
  end

  def test_parse_csv_plain_two_columns_without_header
    file = Tempfile.new(["plain", ".csv"])
    file.write("2026,100\n2027,110\n2028,121\n")
    file.close
    assert_equal({ nil => [[2026, 100.0], [2027, 110.0], [2028, 121.0]] }, A.parse_csv(file.path))
  ensure
    file&.unlink
  end

  def test_parse_csv_accepts_projection_output_and_filters_models
    out = StringIO.new
    Projection::CLI.run(["--csv", "--years", "2"], out: out)
    file = Tempfile.new(["projection", ".csv"])
    file.write(out.string)
    file.close
    groups = A.parse_csv(file.path, model_filter: "logistic")
    assert_equal ["logistic"], groups.keys
    assert_equal [2026, 2027, 2028], groups["logistic"].map(&:first)
    assert_in_delta 93.2, groups["logistic"].first[1], 1e-9
    assert_in_delta 10_000.0, groups["logistic"].last[1], 1e-6
  ensure
    file&.unlink
  end

  # -- CLI commands ---------------------------------------------------------------

  def test_solve_default_reports_the_required_rate
    out = run_cli("solve")
    assert_includes out, "4.79%/yr"
    assert_includes out, "14.8 years"
    assert_includes out, "2126"
  end

  def test_solve_rate_reports_years_to_target
    out = run_cli("solve", "--rate", "4.0")
    assert_includes out, "119.2"
    assert_includes out, "2145"
    assert_includes out, "4.707 B"
  end

  def test_sweep_marks_cells_that_reach_the_target
    out = run_cli("sweep", "--rates", "5", "--horizons", "100")
    assert_includes out, "12.256 B*"
    assert_includes out, "years to target"
  end

  def test_trajectory_table_and_csv
    table = run_cli("trajectory", "--years", "20", "--step", "10")
    assert_includes table, "needed to 2046"
    assert_includes table, "CAGR since 2026"
    csv = run_cli("trajectory", "--csv", "--years", "10")
    lines = csv.lines
    assert_equal "model,year,calendar_year,population_millions,segment_rate,cagr_to_date,rate_needed_remaining\n", lines.first
    assert_equal 11, lines.size - 1
    assert_includes csv, "exponential,10,2036"
  end

  def test_schedule_presets_and_custom_schedule
    presets = run_cli("schedule")
    assert_includes presets, "constant required CAGR"
    assert_includes presets, "not within 500 yr"
    custom = run_cli("schedule", "--initial", "6", "--half-life", "30")
    assert_includes custom, "halving every 30 yr"
    assert_includes custom, "arrival:"
  end

  def test_schedule_csv_mode
    out = run_cli("schedule", "--initial", "8", "--drop", "0.05", "--csv")
    lines = out.lines
    assert_equal "year,calendar_year,rate,population_millions\n", lines.first
    assert_operator lines.size, :>, 10
    assert_includes out, "0,2026,0.08000000,93.200000"
  end

  def test_annualize_integration_with_projection_csv
    io = StringIO.new
    Projection::CLI.run(["--csv", "--years", "20", "--model", "exponential"], out: io)
    file = Tempfile.new(["projection", ".csv"])
    file.write(io.string)
    file.close
    model = exponential(20)
    expected = Projection::Format.population(model.population_at(20))
    out = run_cli("annualize", file.path, "--window", "10")
    assert_includes out, "model: exponential"
    assert_includes out, "overall: 93.2 M (2026) -> #{expected} (2046)"
    assert_includes out, Projection::Format.percent(model.annual_rate)
    assert_includes out, "10 yr"
    assert_includes out, "2036"
  ensure
    file&.unlink
  end

  def test_annualize_plain_csv_reports_windows
    file = Tempfile.new(["plain", ".csv"])
    file.write("year,population\n2026,100\n2036,200\n")
    file.close
    out = run_cli("annualize", file.path, "--window", "5")
    assert_includes out, "7.18%"
  ensure
    file&.unlink
  end

  def test_format_gained_a_trillion_tier
    assert_equal "1.5 T", Projection::Format.population(1_500_000)
    assert_equal "10.000 B", Projection::Format.population(10_000)
  end
end
