#!/usr/bin/env ruby
# frozen_string_literal: true

# annualized.rb — annualized growth-rate tooling layered on population_projection.rb.
#
# Commands
#   solve       Annualized (CAGR) rate for a horizon, or years for a rate (closed form)
#   sweep       Grid of populations reached at rate x horizon, target cells starred
#   trajectory  Year-by-year annualized rates for a model: segment average, CAGR to
#               date, and the rate still needed to land on the target
#   schedule    Simulate rate schedules that change every year (drop / halve);
#               report the arrival year or the stalling level
#   annualize   Post-process a CSV of population by year into annualized rates
#               (overall, per window, optionally per year)
#
# Examples
#   ./annualized.rb solve --years 80
#   ./annualized.rb solve --rate 2
#   ./annualized.rb sweep --rates 1,2,4 --horizons 50,100,150
#   ./annualized.rb trajectory --model logistic --years 120
#   ./annualized.rb schedule --initial 6 --drop 0.05
#   ./population_projection.rb --csv > p.csv && ./annualized.rb annualize p.csv

require "csv"
require "optparse"
require_relative "population_projection"

module Iran
  module Annualized
    Projection = PopulationProjection
    Format = PopulationProjection::Format

    DEFAULTS = { start: 93.2, target: 10_000.0, base_year: 2026 }.freeze
    DEFAULT_YEARS = 100.0
    REFERENCE_HORIZONS = [25, 50, 75, 100, 150, 200].freeze
    DEFAULT_SWEEP_RATES = [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 15.0].freeze # percent/yr
    DEFAULT_MAX_YEARS = 500

    Simulation = Struct.new(:series, :arrival_year, :final_population, keyword_init: true)
    Row = Struct.new(:year, :population, :segment_rate, :cagr_to_date, :remaining_rate, keyword_init: true)

    # Callable annual growth rate for a schedule. A rule is nil (constant),
    # [:drop, points_per_year] or [:half, half_life_years].
    def self.rate_function(initial_rate:, rule: nil)
      case rule&.first
      when :drop
        drop = rule[1] / 100.0
        ->(t) { [initial_rate - drop * t, 0.0].max }
      when :half
        half_life = rule[1].to_f
        ->(t) { initial_rate * 0.5**(t / half_life) }
      else
        ->(_t) { initial_rate }
      end
    end

    # Discrete yearly simulation: P(t+1) = P(t) * (1 + rate_at(t)).
    def self.simulate(start_population:, rate_at:, target_population:, max_years:)
      series = [start_population]
      arrival = nil
      max_years.times do |t|
        rate = rate_at.call(t)
        raise ArgumentError, "growth rate must not be negative" if rate.negative?

        series << series.last * (1.0 + rate)
        arrival ||= t + 1 if series.last >= target_population
      end
      Simulation.new(series: series, arrival_year: arrival, final_population: series.last)
    end

    # One year of an annualized-rate trajectory for a projection model.
    # segment_rate: annualized over the previous +step+ years (per year in CSV mode)
    # cagr_to_date: annualized from the first year to this one
    # remaining_rate: constant rate needed over the remaining years to hit the target
    def self.trajectory_row(model, year, horizon, step)
      population = model.population_at(year)
      segment_years = [step, year].min
      segment_rate = year.positive? ? (population / model.population_at(year - segment_years))**(1.0 / segment_years) - 1.0 : nil
      cagr_to_date = year.positive? ? (population / model.start_population)**(1.0 / year) - 1.0 : nil
      remaining_rate = year < horizon ? (model.target_population / population)**(1.0 / (horizon - year)) - 1.0 : nil
      Row.new(year: year, population: population, segment_rate: segment_rate,
              cagr_to_date: cagr_to_date, remaining_rate: remaining_rate)
    end

    # Annualized rate between two [year, population] rows.
    def self.annualized_between(from, to)
      span = to[0] - from[0]
      return nil unless span.positive?

      (to[1] / from[1])**(1.0 / span) - 1.0
    end

    # Non-overlapping windows of at most +size+ years; the remainder is absorbed
    # into the final window so the last row is always included.
    def self.windows(points, size)
      result = []
      i = 0
      while i < points.size - 1
        j = i + 1
        j += 1 while j + 1 < points.size && points[j + 1][0] - points[i][0] <= size
        result << [points[i], points[j]]
        i = j
      end
      result
    end

    # Reads year/population data: either the tidy CSV from
    # `population_projection.rb --csv` or a plain year,population CSV.
    # Returns { model_name_or_nil => [[year, population], ...] }.
    def self.parse_csv(path, model_filter: nil)
      raw = CSV.read(path)
      raise ArgumentError, "empty CSV: #{path}" if raw.empty?

      if raw.first.all? { |cell| cell.to_s.match?(/\A-?\d+(\.\d+)?\z/) }
        header = %w[year population]
        body = raw
      else
        header = raw.first.map(&:to_s)
        body = raw[1..]
      end

      index = ->(name) { header.index(name) }
      year_index = index.call("calendar_year") || index.call("year")
      pop_index = index.call("population_millions") || index.call("population")
      model_index = index.call("model")

      raise ArgumentError, "#{path}: need a year column (calendar_year or year)" if year_index.nil?
      raise ArgumentError, "#{path}: need a population column (population_millions or population)" if pop_index.nil?

      groups = Hash.new { |hash, key| hash[key] = [] }
      body.each do |cells|
        model = model_index ? cells[model_index] : nil
        next if model_filter && model != model_filter

        groups[model] << [cells[year_index].to_i, cells[pop_index].to_f]
      end
      if groups.empty?
        raise ArgumentError, "#{path}: no rows#{model_filter ? " for model #{model_filter}" : ''}"
      end

      groups.transform_values do |points|
        points.group_by(&:first).map { |year, rows| [year, rows.last.last] }.sort
      end
    end

    COMMANDS = %w[solve sweep trajectory schedule annualize].freeze

    def self.usage
      <<~USAGE
        Usage: annualized.rb COMMAND [options]

        Annualized growth-rate tools layered on population_projection.rb.
        Defaults: #{DEFAULTS[:start]} M in #{DEFAULTS[:base_year]} -> #{DEFAULTS[:target].to_i} M target.

        Commands:
          solve       Annualized rate for a horizon, or years for a rate
          sweep       Grid of populations by rate and horizon, target cells starred
          trajectory  Annualized rates year by year (segment, CAGR, needed)
          schedule    Year-by-year rate schedules; arrival year or stalling level
          annualize   Annualized rates from a CSV of (year, population)

        Run `annualized.rb COMMAND --help` for command options.

        Examples:
          ./annualized.rb solve --years 80
          ./annualized.rb solve --rate 2
          ./annualized.rb sweep --rates 1,2,4 --horizons 50,100,150
          ./annualized.rb trajectory --model logistic --years 120
          ./annualized.rb schedule --initial 6 --drop 0.05
          ./population_projection.rb --csv > p.csv && ./annualized.rb annualize p.csv
      USAGE
    end

    def self.run(argv, out: $stdout)
      command = argv.shift
      case command
      when "solve" then Commands.solve(argv, out)
      when "sweep" then Commands.sweep(argv, out)
      when "trajectory" then Commands.trajectory(argv, out)
      when "schedule" then Commands.schedule(argv, out)
      when "annualize" then Commands.annualize(argv, out)
      when nil, "help", "-h", "--help"
        out.puts usage
        0
      else
        warn "unknown command: #{command}"
        warn usage
        1
      end
    rescue OptionParser::ParseError, ArgumentError, Errno::ENOENT => e
      warn "error: #{e.message}"
      1
    end

    # CLI commands; the math lives in the module functions above.
    module Commands
      module_function

      PRESETS = [
        { name: "constant required CAGR", rule: nil },
        { name: "required CAGR, drop 0.05 pp/yr", rule: [:drop, 0.05] },
        { name: "required CAGR, drop 0.10 pp/yr", rule: [:drop, 0.10] },
        { name: "required CAGR, halve every 20 yr", rule: [:half, 20.0] },
        { name: "8.00% initial, drop 0.05 pp/yr", rule: [:drop, 0.05], initial: 8.0 },
        { name: "8.00% initial, halve every 50 yr", rule: [:half, 50.0], initial: 8.0 }
      ].freeze

      def add_common_options(parser, options)
        parser.on("--start MILLIONS", Float, "Starting population in millions (default: #{DEFAULTS[:start]})") { |v| options[:start] = v }
        parser.on("--target MILLIONS", Float, "Target population in millions (default: #{DEFAULTS[:target]})") { |v| options[:target] = v }
        parser.on("--base-year YEAR", Integer, "Calendar year of the start (default: #{DEFAULTS[:base_year]})") { |v| options[:base_year] = v }
      end

      def validate_common!(options)
        raise OptionParser::InvalidArgument, "--start must be positive" unless options[:start].positive?
        raise OptionParser::InvalidArgument, "--target must be greater than --start" unless options[:target] > options[:start]
      end

      def parse_list(value, name)
        list = value.split(",").map { |part| Float(part.strip) }
        raise OptionParser::InvalidArgument, "--#{name} must be positive numbers" unless list.all?(&:positive?)

        list
      rescue ArgumentError
        raise OptionParser::InvalidArgument, "invalid --#{name} list: #{value.inspect}"
      end

      def build_model(options)
        shared = { start_population: options[:start], target_population: options[:target], years: options[:years] }
        case options[:model]
        when "exponential" then Projection::Exponential.new(**shared)
        when "declining" then Projection::Declining.new(**shared)
        when "logistic" then Projection::Logistic.new(**shared, capacity: options[:capacity])
        end
      end

      def default_rates(start, target)
        required = Projection.cagr(start, target, DEFAULT_YEARS) * 100.0
        (DEFAULT_SWEEP_RATES + [required.round(2)]).uniq.sort
      end

      def rule_text(rule)
        case rule&.first
        when :drop then "dropping #{format('%g', rule[1])} pp/yr"
        when :half then "halving every #{format('%g', rule[1])} yr"
        else "constant"
        end
      end

      # -- solve -----------------------------------------------------------------

      def solve(argv, out)
        options = DEFAULTS.merge(years: nil, rate: nil)
        parser = OptionParser.new do |o|
          o.banner = "Usage: annualized.rb solve [--years N] [--rate PERCENT] [options]"
          o.separator ""
          o.separator "Closed-form solve in both directions: the constant annualized (CAGR)"
          o.separator "rate needed for a horizon, or the years needed at a given rate."
          o.separator ""
          add_common_options(o, options)
          o.on("--years N", Float, "Horizon in years; prints the required rate") { |v| options[:years] = v }
          o.on("--rate PERCENT", Float, "Constant rate in percent per year; prints years to target") { |v| options[:rate] = v }
          o.on("-h", "--help", "Show this help") { out.puts o; exit 0 }
        end
        parser.parse(argv)
        validate_common!(options)
        options[:years] = DEFAULT_YEARS if options[:years].nil? && options[:rate].nil?
        raise OptionParser::InvalidArgument, "--years must be positive" if options[:years] && !options[:years].positive?
        raise OptionParser::InvalidArgument, "--rate must be positive" if options[:rate] && !options[:rate].positive?

        start = options[:start]
        target = options[:target]
        base = options[:base_year]

        if (years = options[:years])
          rate = Projection.cagr(start, target, years)
          out.puts "Required annualized growth: #{Format.population(start)} (#{base}) -> #{Format.population(target)} in #{format('%g', years)} years"
          out.puts format("  CAGR (annual compounding):  %s/yr", Format.percent(rate))
          out.puts format("  continuous rate:            %s/yr", Format.percent(Math.log1p(rate)))
          out.puts format("  doubling time at that rate: %.1f years", Math.log(2) / Math.log1p(rate))
          out.puts format("  arrival year:               %d", base + years.round)
        end

        if (rate_percent = options[:rate])
          rate = rate_percent / 100.0
          years = Projection.years_to_target(rate, start_population: start, target_population: target)
          out.puts if options[:years]
          out.puts "At a constant #{Format.percent(rate)}/yr from #{Format.population(start)} (#{base}):"
          out.puts format("  years to #{Format.population(target)}:  %s", years >= 1000 ? format('%.0f', years) : format('%.1f', years))
          out.puts format("  arrival year:               %d", base + years.round)
          out.puts format("  population after 100 years: %s", Format.population(start * (1.0 + rate)**100))
        end
        0
      end

      # -- sweep -----------------------------------------------------------------

      def sweep(argv, out)
        options = DEFAULTS.merge(rates: nil, horizons: nil)
        parser = OptionParser.new do |o|
          o.banner = "Usage: annualized.rb sweep [--rates 0.5,1,2] [--horizons 25,50,100] [options]"
          o.separator ""
          o.separator "Grid of populations reached at constant annualized rates. Rows are"
          o.separator "rates (percent/yr); columns are horizons (years); starred cells reach"
          o.separator "the target; the last column is the years needed to reach it."
          o.separator ""
          add_common_options(o, options)
          o.on("--rates LIST", "Rates in percent per year, comma separated (default: preset list plus the #{DEFAULT_YEARS.to_i}-year required rate)") { |v| options[:rates] = parse_list(v, "rates") }
          o.on("--horizons LIST", "Horizons in years, comma separated (default: #{REFERENCE_HORIZONS.join(', ')})") { |v| options[:horizons] = parse_list(v, "horizons") }
          o.on("-h", "--help", "Show this help") { out.puts o; exit 0 }
        end
        parser.parse(argv)
        validate_common!(options)

        start = options[:start]
        target = options[:target]
        rates = options[:rates] || default_rates(start, target)
        horizons = options[:horizons] || REFERENCE_HORIZONS.map(&:to_f)

        out.puts "Population reached at constant annualized rates (#{Format.population(start)} at #{options[:base_year]})"
        out.puts format("  %8s", "rate/yr") +
                 horizons.map { |h| format("  %12s", format('%g yr', h)) }.join +
                 format("  %15s", "years to target")
        rates.each do |rate_percent|
          rate = rate_percent / 100.0
          cells = horizons.map do |h|
            population = start * (1.0 + rate)**h
            cell = Format.population(population)
            cell += "*" if population >= target
            format("  %12s", cell)
          end
          years_needed = Projection.years_to_target(rate, start_population: start, target_population: target)
          out.puts format("  %7.2f%%", rate_percent) + cells.join + format("  %15s", format('%.0f', years_needed))
        end
        out.puts "* = reached #{Format.population(target)} within that horizon"
        0
      end

      # -- trajectory ------------------------------------------------------------

      def trajectory(argv, out)
        options = DEFAULTS.merge(years: DEFAULT_YEARS, model: "exponential", capacity: nil, step: 10, csv: false)
        parser = OptionParser.new do |o|
          o.banner = "Usage: annualized.rb trajectory [--model NAME] [--years N] [--step N] [options]"
          o.separator ""
          o.separator "Year-by-year annualized rates for one model: the rate over the last"
          o.separator "row interval, the CAGR from the first year to each row, and the"
          o.separator "constant rate still needed over the remaining years to hit the target."
          o.separator ""
          add_common_options(o, options)
          o.on("--model NAME", %w[exponential declining logistic], "Projection model (default: exponential)") { |v| options[:model] = v }
          o.on("--years N", Float, "Horizon in years (default: #{DEFAULT_YEARS.to_i})") { |v| options[:years] = v }
          o.on("--capacity MILLIONS", Float, "Logistic carrying capacity (default: 1.2x target)") { |v| options[:capacity] = v }
          o.on("--step N", Integer, "Years between table rows (default: 10)") { |v| options[:step] = v }
          o.on("--csv", "Print every year as CSV instead of a table") { options[:csv] = true }
          o.on("-h", "--help", "Show this help") { out.puts o; exit 0 }
        end
        parser.parse(argv)
        validate_common!(options)
        raise OptionParser::InvalidArgument, "--years must be greater than 1" unless options[:years] > 1
        raise OptionParser::InvalidArgument, "--step must be positive" unless options[:step].positive?

        model = build_model(options)
        years = options[:years].round
        end_year = options[:base_year] + years
        capacity_note = model.respond_to?(:capacity) ? " (capacity #{Format.population(model.capacity)})" : ""

        if options[:csv]
          out.puts "model,year,calendar_year,population_millions,segment_rate,cagr_to_date,rate_needed_remaining"
          (0..years).each do |t|
            row = Annualized.trajectory_row(model, t, years, 1)
            out.puts [model.key, t, options[:base_year] + t,
                      format('%.6f', row.population),
                      row.segment_rate && format('%.8f', row.segment_rate),
                      row.cagr_to_date && format('%.8f', row.cagr_to_date),
                      row.remaining_rate && format('%.8f', row.remaining_rate)].join(",")
          end
          return 0
        end

        out.puts "Annualized trajectory: #{Format.population(options[:start])} (#{options[:base_year]}) -> " \
                 "#{Format.population(options[:target])} (#{end_year})"
        out.puts "  model: #{model.key}#{capacity_note}; rows every #{options[:step]} years"
        out.puts format("  %6s  %6s  %12s  %9s  %16s  %15s",
                        "year", "cal.", "population", "seg. %/yr",
                        "CAGR since #{options[:base_year]}", "needed to #{end_year}")
        row_years = (0..years).step(options[:step]).to_a
        row_years << years unless row_years.last == years
        row_years.each do |t|
          row = Annualized.trajectory_row(model, t, years, options[:step])
          out.puts format("  %6d  %6d  %12s  %9s  %16s  %15s",
                          t, options[:base_year] + t,
                          Format.population(row.population),
                          row.segment_rate ? Format.percent(row.segment_rate) : "n/a",
                          row.cagr_to_date ? Format.percent(row.cagr_to_date) : "n/a",
                          row.remaining_rate ? Format.percent(row.remaining_rate) : "n/a")
        end
        out.puts "  CAGR over the whole horizon: #{Format.percent(Projection.cagr(options[:start], options[:target], options[:years]))}/yr (same for every model)"
        0
      end

      # -- schedule --------------------------------------------------------------

      def schedule(argv, out)
        options = DEFAULTS.merge(initial: nil, drop: nil, half_life: nil, max_years: DEFAULT_MAX_YEARS, step: 10, csv: false)
        parser = OptionParser.new do |o|
          o.banner = "Usage: annualized.rb schedule [--initial PCT] [--drop PP] [--half-life N] [options]"
          o.separator ""
          o.separator "Simulates schedules where the annualized rate changes every year:"
          o.separator "constant, dropping by PP percentage points per year, or halving"
          o.separator "every N years. With no schedule options, compares preset scenarios."
          o.separator ""
          add_common_options(o, options)
          o.on("--initial PERCENT", Float, "Initial rate in percent/yr (default: #{DEFAULT_YEARS.to_i}-year required CAGR)") { |v| options[:initial] = v }
          o.on("--drop PP", Float, "Percentage points subtracted from the rate each year") { |v| options[:drop] = v }
          o.on("--half-life N", Float, "Years for the rate to halve") { |v| options[:half_life] = v }
          o.on("--max-years N", Integer, "Simulation limit (default: #{DEFAULT_MAX_YEARS})") { |v| options[:max_years] = v }
          o.on("--step N", Integer, "Years between table rows (default: 10)") { |v| options[:step] = v }
          o.on("--csv", "Print every year as CSV (custom schedules only)") { options[:csv] = true }
          o.on("-h", "--help", "Show this help") { out.puts o; exit 0 }
        end
        parser.parse(argv)
        validate_common!(options)
        raise OptionParser::InvalidArgument, "--max-years must be positive" unless options[:max_years].positive?
        raise OptionParser::InvalidArgument, "--step must be positive" unless options[:step].positive?
        raise OptionParser::InvalidArgument, "use either --drop or --half-life, not both" if options[:drop] && options[:half_life]
        raise OptionParser::InvalidArgument, "--drop must be positive" if options[:drop] && !options[:drop].positive?
        raise OptionParser::InvalidArgument, "--half-life must be positive" if options[:half_life] && !options[:half_life].positive?
        raise OptionParser::InvalidArgument, "--initial must be positive" if options[:initial] && !options[:initial].positive?

        if options[:initial] || options[:drop] || options[:half_life]
          custom_schedule(out, options)
        else
          preset_table(out, options)
        end
        0
      end

      def custom_schedule(out, options)
        start = options[:start]
        target = options[:target]
        base = options[:base_year]
        initial = (options[:initial] || Projection.cagr(start, target, DEFAULT_YEARS) * 100.0) / 100.0
        rule = ([:half, options[:half_life]] if options[:half_life]) || ([:drop, options[:drop]] if options[:drop])
        rate_at = Annualized.rate_function(initial_rate: initial, rule: rule)
        simulation = Annualized.simulate(start_population: start, rate_at: rate_at,
                                         target_population: target, max_years: options[:max_years])
        limit = simulation.arrival_year || options[:max_years]

        if options[:csv]
          out.puts "year,calendar_year,rate,population_millions"
          (0..limit).each do |t|
            out.puts [t, base + t, format('%.8f', rate_at.call(t)), format('%.6f', simulation.series[t])].join(",")
          end
          return
        end

        out.puts "Rate schedule: initial #{Format.percent(initial)}/yr, #{rule_text(rule)}"
        out.puts "  #{Format.population(start)} (#{base}) -> #{Format.population(target)}, simulated up to #{options[:max_years]} years"
        if simulation.arrival_year
          out.puts format("  arrival: %d (%d years)", base + simulation.arrival_year, simulation.arrival_year)
        else
          out.puts format("  arrival: not within %d years (population at %d: %s)",
                          options[:max_years], base + options[:max_years], Format.population(simulation.final_population))
        end

        out.puts
        out.puts format("  %6s  %6s  %10s  %12s", "year", "cal.", "rate %/yr", "population")
        # Once the rate hits zero the population is constant; stop there and
        # note the plateau instead of repeating identical rows.
        plateau = (0..limit).find { |t| rate_at.call(t).zero? }
        row_years = (0..(plateau || limit)).step(options[:step]).to_a
        row_years << (plateau || limit) unless row_years.last == (plateau || limit)
        row_years.each do |t|
          out.puts format("  %6d  %6d  %10s  %12s",
                          t, base + t, Format.percent(rate_at.call(t)), Format.population(simulation.series[t]))
        end
        if plateau && plateau < limit
          out.puts format("  population plateaus at %s from %d onward (growth rate 0)",
                          Format.population(simulation.series[plateau]), base + plateau)
        end
      end

      def preset_table(out, options)
        start = options[:start]
        target = options[:target]
        base = options[:base_year]
        required = Projection.cagr(start, target, DEFAULT_YEARS)

        out.puts "Rate-schedule scenarios: #{Format.population(start)} (#{base}) -> #{Format.population(target)}, " \
                 "simulated up to #{options[:max_years]} years"
        out.puts format("  %-34s %-9s %-18s %s", "scenario", "initial", "arrival", "population @ #{base + options[:max_years]}")
        PRESETS.each do |preset|
          initial = (preset[:initial] || required * 100.0) / 100.0
          simulation = Annualized.simulate(start_population: start,
                                           rate_at: Annualized.rate_function(initial_rate: initial, rule: preset[:rule]),
                                           target_population: target, max_years: options[:max_years])
          arrival = if simulation.arrival_year
                      format("%d (%d yr)", base + simulation.arrival_year, simulation.arrival_year)
                    else
                      format("not within %d yr", options[:max_years])
                    end
          out.puts format("  %-34s %-9s %-18s %s",
                          preset[:name], Format.percent(initial), arrival, Format.population(simulation.final_population))
        end
      end

      # -- annualize -------------------------------------------------------------

      def annualize(argv, out)
        options = { window: 10, model: nil, yearly: false }
        parser = OptionParser.new do |o|
          o.banner = "Usage: annualized.rb annualize FILE [--window N] [--model NAME] [--yearly]"
          o.separator ""
          o.separator "Reads a CSV of population by year and reports annualized rates:"
          o.separator "overall, per window, and optionally year by year. Accepts the output"
          o.separator "of `population_projection.rb --csv` or any CSV with year (or"
          o.separator "calendar_year) and population (or population_millions) columns."
          o.separator ""
          o.on("--window N", Integer, "Window size in years for the window table (default: 10)") { |v| options[:window] = v }
          o.on("--model NAME", "Only this model (for CSVs with a model column)") { |v| options[:model] = v }
          o.on("--yearly", "Also print the annualized rate between consecutive years") { options[:yearly] = true }
          o.on("-h", "--help", "Show this help") { out.puts o; exit 0 }
        end
        parser.parse!(argv)
        path = argv.shift
        raise OptionParser::MissingArgument, "FILE" if path.nil?
        raise OptionParser::InvalidArgument, "--window must be at least 1" if options[:window] < 1

        groups = Annualized.parse_csv(path, model_filter: options[:model])
        groups.each_with_index do |(model, points), index|
          out.puts if index.positive?
          out.puts "#{model ? "model: #{model} (#{path})" : path}: #{points.size} rows, #{points.first[0]}..#{points.last[0]}"
          overall = Annualized.annualized_between(points.first, points.last)
          out.puts format("  overall: %s (%d) -> %s (%d) = %s/yr",
                          Format.population(points.first[1]), points.first[0],
                          Format.population(points.last[1]), points.last[0],
                          Format.percent(overall))
          out.puts
          out.puts "  window      from      to   population   annualized"
          Annualized.windows(points, options[:window]).each do |from, to|
            out.puts format("  %4d yr  %6d  %6d  %12s  %11s",
                            to[0] - from[0], from[0], to[0],
                            Format.population(to[1]), Format.percent(Annualized.annualized_between(from, to)))
          end
          next unless options[:yearly]

          out.puts
          out.puts "  year   population   annualized"
          points.each_cons(2) do |from, to|
            rate = Annualized.annualized_between(from, to)
            out.puts format("  %6d  %12s  %11s", to[0], Format.population(to[1]), rate ? Format.percent(rate) : "n/a")
          end
        end
        0
      end
    end
  end
end

exit Iran::Annualized.run(ARGV) if $PROGRAM_NAME == __FILE__
