#!/usr/bin/env ruby
# frozen_string_literal: true

# Population projection models that scale a starting population to a target
# value — by default, Iran's 93.2 million (2026) toward 10 billion.
#
# Units
#   All library values are in MILLIONS of people. The CLI renders them as
#   "M" / "B" strings for readability.
#
# Models
#   Every model is calibrated so that P(0) = start and P(T) = target, which
#   means they all share the same compound annual growth rate (CAGR) over the
#   horizon:
#
#     CAGR = (target / start)^(1/T) - 1
#
#   They differ in the path taken and in the annual growth rate at a given
#   moment:
#
#     exponential  P(t) = P0 * (1 + r)^t                  constant r = CAGR
#     declining    r(t) = r0 * (1 - t/T)                  linear taper to 0
#                  P(t) = P0 * exp(r0 * (t - t^2/(2T))),  r0 = 2*ln(target/P0)/T
#     logistic     P(t) = K / (1 + A * e^(-r*t))          S-curve toward cap K
#                  A = (K - P0)/P0,  r = ln(target*A/(K - target)) / T
#
# Usage
#   ruby population_projection.rb --help
#   ruby population_projection.rb                          # default report
#   ruby population_projection.rb --years 50 --model logistic
#   ruby population_projection.rb --csv > projection.csv

require "optparse"

module Iran
  module PopulationProjection
    # Compound annual growth rate from one population level to another.
    def self.cagr(start_population, target_population, years)
      (target_population / start_population)**(1.0 / years) - 1.0
    end

    # Number of years needed to compound from start to target at +rate+.
    def self.years_to_target(rate, start_population:, target_population:)
      Math.log(target_population / start_population) / Math.log1p(rate)
    end

    # Rendering helpers shared by the models and the CLI.
    module Format
      module_function

      # Millions of people -> "93.2 M", "10.000 B", or "1.33e+06 T".
      def population(millions)
        if millions >= 1_000_000
          format("%.3g T", millions / 1_000_000.0)
        elsif millions >= 1_000
          format("%.3f B", millions / 1_000.0)
        else
          format("%.1f M", millions)
        end
      end

      # A growth rate -> "4.79%" (extra precision below 0.01%).
      def percent(rate)
        return "0.00%" if rate.zero?

        pct = rate * 100.0
        pct.abs < 0.01 ? format("%.4f%%", pct) : format("%.2f%%", pct)
      end
    end

    # Shared argument checks for the projection models.
    module Validation
      private

      def validate_horizon!(start_population, target_population, years)
        raise ArgumentError, "start_population must be positive" unless start_population.positive?
        raise ArgumentError, "target_population must be greater than start_population" unless target_population > start_population
        raise ArgumentError, "years must be positive" unless years.positive?
      end
    end

    # Constant compound growth: P(t) = P0 * (1 + r)^t, with r = CAGR.
    class Exponential
      include Validation

      attr_reader :start_population, :target_population, :years

      def initialize(start_population:, target_population:, years:)
        @start_population = Float(start_population)
        @target_population = Float(target_population)
        @years = Float(years)
        validate!
      end

      def key = "exponential"

      # Discrete annualized rate (CAGR); growth_rate_at is constant.
      def annual_rate
        PopulationProjection.cagr(start_population, target_population, years)
      end
      alias average_rate annual_rate

      # Continuous ("force of growth") rate: ln(P_T / P_0) / T.
      def continuous_rate
        Math.log(target_population / start_population) / years
      end

      def population_at(year)
        start_population * (1.0 + annual_rate)**Float(year)
      end

      def growth_rate_at(_year)
        annual_rate
      end

      private

      def validate!
        validate_horizon!(start_population, target_population, years)
      end
    end

    # Growth rate tapers linearly from r0 to 0 over the horizon:
    #   r(t) = r0 * (1 - t/T)
    #   P(t) = P0 * exp(r0 * (t - t^2/(2T))),  r0 = 2 * ln(target/P0) / T
    class Declining
      include Validation

      attr_reader :start_population, :target_population, :years

      def initialize(start_population:, target_population:, years:)
        @start_population = Float(start_population)
        @target_population = Float(target_population)
        @years = Float(years)
        validate!
      end

      def key = "declining"

      def initial_rate
        2.0 * Math.log(target_population / start_population) / years
      end

      def final_rate = 0.0

      # Average rate over the whole horizon equals the CAGR.
      def average_rate
        PopulationProjection.cagr(start_population, target_population, years)
      end

      def population_at(year)
        t = Float(year)
        start_population * Math.exp(initial_rate * (t - t**2 / (2.0 * years)))
      end

      def growth_rate_at(year)
        initial_rate * (1.0 - Float(year) / years)
      end

      private

      def validate!
        validate_horizon!(start_population, target_population, years)
      end
    end

    # Logistic (S-curve) growth toward a carrying capacity K:
    #   P(t) = K / (1 + A * e^(-r*t)),  A = (K - P0) / P0
    # r is chosen so the curve passes through the target at the horizon:
    #   r = ln(target * A / (K - target)) / T,  requires K > target.
    class Logistic
      include Validation

      DEFAULT_CAPACITY_FACTOR = 1.2

      attr_reader :start_population, :target_population, :years, :capacity

      def initialize(start_population:, target_population:, years:, capacity: nil)
        @start_population = Float(start_population)
        @target_population = Float(target_population)
        @years = Float(years)
        @capacity = Float(capacity || target_population * DEFAULT_CAPACITY_FACTOR)
        validate!
      end

      def key = "logistic"

      def shape_rate
        Math.log(target_population * coefficient / (capacity - target_population)) / years
      end

      def population_at(year)
        capacity / (1.0 + coefficient * Math.exp(-shape_rate * Float(year)))
      end

      def growth_rate_at(year)
        shape_rate * (1.0 - population_at(year) / capacity)
      end

      def average_rate
        PopulationProjection.cagr(start_population, target_population, years)
      end

      private

      def coefficient
        (capacity - start_population) / start_population
      end

      def validate!
        validate_horizon!(start_population, target_population, years)
        raise ArgumentError, "capacity must be greater than target_population" unless capacity > target_population
      end
    end

    # Command-line report (also exercised by the test suite).
    module CLI
      DEFAULTS = {
        start: 93.2,
        target: 10_000.0,
        years: 100.0,
        base_year: 2026,
        model: "all",
        capacity: nil,
        rows: 11,
        csv: false
      }.freeze

      HORIZONS = [25, 50, 75, 100, 150, 200].freeze

      # Reference rates used for the "how long would it take" table; 0.5-1.0%
      # brackets recent estimates of Iran's actual annual growth (~0.7% in 2024).
      REFERENCE_RATES = [0.005, 0.007, 0.01, 0.015, 0.02, 0.03].freeze

      def self.run(argv, out: $stdout)
        options = parse(argv, out)

        models = [
          Exponential.new(start_population: options[:start], target_population: options[:target], years: options[:years]),
          Declining.new(start_population: options[:start], target_population: options[:target], years: options[:years]),
          Logistic.new(start_population: options[:start], target_population: options[:target], years: options[:years], capacity: options[:capacity])
        ]

        options[:csv] ? write_csv(out, options, models) : report(out, options, models)
        0
      rescue ArgumentError => e
        warn "error: #{e.message}"
        1
      end

      def self.parse(argv, out)
        options = DEFAULTS.dup
        parser = OptionParser.new do |o|
          o.banner = "Usage: ruby population_projection.rb [options]"
          o.separator ""
          o.separator "Projects a population from --start to --target and reports the"
          o.separator "annualized growth rates and year-by-year trajectories involved."
          o.separator ""
          o.on("--start MILLIONS", Float, "Starting population in millions (default: #{DEFAULTS[:start]})") { |v| options[:start] = v }
          o.on("--target MILLIONS", Float, "Target population in millions (default: #{DEFAULTS[:target]})") { |v| options[:target] = v }
          o.on("--years N", Float, "Projection horizon in years (default: #{DEFAULTS[:years].to_i})") { |v| options[:years] = v }
          o.on("--base-year YEAR", Integer, "Calendar year of the starting population (default: #{DEFAULTS[:base_year]})") { |v| options[:base_year] = v }
          o.on("--model NAME", %w[exponential declining logistic all],
               "Model to show: exponential, declining, logistic, all (default: all)") { |v| options[:model] = v }
          o.on("--capacity MILLIONS", Float, "Logistic carrying capacity in millions (default: 1.2x target)") { |v| options[:capacity] = v }
          o.on("--rows N", Integer, "Rows in the report tables (default: #{DEFAULTS[:rows]})") { |v| options[:rows] = v }
          o.on("--csv", "Emit every projected year for all models as CSV") { options[:csv] = true }
          o.on("-h", "--help", "Show this help") do
            out.puts o
            exit 0
          end
        end
        parser.parse(argv)
        validate_options!(options)
        options
      rescue OptionParser::ParseError => e
        warn e.message
        warn parser
        exit 1
      end

      def self.validate_options!(options)
        raise OptionParser::InvalidArgument, "--start must be positive" unless options[:start].positive?
        raise OptionParser::InvalidArgument, "--target must be greater than --start" unless options[:target] > options[:start]
        raise OptionParser::InvalidArgument, "--years must be positive" unless options[:years].positive?
        raise OptionParser::InvalidArgument, "--rows must be at least 2" if options[:rows] < 2
        if options[:capacity] && options[:capacity] <= options[:target]
          raise OptionParser::InvalidArgument, "--capacity must be greater than --target"
        end
      end

      def self.report(out, options, models)
        start = options[:start]
        target = options[:target]
        years = options[:years]
        base_year = options[:base_year]
        end_year = base_year + years.round

        display = models.select { |m| options[:model] == "all" || m.key == options[:model] }

        out.puts "Population projection: #{Format.population(start)} (#{base_year}) -> #{Format.population(target)}"
        out.puts format("%.2fx growth over %g years. All models land exactly on %s in %d; they",
                        target / start, years, Format.population(target), end_year)
        out.puts "differ only in the path taken and in the annual growth rate over time."
        out.puts

        out.puts "Compound annual growth rate (CAGR) by horizon"
        out.puts format("  %8s  %10s  %12s", "years", "CAGR", "continuous")
        (HORIZONS.map(&:to_f) + [years]).uniq.sort.each do |horizon|
          rate = PopulationProjection.cagr(start, target, horizon)
          note = horizon == years ? "  <- selected horizon" : ""
          out.puts format("  %8g  %10s  %12s%s", horizon, Format.percent(rate), Format.percent(Math.log1p(rate)), note)
        end
        out.puts

        row_years = sample_years(years, options[:rows])

        out.puts "Population by model"
        out.puts format("  %6s  %6s", "year", "cal.") + display.map { |m| format("  %14s", m.key) }.join
        row_years.each do |t|
          out.puts format("  %6d  %6d", t, base_year + t) +
                   display.map { |m| format("  %14s", Format.population(m.population_at(t))) }.join
        end
        out.puts

        out.puts "Annual growth rate in each year"
        out.puts format("  %6s  %6s", "year", "cal.") + display.map { |m| format("  %14s", m.key) }.join
        row_years.each do |t|
          out.puts format("  %6d  %6d", t, base_year + t) +
                   display.map { |m| format("  %14s", Format.percent(m.growth_rate_at(t))) }.join
        end
        out.puts

        out.puts "Key rates"
        display.each do |model|
          detail =
            case model.key
            when "exponential"
              "constant #{Format.percent(model.annual_rate)}/yr"
            when "declining"
              "#{Format.percent(model.growth_rate_at(0))}/yr falling to 0.00%/yr by #{end_year}"
            when "logistic"
              "#{Format.percent(model.growth_rate_at(0))}/yr falling to " \
                "#{Format.percent(model.growth_rate_at(years))}/yr by #{end_year} " \
                "(capacity #{Format.population(model.capacity)})"
            end
          out.puts format("  %-12s %s", model.key, detail)
        end
        out.puts

        out.puts "Years to reach #{Format.population(target)} at a fixed annual growth rate"
        REFERENCE_RATES.each do |rate|
          n = PopulationProjection.years_to_target(rate, start_population: start, target_population: target)
          note = rate == 0.007 ? "   # close to Iran's recent rate" : ""
          out.puts format("  %6s/yr -> %5.0f years (arrival around %d)%s", Format.percent(rate), n, base_year + n.round, note)
        end
      end

      def self.write_csv(out, options, models)
        out.puts "model,year,calendar_year,population_millions,growth_rate"
        (0..options[:years].round).each do |t|
          models.each do |model|
            out.puts [
              model.key,
              t,
              options[:base_year] + t,
              format("%.6f", model.population_at(t)),
              format("%.8f", model.growth_rate_at(t))
            ].join(",")
          end
        end
      end

      # Evenly spaced elapsed years, always including 0 and the full horizon.
      def self.sample_years(years, rows)
        count = [rows, 2].max
        step = years / (count - 1)
        (0...count).map { |i| (step * i).round }.uniq
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit Iran::PopulationProjection::CLI.run(ARGV)
end
