#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "population_projection"

class PopulationProjectionTest < Minitest::Test
  START = 93.2
  TARGET = 10_000.0
  YEARS = 100.0

  def build(klass, overrides = {})
    defaults = { start_population: START, target_population: TARGET, years: YEARS }
    klass.new(**defaults.merge(overrides))
  end

  def every_model
    [
      build(Iran::PopulationProjection::Exponential),
      build(Iran::PopulationProjection::Declining),
      build(Iran::PopulationProjection::Logistic)
    ].each { |model| yield model }
  end

  def test_every_model_starts_and_finishes_on_the_endpoints
    every_model do |model|
      assert_in_delta START, model.population_at(0), 1e-6
      assert_in_delta TARGET, model.population_at(YEARS), 1e-6
    end
  end

  def test_every_model_shares_the_same_cagr
    expected = Iran::PopulationProjection.cagr(START, TARGET, YEARS)
    every_model do |model|
      assert_in_delta expected, model.average_rate, 1e-12
    end
  end

  def test_cagr_matches_textbook_example
    # 100 -> 400 over 2 years doubles every year.
    assert_in_delta 1.0, Iran::PopulationProjection.cagr(100, 400, 2), 1e-12
  end

  def test_exponential_matches_hand_calculation
    model = build(Iran::PopulationProjection::Exponential)
    assert_in_delta 0.047866, model.annual_rate, 1e-6
    # Halfway through a constant-CAGR path the population is sqrt of the ratio.
    assert_in_delta START * (TARGET / START)**0.5, model.population_at(50), 1e-9
  end

  def test_declining_rate_tapers_linearly_to_zero
    model = build(Iran::PopulationProjection::Declining)
    assert_in_delta 0.0, model.growth_rate_at(YEARS), 1e-12
    assert_in_delta model.initial_rate / 2, model.growth_rate_at(YEARS / 2), 1e-12
  end

  def test_logistic_is_monotonic_and_stays_below_capacity
    model = build(Iran::PopulationProjection::Logistic)
    previous = 0.0
    (0..100).each do |year|
      population = model.population_at(year)
      assert population > previous, "logistic population should grow every year"
      assert population < model.capacity, "logistic population should stay below capacity"
      previous = population
    end
  end

  def test_logistic_respects_a_custom_capacity
    model = build(Iran::PopulationProjection::Logistic, capacity: 11_000.0)
    assert_in_delta 11_000.0, model.capacity, 1e-9
    assert_in_delta TARGET, model.population_at(YEARS), 1e-6
  end

  def test_years_to_target_inverts_compound_growth
    rate = 0.0123
    years = Iran::PopulationProjection.years_to_target(rate, start_population: START, target_population: TARGET)
    assert_in_delta TARGET, START * (1.0 + rate)**years, 1e-6
  end

  def test_models_reject_impossible_inputs
    assert_raises(ArgumentError) { build(Iran::PopulationProjection::Exponential, start_population: 0) }
    assert_raises(ArgumentError) { build(Iran::PopulationProjection::Declining, target_population: 50.0) }
    assert_raises(ArgumentError) { build(Iran::PopulationProjection::Logistic, years: 0) }
    assert_raises(ArgumentError) { build(Iran::PopulationProjection::Logistic, capacity: 500.0) }
  end

  def test_formatting_helpers
    format = Iran::PopulationProjection::Format
    assert_equal "93.2 M", format.population(93.2)
    assert_equal "10.000 B", format.population(10_000)
    assert_equal "4.79%", format.percent(0.047866)
  end

  def test_cli_renders_the_default_report
    out = StringIO.new
    assert_equal 0, Iran::PopulationProjection::CLI.run([], out: out)
    assert_includes out.string, "10.000 B"
    assert_includes out.string, "CAGR"
    assert_includes out.string, "exponential"
    assert_includes out.string, "declining"
    assert_includes out.string, "logistic"
  end

  def test_cli_can_focus_a_single_model
    out = StringIO.new
    assert_equal 0, Iran::PopulationProjection::CLI.run(["--model", "logistic"], out: out)
    assert_includes out.string, "logistic"
    refute_includes out.string, "constant 4.79%/yr"
  end

  def test_cli_emits_csv_for_every_year
    out = StringIO.new
    assert_equal 0, Iran::PopulationProjection::CLI.run(["--csv", "--years", "10"], out: out)
    lines = out.string.lines
    assert_equal "model,year,calendar_year,population_millions,growth_rate\n", lines.first
    # 3 models * 11 years.
    assert_equal 33, lines.size - 1
    assert_includes out.string, "exponential,10,2036"
  end

  def test_sample_years_always_span_the_horizon
    assert_equal (0..100).step(10).to_a, Iran::PopulationProjection::CLI.sample_years(100.0, 11)
    assert_equal [0, 100], Iran::PopulationProjection::CLI.sample_years(100.0, 2)
  end
end
