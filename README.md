# Iran population projection

Ruby models that project a starting population — by default Iran's **93.2 million (2026)** —
toward a target of **10 billion**, reporting the annualized growth rates required and the
year-by-year trajectory.

```
ruby population_projection.rb            # default report: 100-year horizon, all three models
ruby population_projection.rb --help
ruby population_projection.rb --years 50 --model logistic --rows 6
ruby population_projection.rb --csv --years 100 > projection.csv
```

## `population_projection.rb` options

| Flag | Default | Meaning |
| --- | --- | --- |
| `--start MILLIONS` | `93.2` | Starting population |
| `--target MILLIONS` | `10000` | Target population |
| `--years N` | `100` | Projection horizon |
| `--base-year YEAR` | `2026` | Calendar year of the starting population |
| `--model NAME` | `all` | `exponential`, `declining`, `logistic`, or `all` |
| `--capacity MILLIONS` | `1.2 × target` | Logistic carrying capacity |
| `--rows N` | `11` | Rows in the report tables |
| `--csv` | | Emit every projected year for all models as CSV |

## Models

All three models are calibrated to start at `P0` and land exactly on the target after `T`
years, so they share one compound annual growth rate (CAGR):

```
CAGR = (target / P0)^(1/T) - 1
```

They differ in the **path** they take and in the growth rate at any point in time:

| Model | Formula | Growth rate |
| --- | --- | --- |
| `exponential` | `P(t) = P0 · (1 + r)^t` | constant `r = CAGR` |
| `declining` | `P(t) = P0 · exp(r0 · (t − t²/2T))` | starts at `r0 = 2·ln(target/P0)/T`, tapers linearly to 0 at `T` |
| `logistic` | `P(t) = K / (1 + A·e^(−r·t))`, `A = (K − P0)/P0` | `r·(1 − P(t)/K)`, slows as it approaches capacity `K` |

For the default 93.2 M → 10 B over 100 years:

- required CAGR: **4.79%/yr** (continuous rate 4.68%/yr)
- `declining` starts at 9.35%/yr and tapers to 0%/yr
- `logistic` (capacity 12 B) starts at 6.41%/yr and is still 1.08%/yr at the target year

The report also shows how long a fixed rate would take: at Iran's recent ~0.7%/yr,
reaching 10 B would take about **670 years**.

## Sample output (abridged)

```
Population projection: 93.2 M (2026) -> 10.000 B
107.30x growth over 100 years. All models land exactly on 10.000 B in 2126; they
differ only in the path taken and in the annual growth rate over time.

Compound annual growth rate (CAGR) by horizon
     years        CAGR    continuous
        25      20.57%        18.70%
        50       9.80%         9.35%
        75       6.43%         6.23%
       100       4.79%         4.68%  <- selected horizon
       150       3.17%         3.12%
       200       2.37%         2.34%

Annual growth rate in each year
    year    cal.     exponential       declining        logistic
       0    2026           4.79%           9.35%           6.41%
      50    2076           4.79%           4.68%           5.39%
     100    2126           4.79%           0.00%           1.08%

Key rates
  exponential  constant 4.79%/yr
  declining    9.35%/yr falling to 0.00%/yr by 2126
  logistic     6.41%/yr falling to 1.08%/yr by 2126 (capacity 12.000 B)

Years to reach 10.000 B at a fixed annual growth rate
   0.70%/yr ->   670 years (arrival around 2696)   # close to Iran's recent rate
   1.00%/yr ->   470 years (arrival around 2496)
   2.00%/yr ->   236 years (arrival around 2262)
```

## `annualized.rb` — annualized rate tools

A second script with five subcommands for looking at the growth rate itself.
`ruby annualized.rb --help` lists them; each takes `--help` for options.

| Command | What it does |
| --- | --- |
| `solve` | Closed-form solve both ways: `--years 80` → required rate; `--rate 2` → years to 10 B |
| `sweep` | Grid of populations by rate × horizon; cells that reach 10 B are starred, last column is years to target |
| `trajectory` | Year-by-year annualized rates for a model: rate over the last interval, CAGR since 2026, and the constant rate still needed to land on 10 B |
| `schedule` | Simulates schedules where the rate changes yearly (`--drop` pp/yr or `--half-life`); reports the arrival year or the level where growth stalls |
| `annualize` | Reads a CSV of population by year (script 1's output or any `year,population` file) and reports overall, per-window, and per-year annualized rates |

```sh
./annualized.rb solve --years 80                 # 6.02%/yr required
./annualized.rb solve --rate 2                   # at 2%/yr: ~236 years
./annualized.rb sweep --rates 1,2,4 --horizons 50,100,150
./annualized.rb trajectory --model logistic --years 120
./annualized.rb schedule                         # preset scenario comparison
./annualized.rb schedule --initial 6 --drop 0.05 # custom schedule
./population_projection.rb --csv > p.csv && ./annualized.rb annualize p.csv --window 25
```

Sample (`schedule` presets, abridged):

```
Rate-schedule scenarios: 93.2 M (2026) -> 10.000 B, simulated up to 500 years
  scenario                           initial   arrival            population @ 2526
  constant required CAGR             4.79%     2126 (100 yr)      1.33e+06 T
  required CAGR, drop 0.05 pp/yr     4.79%     not within 500 yr  910.2 M
  8.00% initial, drop 0.05 pp/yr     8.00%     2106 (80 yr)       49.468 B
  8.00% initial, halve every 50 yr   8.00%     2152 (126 yr)      27.638 B
```

The presets show the core result: a constant 4.79%/yr arrives on schedule, but
any schedule where the rate decays — the demographically plausible case — stalls
well short of 10 B unless the starting rate is much higher.

## Tests

```
ruby population_projection_test.rb   # 14 tests: models, formats, CLI
ruby annualized_test.rb              # 22 tests: solvers, simulator, CSV parsing, all subcommands
```

## Caveat

These are mechanical projections from two endpoints, not demographic forecasts. Iran's
actual fertility is near or below replacement, so real growth is expected to slow and
eventually plateau rather than compound toward 10 billion.
