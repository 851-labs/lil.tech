# Cards

<!-- Part of docs/DECISIONS.md, the index of decisions (851-2791). -->

Summary's hard-coded metrics become **cards** (851-3192): a card is a named chart, with an SF Symbol and a color, defined by a structured query, the **card spec**. It shows as a preview row on Summary, and opens as a full-page card. People create and edit cards in the apps, agents create, update and delete them over MCP, and they sync across every Mac and iPhone. This file is the design (851-3193), and the source of truth for every Cards ticket: a ticket that changes a decision updates it here in the same PR.

**Decided by Alexandru (2026-10-23), not to be re-litigated:**

- Every feature works on iOS, macOS and the server (`DECISIONS.md` › Principles). No platform-only escape hatches, such as a Mac-only SQL mode.
- Local-first: each device computes cards from its own data, the Mac from its SQLite and the iPhone from HealthKit (offline, private). The server syncs cards and runs previews for remote agents. It never computes what an app shows.
- A structured, versioned card spec (JSON), not SQL. One spec runs on every engine, validated, with clear errors for agents.
- Summary's six metrics are the **welcome seed**: steps, heart rate, active energy, walking + running distance, resting heart rate and weight, as ordinary cards that can be edited, reordered and deleted. Their IDs are fixed per account, existing accounts are seeded once, and deletions stick.
- Agents can create, update and delete cards in v1, through a new consent scope that can never write Health data. The consent copy and the privacy policy change with it, without asking Alexandru first.
- The example cards are the acceptance test (below): body temperature, sleeping heart rate, HRV, and heart rate in the 5 minutes before falling asleep; and, added the same day (851-3194), morning weight: the first weigh-in before noon each day, with a 7-day rolling average.

## Terms

- **Card:** one `health_card` record: its spec, its place on Summary, and when it was made and changed.
- **Spec:** the JSON document that says what a card charts and how it looks. Versioned, validated, and stored in its **canonical form**.
- **Series:** one quantity type, aggregated per bucket, optionally in an event window and filtered by source or device.
- **Reading:** one sample of a series' type with a value. Engines aggregate readings. Cumulative types are the exception: they use Health's de-duplicated totals.
- **Bucket:** what one point covers: an hour, a day, a night, a week or a month.
- **Range:** the period the chart shows: D, W, M, 6M or Y, as Metric Detail has them.
- **Window:** stretches of time a series' readings must fall in: asleep, before falling asleep, after waking, during workouts (the **event windows**), or hours of the local clock (`timeOfDay`).
- **Engine:** code that runs a spec over a period. There are three: the Mac's (SQLite), the server's (the store's SQLite) and the iPhone's (HealthKit).

## The card spec, v1

### Shape

A spec is a JSON object. Every field below appears in the canonical form, the form that's stored, synced and returned by the tools, with defaults filled in. Inputs (the tools, the apps' editor) may leave out any field that has a default. Unknown fields are errors, at every level, so a typo (`colour`) is caught rather than ignored.

```json
{
  "version": 1,
  "display": {
    "name": "Steps",
    "symbol": "flame.fill",
    "color": "orange",
    "unit": null
  },
  "series": [
    {
      "id": "a",
      "type": "HKQuantityTypeIdentifierStepCount",
      "aggregation": "sum",
      "window": null,
      "filter": null,
      "label": null,
      "hidden": false
    }
  ],
  "formulas": [],
  "bucket": "auto",
  "range": "W",
  "chart": { "style": "bars", "goal": null }
}
```

| Field | Type | Allowed | Default |
|---|---|---|---|
| `version` | integer | `1` | required |
| `display.name` | string | 1–40 characters after trimming, no control characters or line breaks | required |
| `display.symbol` | string | a name from the curated symbols (Display, below) | the first visible series' type's symbol (its category's), or the first series' with every series hidden |
| `display.color` | string | a palette name (Display) | the same series' type's color (its category's, `HealthCategory.colorName`) |
| `display.unit` | string or null | a display unit of the lead's dimension (Display) | `null`: the locale's unit (`MetricFormat`) |
| `series` | array | 1–4 series | required |
| `series[].id` | string | `^[a-z][a-z0-9]{0,15}$`, unique among series and formulas | `a`, `b`, `c`, `d` by position |
| `series[].type` | string | a readable quantity type's HealthKit identifier | required |
| `series[].aggregation` | string | `sum` for cumulative types; `avg`, `min`, `max`, `first`, `latest` or `count` for the others | `sum` for cumulative types, else `avg` |
| `series[].window` | object or null | one window (below): an event window or a time of day, for types that aren't cumulative | `null`: all the time |
| `series[].filter` | object or null | `{ "sources": [...], "deviceModels": [...] }`, for types that aren't cumulative | `null`: every source |
| `series[].label` | string or null | 1–40 characters | `null`: the type's name |
| `series[].hidden` | boolean | at least one series or formula stays visible | `false` |
| `formulas` | array | 0–2 formulas (below) | `[]` |
| `bucket` | string | `auto`, `hour`, `day`, `night`, `week`, `month` | `auto` |
| `range` | string | `D`, `W`, `M`, `6M`, `Y`, among the bucket's ranges | `W`, or the bucket's first range when it doesn't have `W` (`week`: `M`; `month`: `6M`) |
| `chart.style` | string | `bars`, `ranges`, `dots`, `line` | the same series' type's `chartStyle`, but `dots` for a `count` of a `ranges` type |
| `chart.goal` | object or null | `{ "value": <number> }`, in the lead's value unit | `null` |

Types are HealthKit identifiers in the canonical form. Inputs also accept what `lil-health` and the tools accept, the name lil health shows (`Heart Rate`) or the identifier without its prefix (`HeartRate`), in any case (`HealthCatalog.type(named:)`), and canonicalize them to the identifier.

- **Lengths** (names, labels, filter strings) count Unicode code points: Swift's `unicodeScalars.count`, JavaScript's `[...s].length`. Not grapheme clusters or UTF-16 units, which the Swift validator and the server's port would count differently, and a refused push makes a device bootstrap again.
- **A series' value unit** is its type's catalog unit, except for `count`, whose values are numbers of readings, in `count`, whatever the type.
- **The lead** is the card's first visible series, or, with every series hidden, its first visible formula. The header's summary, the Summary row's headline, the goal's unit and the display unit's dimension are the lead's.

### Versioning and the canonical form

- **`version`** is the spec's format. v1 is this document. A change that a v1 reader would misread (a new field, a new allowed value, a changed meaning) is a new version, documented here, with its own validation rules. Fixes that don't change what a valid spec means aren't.
- **Every engine and validator knows the versions it reads**: v1 for now. An app that meets a card of a later version shows it as a placeholder row, "Update lil health to show this card", and never changes its spec. It can still be deleted and reordered: apps keep each card's spec as the JSON they pulled, decode it only to show it, and write it back unchanged when they write the row for anything else (a move), so a spec they can't read survives them. They validate a spec only when they change it. The server refuses a version it doesn't know, so servers update before apps write a new version: the usual order, since the server deploys on merge.
- **Canonical form:** a spec is stored with every default filled in (symbol, color, chart style, series IDs, nulls). So a card never changes meaning when a default changes, such as a type's chart style in the catalog, and two engines never resolve a default differently. Apps and tools canonicalize before writing, with keys in the table's order for readable diffs. The store rejects a spec that isn't canonical, comparing **values, not text**: `canonicalize(parse(spec))` must deep-equal `parse(spec)`, numbers as doubles, key order and whitespace ignored, so Swift's and JavaScript's JSON writers (`1e-07` against `1e-7`) can never disagree into a refused push.
- **The Swift model is the source of truth** (851-3194), as `HealthCatalog` is: `HealthCards` holds the Codable model, the canonicalizer and the validator. `scripts/format` generates `Services/api/card-spec.schema.json` (JSON Schema 2020-12, its enums included: symbols, colors, units, aggregations), and `scripts/format --lint` fails when it's stale. The server's Effect Schema for the spec must produce the same JSON Schema (a test), and the server ports the semantic rules (the ones JSON Schema can't express). Both sides run one set of cases, `Services/api/test/health/cards/validation-cases.json`: a spec and the errors expected, word for word.

### Display

- **Name:** what Summary and the page title show. Not unique: two cards may share a name.
- **Symbol:** an SF Symbol from a curated list, so every name renders on macOS 26 and iOS 26 and agents can't pick one that draws nothing. `HealthCards.cardSymbols` holds the list, and a test on each platform checks that every one exists (`NSImage(systemSymbolName:)`, `UIImage(systemName:)`). v1's list, which 851-3194 may trim if that test finds a name missing:
  - Health's categories (so the seed looks as Summary does today): `flame.fill`, `figure`, `circle.dotted.circle`, `ear`, `heart.fill`, `pills.fill`, `brain.head.profile`, `figure.walk.motion`, `carrot.fill`, `lungs.fill`, `bed.double.fill`, `list.bullet.clipboard`, `waveform.path.ecg`, `plus`.
  - Body and vitals: `heart.text.square.fill`, `bolt.heart.fill`, `waveform`, `drop.fill`, `thermometer.medium`, `scalemass.fill`, `ruler.fill`, `eye.fill`, `hand.raised.fill`, `brain`, `cross.case.fill`.
  - Activity: `figure.walk`, `figure.run`, `figure.stairs`, `figure.pool.swim`, `figure.outdoor.cycle`, `bicycle`, `figure.strengthtraining.traditional`, `figure.mind.and.body`, `figure.cooldown`, `bolt.fill`, `timer`, `stopwatch.fill`.
  - Sleep and time: `moon.fill`, `moon.zzz.fill`, `zzz`, `sun.max.fill`, `sunrise.fill`, `sunset.fill`, `clock.fill`, `alarm.fill`.
  - Food: `fork.knife`, `cup.and.saucer.fill`, `waterbottle.fill`, `leaf.fill`.
  - General: `chart.line.uptrend.xyaxis`, `chart.bar.fill`, `gauge.with.dots.needle.50percent`, `star.fill`, `target`, `flag.fill`.
- **Color:** a palette name, so a card looks the same on every platform: `red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `brown`, `gray`. Each is SwiftUI's system color of that name, which adapts to light and dark mode and is the same on the Mac and the iPhone. The default is the first series' type's category color. `HealthCatalog` gets `HealthCategory.colorName`, the palette name, beside `symbolName`, and `HealthUI`'s `HealthCategory.color` reads it, so there's one mapping and `HealthCards` needs no SwiftUI. Every chart line draws in it: a formula over its series in the same color, a second series at 60% opacity, a third and fourth at 40% and 25% opacity with dots of different shapes (circle, square, triangle, diamond), so the palette stays one color per card.
- **Unit:** `null` shows the locale's unit for the first series' type, as Metric Detail does (`MetricFormat.unit(_:typeID:locale:)`, 851-3116). An override pins one, for people who weigh in kilograms but read temperatures in °F. Only these, and only where the lead's value unit has that dimension (never for `count`): mass `kg`, `lb`, `st`; length `cm`, `m`, `km`, `in`, `ft`, `yd`, `mi`; temperature `degC`, `degF`; speed `km/hr`, `mi/hr`, `m/s`; volume `mL`, `L`, `fl_oz_us`; energy `kcal`, `kJ` (HealthKit's unit strings). Values are stored and computed in catalog units on every engine, and only the apps convert to the display unit. The tools never convert (`health.md`, Agents' data keeps its units).

### Series

- **Types:** v1 charts quantity types only (`kind == quantity`), whose `readAuthorization` is `standard`: the types Metric Detail charts. Categories (symptoms, mindful minutes), workouts as a type, sleep as a type and characteristics aren't series in v1. Sleep shapes windows instead.
- **Cumulative types** (steps, energy, distance, nutrition: `aggregation == cumulative` in the catalog) take `sum` only, with no window and no filter. They chart Health's de-duplicated totals: on the Mac and the server, the statistics source's 30-minute buckets, then the samples past its last bucket (`cumulativeTotals`), and on the iPhone, HealthKit's statistics. Raw samples from several sources (an iPhone's and a Watch's steps) would count twice, and statistics can't be split by window or source. A windowed or filtered sum, such as steps during workouts, is a later version.
- **Other quantity types** (heart rate, HRV, weight, temperature…) take:
  - `avg`: the average of the bucket's readings, weighted by the type's aggregation style, as Metric Detail weighs them (arithmetic, time-weighted, or equivalent continuous level for sound; Engines, below).
  - `min` and `max`: the lowest and highest reading.
  - `first`: the reading that started first (851-3194, for morning weight). Ties go to the earlier end, then the smaller sample ID (lowercase UUID).
  - `latest`: the reading that started last. Ties go to the later end, then the greater sample ID (lowercase UUID).
  - `count`: how many readings. Its value unit is `count` (above): it's its own dimension for the one-axis rule, a display unit never converts it, a goal over it is a count, and it can't be drawn as `ranges`.
- **Filter:** `sources` is a list of 1–10 source bundle IDs (exact match on `sourceBundleID`; a Watch's look like `com.apple.health.<UUID>`, as `samples` returns them), and `deviceModels` a list of 1–10 `HKDevice` models (exact match on the device's `model`, such as `Watch` or `iPhone`). A reading matches when it matches every list given. Each list has strings of 1–200 characters, and the object needs at least one list.

### Event windows

A window keeps a series' readings to stretches of time. A reading is in a window when its **start** is in one of its stretches, half-open (`start ≤ t < end`), as Sleep's heart rate highlight counts readings (851-3110). Windows apply to types that aren't cumulative. A series has at most one window in v1: an event window (below) or a time of day (Times of day, after).

```json
{ "kind": "asleep" }
{ "kind": "beforeSleep", "minutes": 5 }
{ "kind": "afterWaking", "minutes": 30 }
{ "kind": "workout", "activities": [37, 13] }
{ "kind": "timeOfDay", "from": "00:00", "to": "12:00" }
```

| Kind | Stretches | Fields |
|---|---|---|
| `asleep` | each night's stretches asleep: its asleep segments (Asleep, Core, Deep, REM), merged where they touch, so lying awake in the night isn't part of it | none |
| `beforeSleep` | `[F − minutes, F)`, where `F` is when the night's sleep started | `minutes`: integer, 1–240 |
| `afterWaking` | `[W, W + minutes)`, where `W` is when the night's sleep ended | `minutes`: integer, 1–240 |
| `workout` | each workout's `[startDate, endDate)`, overlapping workouts merged | `activities`: `null` (every workout) or 1–10 distinct `HKWorkoutActivityType` raw values the catalog names (`HealthCatalog.workoutActivityNames`); inputs also take Health's names (`"Running"`), in any case |

**Nights** are Sleep's (`HealthDatabase.sleepNights`, 851-3098), with naps and a day's sleep left out, as Sleep's highlights leave them out (851-3103). Precisely:

1. A night is named by the day it ends on, in the engine's calendar. Its records are the sleep analysis samples (`HKCategoryTypeIdentifierSleepAnalysis`) other than In Bed, whose start is in `[day − 6 h, day + 18 h)`: sleep from 6 PM counts toward the next day.
2. **One source:** the one (`sourceBundleID`) with the most time asleep among those records. Ties go to the bundle ID that sorts first.
3. **The main session:** that source's records, sorted by start, split wherever the next record starts 3 hours or more after the latest end so far. The session with the most time asleep is the night. Naps after the night are other sessions, and drop out.
4. **A night's sleep, not a day's:** the night counts only if its sleep starts before noon on its day's clock (`SleepNight.latestBedtime`, placed as `clockHours` places it). A nap on a day whose night wasn't recorded is a day's sleep, and no night.
5. **`F`, falling asleep,** is the start of the night's first asleep segment (`SleepNight.bedtime`): not getting into bed, and not lying awake before. **`W`, waking,** is the latest end among its asleep segments: not lying awake after, or getting out of bed.

So `beforeSleep` with 5 minutes is the 5 minutes before the first stretch of sleep, and a night without sleep has no stretches. Stages, In Bed records and other sources don't move `F` or `W`. A reading in two nights' stretches (possible only with long windows and different sources on consecutive nights) counts for the later night.

Workouts are `health_workout` records from every source, by their overall `activityType` (a multisport workout's legs aren't matched separately in v1). Pauses aren't left out.

### Times of day (851-3194)

`{"kind": "timeOfDay", "from": "HH:MM", "to": "HH:MM"}` keeps the readings whose start is within those hours of the **local clock**, every day: morning weigh-ins, resting readings overnight.

- **Times** are `HH:MM` on the 24-hour clock, two digits each, from `00:00` to `23:59`. `from` and `to` can't be equal (for every reading, the window is `null`). There's no `24:00`: `"to": "00:00"` ends at midnight.
- **A reading is in the window** when its start's clock time `t` (hours, minutes and seconds, fractions included, in the engine's calendar's time zone) has `from ≤ t < to`. When `from` is later than `to`, the window **crosses midnight**: `t ≥ from` or `t < to`, so `22:00` to `06:00` is each night's 8 hours. A reading still counts in the bucket its start falls in: one at 23:30 is in that day's bucket, and one at 01:00 in the next day's. (`CardTimeOfDay.contains(secondsSinceMidnight:)` in `HealthCards` is the rule.)
- **Daylight saving time:** it's the clock, not elapsed time. On the day clocks go forward, a window over the skipped hour is that much shorter (`02:00` to `03:00` is empty where 2 AM doesn't exist); on the day they go back, the repeated hour's readings all count (`01:00` to `02:00` holds two hours of them). A window never moves by an hour around a change, so a weigh-in at 7:30 is "before noon" all year.
- **Combining:** one window per series in v1, so no time of day within sleep or workouts. It isn't a sleep window: it takes any bucket and range, and a series with one in a `night` card is bucketed by calendar day, like one without a window. With `hour` it simply leaves the other hours empty.
- **Engines:** the Mac and the server read the type's readings over the period as without a window, and keep those whose local clock time is in the window. To keep time-zone math per day rather than per reading (851-2906), they turn each local day of the period into its stretch or two (`[from, to)` on that day's clock, or `[00:00, to)` and `[from, 24:00)` crossing midnight), placed with the calendar so a missing or repeated clock hour gives exactly the readings the rule above gives. The iPhone fetches the period's samples (`HKSampleQuery`, `.strictStartDate`) and keeps them by the same rule in Swift, as it does `first` and `latest`; per-day predicates would mean a query per day.
- **Weights for `avg`** of time-weighted types treat each day's stretch as a window's stretch (Readings and weights, below): a reading counts until its source's next reading in the stretch, or the stretch's end, at least 1 s and at most an hour.

### Bucket and range

`bucket` says what each point covers, and `range` the period the card opens on. The range control offers the bucket's ranges only:

| Bucket | Each point | Ranges |
|---|---|---|
| `auto` | the range's grain, as Metric Detail: an hour (D), a day (W, M), a week (6M), a month (Y) | D, W, M, 6M, Y |
| `hour` | a clock hour | D, W |
| `day` | a calendar day | W, M, 6M, Y |
| `night` | a night (above), at the day it ends on | D, W, M, 6M, Y |
| `week` | a calendar week (the calendar's first weekday) | M, 6M, Y |
| `month` | a calendar month | 6M, Y |

- **`auto` is Metric Detail.** For `sum` series, 6M's and Y's points are the average day of each week or month, among days with a total above 0 (`averageDays`, Health's DAILY AVERAGE), so a week's bar compares with a day's. Other aggregations are computed over all of the week's or month's readings, not averaged from days. The seed cards are `auto`, so they chart exactly as Metric Detail does.
- **A fixed bucket** gives a point per bucket at every range: `day` at Y is 365 points, and `week` at M about 5.
- **`night`** needs at least one series with a sleep window (`asleep`, `beforeSleep`, `afterWaking`). A series with a sleep window places its readings at their night's day whatever the bucket, so with `week` or `month` a night counts in the week or month of the day it ends on. A series without one, in a `night` card, is bucketed by calendar day, the night's day: Sleeping HR minus resting HR, a night against the resting heart rate of the day it ends on.
- **Sleep windows** need `night`, `week` or `month`: an hour or a calendar day would cut nights in two. Workout windows and times of day take any bucket.
- **Periods** are Metric Detail's (`ChartRange.interval`): D is a calendar day, W a calendar week, M a calendar month, 6M the six calendar months ending with the date's, and Y a calendar year, in the engine's calendar (time zone and first weekday). A bucket is the calendar's, so it may start before the period (6M's first week), but only readings in the period count. A `night` card's period holds the nights whose day is in it, with their stretches, even the evening before its first day.

### Chart

- **Style** is one of `HealthCatalog`'s four (851-3097), drawn as Metric Detail draws them:
  - `bars`: a bar from 0 to each point's value.
  - `ranges`: a capsule from each point's lowest to its highest reading, on an axis from 0. Not for `sum` or `count` series, whose values aren't readings.
  - `dots`: a dot at each value, on an axis fitted to them (`fittedDomain`).
  - `line`: dots joined by a line that carries on over buckets without a value, fitted.
  Every visible series uses the card's style. A moving average is always a line, over its series.
- **One axis:** every visible series and formula must have the same value unit, so heart rate and HRV can't share a card, nor weight and how many times it was measured. Two axes are a later version.
- **Goal:** a horizontal rule at `value`, in the lead's value unit (10,000 for steps' `count`, 70 for weight's `kg`), converted to the display unit like the values, and labeled "Goal". Finite, and not negative.

### Formulas

Formulas derive a line from series, and are kept small in v1:

```json
{ "id": "trend", "kind": "movingAverage", "of": "a", "points": 7, "label": null, "hidden": false }
{ "id": "gap", "kind": "difference", "of": ["a", "b"], "label": "Above resting", "hidden": false }
```

- **`movingAverage`:** for each point, the average of the series' values over that bucket and the `points − 1` buckets before it (2–30), among those that have a value, empty buckets included in the count of buckets. Engines compute the buckets before the period for it, so the first points have their full window. With `auto` it's points of the range's grain: 7 at W is 7 days, at Y 7 months.
- **`difference`:** `of[0]` minus `of[1]`, for each bucket where both have a value. Both must be series (not formulas) with the same value unit.
- A formula's `of` names series only. A formula has no lowest or highest, so a `ranges` card draws it as a line, like a moving average.
- Hide a series (`"hidden": true`) to show only a formula: Sleeping HR minus Resting HR as one line.

### Limits

| Limit | Value | Why |
|---|---|---|
| Series per card | 4 | One axis, one color in opacities: more is unreadable |
| Formulas per card | 2 | Keeps v1 small |
| Visible lines (series and formulas) | 1–4 | |
| Points per series and period | at most 366 (`day` or `night` at Y; `hour` at W is 168) | Bounded by the bucket's ranges |
| Spec size | 8 KB as the writer's JSON (UTF-8) in apps and tools; the store refuses past 16 KB | Plenty for 4 series. The store's limit is a backstop, so two JSON writers' few bytes of difference never get a push refused |
| Cards per account | 100 in the apps and tools; the store refuses past 200 | The store's limit is a backstop: devices racing past 100 never reach it, so their pushes aren't refused (below) |
| Name, labels | 40 characters | Fits a Summary row |

## What an engine computes

### Inputs and outputs

An engine runs a canonical spec over one period: `run(spec, range, date, calendar, now) → CardData`. The calendar is a time zone and a first weekday. The Mac and the iPhone use theirs (`@Dependency(\.calendar)`); the server takes them from the tool call (`timeZone`, an IANA name as the Health tools take it, default UTC; `firstWeekday`, `sunday` to `saturday`, default `monday`). The local server defaults to the Mac's.

`CardData`, also the tools' output (names as the tools' JSON):

```json
{
  "range": "W", "start": "2026-10-19", "end": "2026-10-25",
  "timeZone": "Europe/London", "firstWeekday": "monday", "bucket": "night",
  "series": [
    {
      "id": "a", "label": "Heart Rate", "type": "HKQuantityTypeIdentifierHeartRate",
      "aggregation": "avg", "unit": "count/min", "hidden": false,
      "points": [
        { "start": "2026-10-20T00:00:00+01:00", "value": 54.2, "minimum": 49, "maximum": 61, "readings": 37 }
      ]
    }
  ],
  "formulas": [
    { "id": "trend", "kind": "movingAverage", "unit": "count/min", "hidden": false,
      "points": [{ "start": "2026-10-20T00:00:00+01:00", "value": 55.0 }] }
  ],
  "summary": { "kind": "average", "value": 55.1, "minimum": null, "maximum": null },
  "goal": null
}
```

- `start` and `end` are the period's first and last days. Each point's `start` is its bucket's start in local time with its offset, to the second, as the tools write times. A night's is its day's midnight.
- Buckets without a value are left out, as Metric Detail leaves them out. `readings` is `null` for `sum` points, and `minimum` and `maximum` equal `value` there.
- Values are in the series' catalog unit. The apps convert for display.

### Readings and weights

- **Readings** are samples of the series' type with a value, starting in the period (for windows, in a stretch of one of the period's nights or workouts), that match the filter. The server skips deleted samples (tombstones) as its tools do.
- **Weights for `avg`,** by the type's aggregation style (`HealthDataType.Aggregation`), as `HealthDatabase.discreteStatistics` weighs them:
  - **Arithmetic:** 1 each.
  - **Time-weighted** (heart rate): without a window, each reading counts until its source's next reading of the type, or for its own duration if it's the source's last, at least 1 s and at most an hour, looking up to an hour past the period for the next reading, exactly as Metric Detail does. **In a window,** each stretch is on its own: a reading counts until its source's next reading in the stretch, or else the stretch's end, at least 1 s and at most an hour. A 5-minute window's lone reading counts 5 minutes, not the hour after it.
  - **Equivalent continuous level** (sound): its duration, at least 1 s, averaged as energy (`10·log10(Σ w·10^(v/10) / Σ w)`).
- **A bucket's average** is the weighted average of its readings. A coarser `auto` point (a week at 6M) is the weighted average of all its readings, not of its days'.

### Summary and headline

**`summary`** is what the full page's header shows for the period, from the lead:

| Lead | `kind` | Value |
|---|---|---|
| `sum`, `auto`, D | `total` | the day's total |
| `sum`, `auto`, W or M | `average` | the period's total over its days with a total above 0 (Metric Detail's AVERAGE) |
| `sum`, `auto`, 6M or Y | `dailyAverage` | the same, captioned DAILY AVERAGE (851-3099) |
| `sum`, fixed bucket | `total` with one bucket in the period, else `average` | the average of buckets with a total above 0 |
| `avg`, style `ranges` | `range`, or `average` when they're equal (as Metric Detail) | `minimum` and `maximum` of every reading |
| `avg`, other styles | `average` | the weighted average of every reading in the period (not of its points) |
| `min` | `lowest` | the lowest reading |
| `max` | `highest` | the highest reading |
| `first` | `first` | the period's first reading |
| `latest` | `latest` | the period's latest reading |
| `count` | `count` | how many readings |
| a formula (every series hidden) | `average` | the average of its points' values in the period, each point once |

A period without readings has `summary: null`, which the header shows as No Data (851-3102).

**The headline** is what a Summary row shows: the lead's latest value and a sparkline (851-3101) of the 7 buckets ending on it, in the card's style, as today's rows show the week ending on the latest day with data. Its buckets are the card's, with `auto` as `day`.

- **Its value:** a card whose lead is a discrete series, `avg` or `latest`, `auto`, with no window, filter or formula, shows its latest reading and when it was, as Summary shows heart rate and weight today. Every other card shows its latest bucket with a value, dated by the bucket ("Oct 20", "Night of Oct 20", "Week of Oct 13"), as Summary shows a day's steps.
- **Finding the latest bucket:** without a window or filter, the bucket holding the lead type's latest data started by now, found as Summary finds it today (`latestCumulativeStart` for cumulative types, `latestSample` for the others), so the seed cards' rows read exactly as today's, early-morning rows showing yesterday included. With a window or filter, or a formula as the lead: run the 7 buckets ending with the current one, then look back 7 at a time, at most 8 times (8 weeks of nights). Nothing found is No Data.

### The Mac (SQLite, 851-3195 and 851-3196)

- **A shared core in `HealthCards`,** a new module that builds for the Mac and the iPhone and depends only on `HealthCatalog`: the spec, the canonicalizer, the validator, and the engine's pure parts. Those parts are periods and buckets, weights and aggregations, nights from sleep segments, windows, formulas, summary and headline, all over plain inputs: readings `(start, end, value, source, sampleID)`, sleep records, workouts and daily or hourly totals. The Mac and the iPhone fetch differently and compute identically.
- **Moving code:** `sleepNights`' grouping (the source, the main session, the day's-sleep rule) and `discreteStatistics`' weights and average move into the core. `HealthDatabase` calls them, so Sleep, its highlights and Metric Detail keep their behavior exactly, which their tests and catalogs check.
- **Fetching** (`HealthDatabase/Queries/CardQueries.swift`): `sum` reads `cumulativeTotals` by the auto grain or the bucket. Other series read their type's readings by `(type, start_date)` over the period (plus the hour of reach for time weighting and the buckets a moving average needs). With a sleep window, the period's nights come first, then readings over each stretch. With a workout window, workouts by start come first, then readings over each. Filters join the sample's provenance (`withProvenance`: `device.model`).
- **On the main thread or not:** previews and pages read through `@Fetch` requests on the pool, as Metric Detail does, and a card's request carries the period it's for (`PeriodChart`'s pattern, 851-3084).

### The server (the store's SQLite, 851-3197)

- **For remote agents only:** `preview_card` and `get_card` run it. It never feeds an app.
- **A port of the core, rule for rule,** as `StoreHealthTools` ported `HealthTools` (851-2868): Effect code in `src/health/cards/`, over the store's tables (`health_sample`, `health_statistic` with the statistics source chosen as the Mac does, `health_workout`, `health_provenance`), tombstones skipped.
- **CPU:** a call stays under the tools' budget (about 0.7 s for a year on 1,000,000 records, `docs/BENCHMARK.md`). Time-zone math happens once per bucket and night, not per reading, and readings are read as arrays (851-2906). Sleep windows read only the stretches' ranges of the index.

### The iPhone (HealthKit, 851-3199 to 851-3201)

- **Local-first and offline:** it reads HealthKit on the phone, never the server, and the cards' data never leaves it.
- **The same core,** fed from HealthKit (in `HealthKitAccess`):
  - `sum`: `HKStatisticsCollectionQuery` with `.cumulativeSum`, by the auto grain or the bucket, anchored at local midnight in the phone's calendar (for weeks, on its first weekday), so HealthKit de-duplicates by source priority as Health does. 6M's and Y's average days come from day sums.
  - Everything else: `HKSampleQuery` (or anchored queries for paging) of the type with `predicateForSamples(withStart:end:options: .strictStartDate)`, then the core in Swift, so weights, `first`, `latest`, `count` and times of day match the Mac exactly. `HKStatisticsQuery`'s own discrete average uses HealthKit's weighting, not ours, so it isn't used for `avg`. An engine may use `.discreteMin` and `.discreteMax` statistics as a speed-up for `min` and `max` without windows or filters (they don't depend on weights), if 851-3201 shows they match.
  - Filters: `HKQuery.predicateForObjects(from:)` with the sources' `HKSource`s (from an `HKSourceQuery`) and `predicateForObjects(withDeviceProperty: HKDevicePropertyKeyModel, allowedValues:)`.
  - Nights: sleep analysis samples from `[firstDay − 6 h, lastDay + 18 h)`, grouped by the core's nights. Workouts: `HKSampleQuery` of `HKWorkoutType` by start, matched by `workoutActivityType.rawValue`.
- Sample IDs are `uuid.uuidString.lowercased()`, for `latest`'s ties.
- **Speed:** a Y of heart rate is about 100,000 samples. Summary's rows only need a few weeks. A page's 6M and Y load behind the delayed spinner (851-3086), and keep the last period on screen (851-3084). If 851-3199 measures more than 2 s for a year on a recent iPhone, it may cache per-day results for days before today, keyed by the spec's canonical JSON. No cache in the first version.

### Conformance and tolerance (851-3198, 851-3201)

- **The Mac and the server match exactly.** Cases in `Services/api/test/health/cards/conformance/cases.json` run on the tools' synthetic `dataset.json`, extended with nights (a Watch's stages and an iPhone's estimate on the same night, a nap, a day's sleep), heart rate before and after sleep, workouts of two kinds, and a filtered source. Each case is a spec, a range, a date, a calendar and `now`, with its `CardData` written by hand. Outputs match as JSON, numbers within a relative 1e-9 (sums added in another order), as the tools' cases do. The Mac's side syncs the dataset into a fresh database with the sync engine, as `HealthToolkitConformanceTests` does. The server runs the engine directly.
- **The iPhone matches the same cases** after writing the dataset into a simulator's HealthKit (851-3201), with the same 1e-9, except where HealthKit can't, each case marked `"iphone": "skip"` with the reason:
  - **Totals from several sources:** HealthKit de-duplicates by the user's source priority, and the dataset's uploaded statistics are one iPhone's. Written into a fresh simulator, both sources' samples are the simulator's own app's, so they don't de-duplicate the same way.
  - **The statistics' tail:** the Mac and server add samples past the source's last 30-minute bucket. HealthKit's statistics are always complete.
  - **Time zones on :45 offsets:** uploaded 30-minute buckets are up to 15 minutes off a local day (`health.md`, Statistics). HealthKit's are exact.
  - **Device models:** samples an app writes into HealthKit carry the device it gives them, and the simulator may not keep a model the way a Watch writes it. 851-3201 checks, and skips if so.
  Everything else (discrete aggregations, windows and times of day, nights, formulas, summaries) must match. The cases include a time of day crossing midnight and one over a daylight saving change (851-3198).
- **In the apps,** a Mac and an iPhone showing one card can differ by those cases only, since each computes from its own data.

## Validation and errors

The validator runs before every write that changes a spec (apps, tools, store) and before every preview, and returns **every** error (up to 20), each with a JSON path, a code and a message written for agents: what's wrong, what's allowed, how to fix it. Tools return them all in their error (MCP Tools, below), and the editor shows each one under its field.

`HealthCards` implements it (851-3194): `CardSpec(input:)` canonicalizes and validates what apps and tools write, and `CardSpec.storedErrors(_:)` is the store's check. Every code, with its message as the validator writes it (the examples' values vary):

| Code | Path | Message (example) |
|---|---|---|
| `invalidJSON` | (the spec) | `The spec isn't valid JSON.` (text input only) |
| `invalidType` | any field | `display.name must be a string.`, `series[0].hidden must be true or false.`, `A card spec is a JSON object.` |
| `required` | `display.name` | `display.name is required: what the card is called on Summary.` (and `version`, `display`, `series`, a series' `type`, a window's `kind` and `minutes`, a formula's `kind` and `of`, a goal's `value`) |
| `unknownField` | `display.colour` | `Unknown field "colour" in display. Allowed: name, symbol, color, unit.` (`in the spec` at the top) |
| `unknownValue` | `series[0].aggregation` | `"median" isn't an aggregation. Use sum, avg, min, max, latest or count.` (and buckets, ranges, styles, window and formula kinds) |
| `unsupportedVersion` | `version` | `version 2 isn't supported. This server reads card spec version 1.` (the one error: the other rules are v1's) |
| `nameLength` | `display.name` | `display.name must be 1 to 40 characters (it's 52).` |
| `invalidCharacters` | `display.name` | `display.name can't have line breaks or control characters.` (and labels) |
| `unknownSymbol` | `display.symbol` | `"heart.circle.fil" isn't one of lil health's card symbols. Close ones: heart.fill, heart.text.square.fill, bolt.heart.fill. The input schema lists them all.` |
| `unknownColor` | `display.color` | `"crimson" isn't a card color. Use one of: red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray.` |
| `unitDimension` | `display.unit` | `"lb" isn't a unit for Body Temperature (degC). Use degC or degF, or null for the locale's.` / `"lb" isn't a unit for Heart Rate (count/min), which has no others: use null.` |
| `seriesCount` | `series` | `A card has 1 to 4 series (this one has 5).` |
| `invalidID` | `series[0].id` | `series[0].id must be a lowercase letter, then up to 15 lowercase letters or digits, e.g. "a" or "trend" (it's "A1").` |
| `duplicateID` | `formulas[0].id` | `"a" is already a series' id. Each series and formula needs its own.` |
| `unknownType` | `series[0].type` | `"HeartRat" isn't a type lil health knows. Did you mean Heart Rate (HKQuantityTypeIdentifierHeartRate)? list_types lists them.` |
| `notQuantity` | `series[0].type` | `Sleep isn't a quantity: cards chart quantities such as heart rate or steps. To chart around sleep, use a window on a quantity, e.g. {"kind": "asleep"}.` |
| `unreadableType` | `series[0].type` | `NikeFuel can't be read from Health by apps, so cards can't chart it.` |
| `aggregationNotAllowed` | `series[0].aggregation` | `Steps adds up, so it takes "sum" only (avg, min, max, first, latest and count are for types measured at points in time). For an average day over weeks or months, use bucket "auto" at 6M or Y.` / `Heart Rate doesn't add up: use avg, min, max, first, latest or count, not sum.` |
| `windowOnCumulative` | `series[0].window` | `Windows work with types measured at points in time (heart rate, HRV), not ones that add up (Steps), in this version.` |
| `windowMinutes` | `series[0].window.minutes` | `series[0].window.minutes must be a whole number from 1 to 240.` |
| `windowTime` | `series[0].window.from` | `series[0].window.from must be a time on the 24-hour clock, "HH:MM" from "00:00" to "23:59" (it's "7:30").` / at `series[0].window`: `series[0].window starts and ends at 08:00: for every reading, set window to null. A window may cross midnight, e.g. from "22:00" to "06:00".` |
| `unknownActivity` | `series[0].window.activities[1]` | `999 isn't a workout activity. Use HKWorkoutActivityType raw values or names, e.g. 37 or "Running".` |
| `activityCount` | `series[0].window.activities` | `series[0].window.activities must have 1 to 10 activities (it has 0), or be null for every workout.` |
| `duplicateActivity` | `series[0].window.activities[1]` | `series[0].window.activities has Running twice.` |
| `filterOnCumulative` | `series[0].filter` | `Filters work with types measured at points in time, not Steps, which uses Health's de-duplicated totals.` |
| `emptyFilter` | `series[0].filter` | `A filter needs sources or deviceModels. For every source, set filter to null.` |
| `filterList` | `series[0].filter.sources` | `series[0].filter.sources must have 1 to 10 entries (it has 11), or be null.` |
| `filterValue` | `series[0].filter.sources[2]` | `series[0].filter.sources[2] must be a string of 1 to 200 characters.` |
| `labelLength` | `series[0].label` | `series[0].label must be 1 to 40 characters (it's 0), or null.` |
| `formulaCount` | `formulas` | `A card has at most 2 formulas (this one has 3).` |
| `formulaPoints` | `formulas[0].points` | `formulas[0].points must be a whole number from 2 to 30.` |
| `sameSeries` | `formulas[0].of` | `formulas[0] subtracts "a" from itself: name two different series.` |
| `unknownReference` | `formulas[0].of` | `formulas[0] refers to "c", which isn't a series of this card.` (`Formulas take series only.` added when it names a formula) |
| `mixedUnits` | `series[1].type` | `Heart Rate Variability (ms) can't share a card with Heart Rate (count/min): a card has one axis. Make it a card of its own.` / for a difference, at `formulas[0].of`: `formulas[0] subtracts Heart Rate Variability (ms) from Heart Rate (count/min): both need the same unit.` |
| `nothingVisible` | `series` | `Every series and formula is hidden: leave at least one visible.` |
| `visibleCount` | `formulas` | `A card shows at most 4 lines (series and formulas); this one has 5.` |
| `nightNeedsSleepWindow` | `bucket` | `bucket "night" needs a series with a sleep window: {"kind": "asleep"}, "beforeSleep" or "afterWaking".` |
| `sleepWindowBucket` | `bucket` | `Sleep windows need bucket "night", "week" or "month": an hour or a calendar day would cut nights in two.` (`auto` included) |
| `rangeNotForBucket` | `range` | `range "Y" doesn't fit bucket "hour" (up to 8,784 points). Ranges for "hour": D, W.` / `range "W" doesn't fit bucket "week" (1 point). Ranges for "week": M, 6M, Y.` |
| `rangesStyle` | `chart.style` | `"ranges" draws each bucket's lowest and highest reading, and Steps is a total. Use bars, dots or line.` / `…, and a count of Heart Rate readings has none. …` |
| `goalValue` | `chart.goal.value` | `chart.goal.value must be a number of at least 0, in count/min (Heart Rate's unit).` |
| `tooLarge` | (the spec) | `The spec is 8.8 KB; the limit is 8 KB.` (the store's backstop: 16 KB) |
| `notCanonical` | (the spec) | (store only) `The spec isn't in canonical form (a default left out, a type or activity by name, or a name or label not trimmed): apps and tools write it canonicalized.` |
| `positionLength`, `invalidPosition` | `position` | (the row, `CardPosition.error`) `position must be 1 to 200 characters.` / `position "b1" isn't a fractional index: base-62 digits, starting with a letter that gives the length of its integer part.` |

- Messages name types as lil health does ("Heart Rate"), with the identifier where it helps an agent. A count is "a count of Heart Rate readings", and a formula its path (`formulas[0] (ms)`).
- **"Did you mean"** uses the same matching as `search` (each word of the input in a chartable type's name, category or short identifier), and suggests the match with the shortest name, ties in the catalog's order. None for inputs of fewer than 3 letters, which match too much.
- **"Close ones"** for symbols are up to 3 curated names sharing the most dot-separated words: a word scores 2 when a symbol has it, else 1 when one of the symbol's words starts with it or it starts with one (`fil` and `fill`), ties in the list's order.
- **The order** errors come in, which the server's port must keep (851-3194): first each field in the spec's order (`version`, `display`, `series`, `formulas`, `bucket`, `range`, `chart`), each object's fields in the table's order and then its unknown fields, sorted by UTF-16 code units; then the rules across fields: `duplicateID`, then per formula `sameSeries` or `unknownReference` and a difference's `mixedUnits`, then one axis (`mixedUnits`), `nothingVisible`, `visibleCount`, `nightNeedsSleepWindow`, `sleepWindowBucket`, `rangeNotForBucket`, `rangesStyle`, `unitDimension`, `goalValue`; then, with no others, `tooLarge`. Paths are the field's (`series[0].window.minutes`), and empty for the whole spec. A rule across fields is skipped where a field it needs had its own error.
- **Never stricter for an old version:** a spec that validated when a released app wrote it must keep validating, since the store refusing a push makes that device drop it and bootstrap again (`docs/sync/protocol.md`, Pushing changes). Tighter rules come with a new version.

### Details 851-3194 settled

- **Inputs:** `null` in a field with a default takes the default, as leaving it out does. Defaults that depend on a type come from the first series' type, so they exist only once it's valid. A series without an `id` takes `a`, `b`, `c`, `d` by position, and a formula `f1` or `f2`. A moving average's `points` defaults to 7.
- **Text:** names and labels are trimmed of the code points JavaScript's `String.prototype.trim()` removes (U+0009–U+000D, U+0020, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF), and stored trimmed. They can't contain control characters (U+0000–U+001F, U+007F–U+009F) or U+2028 and U+2029. Filter values aren't trimmed, since they're matched exactly.
- **Defaults from a type** (symbol, color, chart style) come from the first visible series, or the first series when every one is hidden: the line the card draws, so a default never trips a rule (a hidden heart rate before visible steps would otherwise default steps to `ranges`). The design said the first series. A `count` of a type drawn as `ranges` defaults to `dots`, since a count has no lowest and highest reading.
- **A filter's canonical form** has both lists, `null` for one not given: `{"sources": null, "deviceModels": ["Watch"]}`. A workout window's has `activities`, `null` for every workout. Activities keep the order given.
- **Display units by dimension:** a catalog unit's dimension is mass for `kg`, `g`, `mg` and `mcg`; length for `m` and `cm`; temperature for `degC`; speed for `m/s`; volume for `mL` and `L`; energy for `kcal`. Other catalog units (`count/min`, `ms`, `%`…) and counts have no display units.
- **Sizes** are bytes of the compact canonical JSON, written as `JSON.stringify` writes it (numbers too: `0.00001`, `1e-7`, `1e+21`), with KB as 1,024 bytes, shown rounded up to a tenth. Decoding a stored spec (`Codable`) allows the store's 16 KB, so a spec another writer made just under it still reads.
- **The curated symbols** are the list above, unchanged: every one exists on macOS and iOS (`symbolsExistOnTheMac` in `HealthCardsTests`, and `cardSymbolsExist` in `HealthPhoneSnapshotTests`, the one test bundle that runs on iOS, so it runs with the iPhone's catalogs: `scripts/snapshot --iphone`, and after every merge).
- **`HealthCategory.colorName`** is in `health-catalog.json`'s categories with `symbolName` (`"symbol"` and `"color"`), so the server's canonicalizer gives the same defaults.

### The generated files

`scripts/generate-health-cards` writes them from `HealthCards` (it compiles `HealthCatalog` and `HealthCards` with `swiftc`, a few seconds), `scripts/format` runs it, and `scripts/format --lint` and `HealthCardsTests` fail when one is stale:

- **`Services/api/card-spec.schema.json`:** the JSON Schema (2020-12) of the **canonical** form: every field required, `additionalProperties: false`, and every enum (chartable types, symbols, colors, display units, aggregations, buckets, ranges, styles, workout activities). It's in the shape Effect's `Schema.toJsonSchemaDocument` writes (`{"type": "string", "enum": […]}`, `anyOf` with `{"type": "null"}` last), so 851-3202's row schema can be compared with it. It can't express the semantic rules (a type's aggregations and units, one axis, buckets' ranges, trimming), which the server ports. The tools' input schema (851-3215) is the same with only the fields without defaults required, and types and activities widened to strings.
- **`Services/api/card-seed.json`:** `{ "cards": [{ "id", "seed", "position", "spec" }] }`, `HealthCards.welcomeSeed`, in order.
- **`Services/api/test/health/cards/validation-cases.json`:** `specs`, each a `name`, a `mode` and a `spec`: mode `input` with the `canonical` form or the `errors`, mode `stored` with the store's `errors` (empty when it's fine); and `positions`: `between` (a key between `a` and `b`, `null` where it throws), `betweenCount` (`count` keys) and `validity` (each position's `error` or `null`). The inputs are `CardValidationCases` in `HealthCards`, covering every code and the design's examples; the outputs are what the Swift gives, and the server's port must give the same, word for word and in order. The positions' outputs match the `fractional-indexing` package (3.4.0), with two fixes the server's port makes too: a position with a character that isn't a base-62 digit throws (the package computes with it as -1), and `count` positions between bounds given the wrong way round still ascend (the package's descend).

## The `health_card` sync entity (851-3202)

The second entity apps write, after `health_pin` (851-2641, retired in 851-2990), and the first that agents write through the server.

```ts
export const HealthCard = defineEntity("health_card", {
  clientWritable: true,
  id: /^card_(?:[0-9A-HJKMNP-TV-Z]{26}|seed_[a-z_]{1,40})$/,
  fields: {
    spec: Column.json,             // the canonical spec
    position: Column.text,         // Summary's order: a fractional index, ascending
    createdAt: Column.integer,     // Unix ms
    updatedAt: Column.integer,     // Unix ms
    seed: Column.nullable(Column.text), // the seed card it started as ("steps"), else null
  },
  checkRow: /* spec valid and canonical, ≤ 16 KB; position a fractional index of 1–200 characters; createdAt ≤ updatedAt; seed only on seed IDs */,
});
```

- **IDs:** `card_` and a ULID (26 characters, Crockford base32, uppercase) made by whoever creates the card (an app, or the server for an agent), so cards created on two devices offline never collide. The protocol's "prefixed, sortable ID". Seed cards have fixed IDs (below).
- **Last writer wins per card.** Apps and the server always write **whole rows** (every field), so a card is never a mix of two edits. An edit on one device and a move of the same card on another are both whole rows, and the later one wins, which at worst moves a card back or undoes a rename: acceptable for settings like these, and limited to that card, since every write is of one card (except an agent's `reorder_cards`, which the server writes from its current rows). Writing only the changed fields would merge them, but an edit to a card another device deleted would then fail the row check, and a refused push makes the device bootstrap again (`protocol.md`). With whole rows, that edit brings the card back, which is what last writer wins means.
- **`updatedAt`** is set by the writer at every write, reorders included. `createdAt` never changes. Neither decides conflicts: the server's order of arrival does (`protocol.md`).
- **Order:** fractional indexing (David Greenspan's "Implementing Fractional Indexing", the `fractional-indexing` package's algorithm): a position is a string of base-62 digits, ordered by its bytes (ascending, ties by ID), and there's always a key between two others. A card moved between two others gets a key between theirs; to the top, one before the first; to the end, one after the last. One write per move, of the moved card alone, and never a renumbering, which would push every card's whole row and undo others' edits that this device hadn't pulled yet. Keys grow about a character every 6 moves into one gap, so the 200-character limit is out of reach in practice. Swift and TypeScript implement the algorithm alike, checked by shared cases in `validation-cases.json`. New cards go to the end. `reorder_cards` gives each card whose place changed a key between its new neighbors, so cards already in order aren't written. The seed's are `a0` to `a5`.
- **Deletion** is the protocol's delete: the row goes, and the change log tells every device. The entity has no key fields, so there's no tombstone (`protocol.md`). A deleted seed card stays deleted because seeding happens once (below), not because of a tombstone.
- **Limits:** apps and tools refuse a 101st card ("You have 100 cards, the most lil health keeps. Delete one first."). The store refuses an upsert that would make a 201st, as a backstop, with `MutationRejected`. That can only come from a bug, since two devices racing past 100 make 101 or 102. The spec's 8 KB, and the push's 500 mutations, bound the rest.
- **API compatibility:** the entity's row schema is an OpenAPI component (`HealthCard`) like the others, with `spec` as free JSON. Fields are only ever added. The spec's own changes go through `version`.
- **Clients:** the Mac syncs it with its other entities into a `healthCards` table (851-3204), and the iPhone syncs only it (851-3205). An app's own writes go through `LilSyncEngine.push`, written locally first and queued, so creating, editing, deleting and reordering work offline and sync when they can.
- **Pulling one entity:** the iPhone needs `health_card`, not millions of the Health records it uploads, so the change feed takes an optional `entities` filter (`GET /v1/sync/changes?after=…&entities=health_card`, 851-3221), indexed by entity and seq, and the iPhone downloads only `health_card`'s snapshot parts. With a filter, `next` moves past changes it skipped, up to `head`, so the cursor keeps up.
- **Catching up a new entity:** an app that starts storing an entity used to bootstrap everything again: every Mac's whole Health copy, for six small cards. Instead, LilSync catches up that entity alone (851-3222, `protocol.md` › Schema changes), by itself when `LilSyncEngine`'s `entities` gains one, with no `syncSchema` bump. It loads only that entity's parts of the latest snapshot (taken at `S`), then pulls `(S, cursor]`, applying only that entity's changes, then carries on. Compaction only removes changes up to `S`, so they're there. A full bootstrap stays the fallback (a new epoch, a 410). It asks for `(S, cursor]` with the `entities` filter (851-3221), so it reads only that entity's changes, usually in one request; against a server without the filter, `(S, cursor]` comes unfiltered, bounded by `limit` so it never passes the cursor. A store without a snapshot catches up from the start of its log, which is all there. An interrupted catch-up resumes after its last page (an interrupted snapshot load starts over, keeping downloaded parts).
- **Signing out** deletes the local cards and their queued pushes, with the rest of the account's local data. **Exports** include `health_card` records, since exports carry every entity. **Deleting the account** wipes them with the store.

## The welcome seed (851-3203)

Every account starts with Summary's six metrics as cards, so Summary looks as it does today:

| ID | `seed` | Position | Name | Symbol | Color | Series | Style |
|---|---|---|---|---|---|---|---|
| `card_seed_steps` | `steps` | `a0` | Steps | `flame.fill` | `orange` | StepCount, `sum` | `bars` |
| `card_seed_heart_rate` | `heart_rate` | `a1` | Heart Rate | `heart.fill` | `red` | HeartRate, `avg` | `ranges` |
| `card_seed_active_energy` | `active_energy` | `a2` | Active Energy | `flame.fill` | `orange` | ActiveEnergyBurned, `sum` | `bars` |
| `card_seed_walking_running_distance` | `walking_running_distance` | `a3` | Walking + Running Distance | `flame.fill` | `orange` | DistanceWalkingRunning, `sum` | `bars` |
| `card_seed_resting_heart_rate` | `resting_heart_rate` | `a4` | Resting Heart Rate | `heart.fill` | `red` | RestingHeartRate, `avg` | `line` |
| `card_seed_weight` | `weight` | `a5` | Weight | `figure` | `purple` | BodyMass, `avg` | `line` |

Each is canonical: `version` 1, the one series `a` with no window, filter or label, no formulas, bucket `auto`, range `W`, no goal, `unit` null. In full, the first:

```json
{
  "version": 1,
  "display": { "name": "Steps", "symbol": "flame.fill", "color": "orange", "unit": null },
  "series": [
    { "id": "a", "type": "HKQuantityTypeIdentifierStepCount", "aggregation": "sum",
      "window": null, "filter": null, "label": null, "hidden": false }
  ],
  "formulas": [],
  "bucket": "auto",
  "range": "W",
  "chart": { "style": "bars", "goal": null }
}
```

The others differ only in the table's columns: HeartRate `avg` `ranges`, ActiveEnergyBurned `sum` `bars`, DistanceWalkingRunning `sum` `bars`, RestingHeartRate `avg` `line`, BodyMass `avg` `line` (types are `HKQuantityTypeIdentifier…`). The symbols and colors are their categories', as today's rows show them, and the styles the catalog's. The seed is defined once, in `HealthCards.welcomeSeed`, and generated into `Services/api/card-seed.json` with the schema, so the server seeds exactly what Swift defines.

- **The server seeds, once per store, never the apps.** When a store starts (after its migrations, before it serves anything), if `meta` has no `health_cards_seeded` and the store isn't deleted, it upserts the six through `applyMutations`, whole rows with `createdAt` and `updatedAt` at now, and sets `health_cards_seeded` to now, **in one transaction**. So the seed is in the change log, every device pulls it, and it happens exactly once.
- **New and existing accounts alike:** a new account's store seeds on its first request. An existing one seeds the first time it starts on the version that adds this. Nothing runs over every account. A store that never wakes (an account unused since) seeds when it next does.
- **Two devices never seed twice,** because devices don't seed. The fixed IDs make it idempotent all the same: if it ever ran again (a store restored to before it seeded), it would write the same six IDs, never a second set.
- **Deletions stick:** the flag is never cleared, so a deleted seed card never comes back. An app never recreates seed cards. A Summary with no cards shows its empty state (UI, below).
- **Editing a seed card** is like editing any card. `seed` stays, so a later version could offer "Restore Default Cards" (not in v1).
- **Before the first pull,** a new Mac or iPhone shows Summary's loading state while sync starts, not seed cards of its own.
- **The `summary` tool doesn't change:** it shows the six everyday metrics, as `HealthDatabase.summaryTypes` does, whatever the cards are. Agents read cards with `list_cards`.

## MCP tools (851-3215, 851-3216, 851-3217)

Seven tools, defined once in `Services/api/src/health/cards/CardsToolkit.ts` with Effect's `Tool` and `Schema` like the Health toolkit (851-2841), listed by lil health's MCP servers after its ten (in `mcp-tools.json`, so the Mac's server registers them from the file too), and named `health.list_cards` and so on through the combined server and `lil mcp`. Outputs are OpenAPI components (`HealthCardResult`, `HealthCardDataResult`…) as the toolkit's are. Inputs that take a spec take any spec the canonicalizer accepts (defaults left out, types by name, activities by name). Outputs always give the canonical form.

| Tool | Input | Output | Needs | Annotations |
|---|---|---|---|---|
| `list_cards` | none | `{ cards: Card[] }`, in Summary's order | `health:read` | read-only, idempotent |
| `get_card` | `{ id, range?, date?, timeZone?, firstWeekday? }` | `{ card: Card, data: CardData }`: the card run over `range` (default its own) for the period containing `date` (default today) | `health:read` | read-only, idempotent |
| `preview_card` | `{ spec, range?, date?, timeZone?, firstWeekday? }` | `{ spec, data: CardData }`: validates and runs a draft without saving it | `health:read` | read-only, idempotent |
| `create_card` | `{ spec }` | `{ card: Card }`, added at the end of Summary | `health:cards` | not read-only, not destructive, not idempotent |
| `update_card` | `{ id, spec }` | `{ card: Card }`: replaces the card's spec. Its position and `createdAt` stay | `health:cards` | destructive, idempotent |
| `delete_card` | `{ id }` | `{ deleted: id }` | `health:cards` | destructive, idempotent |
| `reorder_cards` | `{ ids }`: every card's ID, once each, in the new order | `{ cards: [{ id, position }] }` | `health:cards` | not destructive, idempotent |

- **`Card`** is `{ id, spec, position, seed, createdAt, updatedAt }`, with times as the tools write them (local with offset, in `timeZone`).
- **Errors** are a `HealthCardError` (`message`, plus `errors: [{ path, code, message }]` for validation), whose message lists every error a line each, so an agent can fix them all at once. Others: `No card with the id "card_…". list_cards lists them.`, the 100-card limit, `ids` that aren't every card once (`reorder_cards needs every card's id once: missing card_…, unknown card_…`), and a grant without `health:cards` (below).
- **`preview_card` is how agents build a card:** describe it, preview it, fix the errors or look at the data, then create it. The description says so, and that previews save nothing.
- **Descriptions** spell out the spec in brief (fields, aggregations, windows and nights, buckets and their ranges, styles, formulas) with the five example cards as examples, so an agent can write a valid spec from the description and the input schema alone, which carries every enum. The 256 KB ceiling holds: 4 series of 366 points is under 100 KB.
- **Remote writes** (851-3215) run in the user's store: validate, then `applyMutations` with a whole `health_card` row, the same path the apps' pushes take. So the change is in the log, a live notice goes out, and every device pulls it. `createdAt`, `updatedAt` and the ID are the server's.
- **Local writes stay local-first** (851-3216): `lil-health mcp` validates and canonicalizes with `HealthCards`, then asks the app to write, through the action requests the command line already uses (`AgentAccess.sqlite`'s `actionRequests`, 851-2895), as new actions: `{"action": "createCard", "spec": …}`, `updateCard`, `deleteCard`, `reorderCards`. The app writes its local `healthCards` and queues the push (`LilSyncEngine.push`), then answers with the card. So the app's sync engine stays the only writer of its database, and the tool keeps opening it read-only (`health.md`, Read-only, never migrating). A write works offline and syncs when the Mac is online. The tool launches the app in the background if it isn't running, waits as `open` does (15 s to claim, 15 s to answer), and fails with the action's messages ("Sign in to lil health first.", "lil health didn't answer."). Reads and previews run in the tool, on the database it reads, with the Mac engine. Not App Intents in v1.
- **The access log** records every card call. **Remote:** a row in `agent_access_log` (`server.md`), its `types` the spec's series types, `range` and `date` for `get_card` and `preview_card`, and `rows` the points or cards returned. Two nullable columns are added, `card_id` and `card_name` (an additive store migration, and optional `cardId` and `cardName` fields on `GET /v1/me/agents/access-log`'s entries, safe for installed apps), so Settings can say "Created “Sleeping Heart Rate”". A card's name is the user's own words, like a search, but it's what they need to see what an agent changed, so it's kept, never a spec or values. **Local:** `AgentAccessStore.authorize` with the tool and its arguments in short: `create_card {"name":"Sleeping Heart Rate"}`, `update_card {"id":"card_…","name":"…"}`, `delete_card {"id":"card_…"}`, `preview_card {"range":"W","types":["HKQuantityTypeIdentifierHeartRate"]}`, never the whole spec.
- **Conformance** (851-3217): the tools' cases gain card calls (list, get, preview, each error, and writes followed by `list_cards`), run against both servers as the Health tools' are, so the remote and local servers answer the same. Writes on the Mac's side go through a fake app answering the action requests, as `HealthCLI`'s tests do.

## The consent scope (851-3214)

- **Name:** `health:cards`, under lil health's prefix like `health:read`, in `agentResources.health.scopes` (`["health:read", "health:cards"]`), so Turn Off, the metadata and the consent page pick it up from the registry.
- **Reading stays the key to the server:** today lil health's own server lets a grant in only if it holds every scope of the app (`appServer.usable` in `McpRoutes.ts`), which would shut out every existing grant. So `AgentApp` gets a `readScope` (`health:read`): the app's server, and the combined server's choice of apps, admit a grant by it alone, and forward all of the grant's scopes in `x-lil-agent-scopes`, as they do now. The write tools check for `health:cards` there, per call.
- **What it allows:** creating, updating, deleting and reordering the account's cards (their specs and order), through the four write tools. Nothing else. It never writes, changes or deletes Health data, and no tool that writes Health data exists. Reading cards and previews needs `health:read`, which every grant has.
- **How it's asked for:** agents ask in `scope`, as for `health:read`. `health:cards` always comes with `health:read`: asking for it alone grants both, since a writer that can't list cards is no use. Asking for no scope, as most agents do, means all of the app's scopes, as it does today (`accounts.md`, Agents), so both. `scopes_supported` in the metadata, and the 401 challenge's `scope`, list both. The consent page stays all or nothing (`accounts.md`): it lists what the agent asked for, and the agent gets all of it or nothing.
- **Grants from before** keep `health:read` only, since a refresh never changes a grant's scopes. Their card writes fail with a tool error: `This agent can read lil health but not change cards. To let it, connect it again and allow it to manage cards.` Their reads work as before. MCP's step-up authorization (a 403 `insufficient_scope` on the call) is a later improvement, since the store answers per tool and the challenge is the Worker's.
- **Turn Off Agent Access** takes every lil health scope away, `health:cards` included. Revoking deletes the grant.
- **The consent page:** for lil health's server, "<Agent> will be able to read **all of your lil health data**, and create, change and delete your **cards**. It can't change your Health data." It keeps the existing lines on AI providers and the privacy policy link. Without `health:cards`, it reads as today. For the combined server, the app's line adds "and create, change and delete your cards in lil health".
- **The privacy policy** (`Web/site/public/privacy`), section "AI agents connected to your account": "It can't change or delete anything" becomes "It can't change or delete your Health data. If you allow it, it can also create, change and delete your cards, the charts on lil health's Summary: their names, icons, colors and what they show. Changes sync to your devices." The log's bullet adds "which card it created, changed or deleted, and its name". The Mac section ("Command-line tools and AI agents on your Mac") adds that, while the setting is on, programs can also create, change and delete cards, which sync to your other devices. What I keep adds cards: their names and settings, stored with your account like your Health data, synced to your devices, in your export, and deleted with your account. A new effective date.
- **Consent versioning:** the consent type stays `agents:health`. Its policy version (`agentsConsentPolicyVersions["agents:health"]`) moves to the new policy's effective date, so new connections record consent to the policy that describes cards. Consents given before stay in force for their grants (`Consents.inForce` doesn't compare versions), and those grants can't write cards anyway. Health consent's version doesn't change: cards are settings, not a new use of Health data, and bumping it would ask every iPhone to consent again.
- **lil.tech/agents** explains the card tools and shows the five example cards as prompts (851-3218). Settings › Agents on both apps keeps its copy, except that log rows show card changes.
- **Ships without asking Alexandru** (his authority, 2026-10-23). The PR and ticket say what changed.
- **As shipped (851-3214):**
  - The registry's app has `readScope` and `writeScopes` (`{ "health:cards": { what: "cards", unchanged: "Health data" } }`), so the consent page, `grantFor` (read scope added to any other), `appsOfScopes` (an app is in by its read scope), lil health's server and the combined server's choice of apps all read them. The challenge's and metadata's `scope` lists both.
  - The guard is `requireCardsScope` (`src/health/cards/CardsScope.ts`), over `requireScope` and `forwardedScopes` (`src/mcp/AgentScopes.ts`), which read `x-lil-agent-scopes` from the request the Worker forwarded: no request means no scopes, so it fails closed. It fails with a `HealthToolError` carrying the message above; 851-3215 runs it first in each write tool (mapping it to `HealthCardError` if it wants).
  - The consent page's title adds the writes too: "Allow <Agent> to read your lil health data and change your cards?", under the heading "What it can do" (read-only requests keep "What it can read" and their copy). The combined page says "…these lil apps: lil health, and create, change and delete your cards in lil health. It can't change your Health data, or anything else."
  - **Effective date and consent version: October 24, 2026, `2026-10-24`.** The policy was already effective October 23 (851-3114), and the change deploys late on the 23rd Pacific, the 24th in UTC and Europe, so the next day. Health consent stays `2026-10-15`.
  - **The privacy policy** also lists cards under What I collect (a "Your cards" item), and in deleting an account and the export, beside the agents section's and the Mac section's sentences above.
  - **lil.tech/agents** has a Cards section: what an agent can do with cards (never Health data), that the page says when it asks, that agents connected before must connect again to change cards, and that `lil mcp` can too while access on the Mac is on. The card tools' names and the example prompts are 851-3215's and 851-3218's.
  - **A refresh that asks for `health:cards`** on an older grant is still `invalid_scope`, as for any scope a grant lacks (RFC 6749 §6). MCP clients usually refresh without a `scope`, which keeps the grant's; one that sent the metadata's whole list would have to connect again.

## The five example cards

The acceptance test (851-3218): an agent creates them over MCP, they sync, and they render on the Mac and the iPhone. In canonical form:

**1. Body temperature:** a line over time.

```json
{
  "version": 1,
  "display": { "name": "Body Temperature", "symbol": "thermometer.medium", "color": "red", "unit": null },
  "series": [
    { "id": "a", "type": "HKQuantityTypeIdentifierBodyTemperature", "aggregation": "avg",
      "window": null, "filter": null, "label": null, "hidden": false }
  ],
  "formulas": [],
  "bucket": "auto",
  "range": "M",
  "chart": { "style": "line", "goal": null }
}
```

**2. Sleeping heart rate:** heart rate while asleep, per night.

```json
{
  "version": 1,
  "display": { "name": "Sleeping Heart Rate", "symbol": "moon.zzz.fill", "color": "indigo", "unit": null },
  "series": [
    { "id": "a", "type": "HKQuantityTypeIdentifierHeartRate", "aggregation": "avg",
      "window": { "kind": "asleep" }, "filter": null, "label": null, "hidden": false }
  ],
  "formulas": [],
  "bucket": "night",
  "range": "M",
  "chart": { "style": "line", "goal": null }
}
```

**3. HRV:** dots over time, with a 7-point moving average.

```json
{
  "version": 1,
  "display": { "name": "HRV", "symbol": "waveform.path.ecg", "color": "pink", "unit": null },
  "series": [
    { "id": "a", "type": "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "aggregation": "avg",
      "window": null, "filter": null, "label": null, "hidden": false }
  ],
  "formulas": [
    { "id": "trend", "kind": "movingAverage", "of": "a", "points": 7, "label": null, "hidden": false }
  ],
  "bucket": "auto",
  "range": "M",
  "chart": { "style": "dots", "goal": null }
}
```

**4. Heart rate before sleep:** heart rate in the 5 minutes before falling asleep, per night.

```json
{
  "version": 1,
  "display": { "name": "Heart Rate Before Sleep", "symbol": "bed.double.fill", "color": "mint", "unit": null },
  "series": [
    { "id": "a", "type": "HKQuantityTypeIdentifierHeartRate", "aggregation": "avg",
      "window": { "kind": "beforeSleep", "minutes": 5 }, "filter": null, "label": null, "hidden": false }
  ],
  "formulas": [],
  "bucket": "night",
  "range": "M",
  "chart": { "style": "dots", "goal": null }
}
```

An agent may write card 4 as just `{"version": 1, "display": {"name": "Heart Rate Before Sleep", "symbol": "bed.double.fill", "color": "mint"}, "series": [{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}], "bucket": "night", "range": "M", "chart": {"style": "dots"}}`. Canonicalizing gives the above.

**5. Morning weight:** dots, one a day, each the first weigh-in of the day before noon, with a 7-day rolling average as a line (asked for by Alexandru, 851-3194). The labels are the legend's.

```json
{
  "version": 1,
  "display": { "name": "Morning Weight", "symbol": "scalemass.fill", "color": "purple", "unit": null },
  "series": [
    { "id": "a", "type": "HKQuantityTypeIdentifierBodyMass", "aggregation": "first",
      "window": { "kind": "timeOfDay", "from": "00:00", "to": "12:00" }, "filter": null,
      "label": "First weigh-in before noon", "hidden": false }
  ],
  "formulas": [
    { "id": "trend", "kind": "movingAverage", "of": "a", "points": 7, "label": "7-day rolling average", "hidden": false }
  ],
  "bucket": "day",
  "range": "M",
  "chart": { "style": "dots", "goal": null }
}
```

Bucket `day` rather than `auto`, so each dot is a day and the average is 7 days at every range (with `auto`, 6M's points would be weeks).

**Beyond the five**, as the spec allows: Sleeping HR minus Resting HR per night is series `a` (HeartRate `avg` `asleep`, hidden), `b` (RestingHeartRate `avg`, no window, by the night's day, hidden), and a `difference` of `["a", "b"]`, bucket `night`. Steps with a 10,000 goal is the seed card with `"goal": {"value": 10000}`. Heart rate during runs is HeartRate `avg` with `{"kind": "workout", "activities": [37]}`, bucket `day`, style `ranges`.

## UI

Every state in a catalog, Mac and iPhone (AGENTS.md › UI states). Layout-shift rules (851-3084), delayed spinners (851-3086), and short copy (851-3104), as everywhere.

### Mac

- **Summary** (851-3206): its first section becomes the account's cards, a row each in Summary's order, replacing `summaryTypes`' metrics. Highlights stay below, as they are. A row is today's `MetricRow`, generalized: the card's symbol and name in its color, the headline (value, unit in the display unit, its date) and the sparkline in the card's style. The seed's rows look exactly as today's, which their catalog states check against today's references. Other rows:
  - A card of a later version reads "Update lil health to show this card", with no chart.
  - A card whose type has no data shows No Data, at the height of a row with data.
  - **Loading:** while cards load, the section keeps the height of the rows it last had (placeholder rows, "–"). On first launch, before the first pull, it has the seed's six placeholder rows, so Highlights doesn't move when the cards arrive (851-3092's rule). A failure is a line in the section.
  - **Empty:** "No Cards" with a New Card… button, in the section.
  - **Toolbar:** New Card… (⌘N in Summary).
  - **Context menu:** Edit…, Move Up, Move Down, Delete….
- **The legend** (851-3194, for both apps): a card with more than one visible line (series and formulas) shows a legend on its Summary row and its full page, a line's mark (its opacity and dot shape, or a line for a formula) and its label each, in the spec's order: a series' `label` or else its type's name, a formula's `label` or else a description ("7-point moving average", "Heart Rate − Resting Heart Rate"). Morning weight's reads "First weigh-in before noon" and "7-day rolling average". A card with one visible line has none, as today's rows have none. On a row it's one line under the sparkline (truncating, never wrapping, so rows keep their height); on the page, under the chart. Catalog states show both, with and without a legend.
- **The full-page card** (851-3207) is Metric Detail's page, for a card: a grouped form with the range control in the toolbar (only the bucket's ranges), the header from `summary` (caption, value, the period's dates), the chart at Metric Detail's fixed height in the card's style, with its goal rule and moving average, a hovered point's value and date, and Edit… in the toolbar. It follows every period rule: it opens on the card's range at the latest period with data (851-3188, from the first series' `latestPeriodDate`), keeps the last period with `updatingIndicator` while the next loads (851-3084), has placeholders before anything has loaded, says No Data once (851-3102), and is marked with `layoutAnchor` and listed in `LayoutShiftTests` (`sameLayout`: loading, loaded, loading another period, failed, no data). Below the chart: "About This Card", one sentence from the spec ("Average heart rate in the 5 minutes before falling asleep, per night."). Then, for a card of one series, Show All Data and Data Sources for its type, as Metric Detail has them. A metric pushed from Browse stays Metric Detail; a card is pushed from Summary on the same navigation path (`metricPath`), so ⌘[ and the sidebar work as they do.
- **The editor** (851-3208) is a sheet (New Card…, Edit…), a grouped form with the live preview at the top: the card as its page draws it, at its range, updating as the spec changes (debounced 300 ms, with the delayed spinner). Below are Name; Symbol, a button opening a popover grid of the curated symbols; Color, a row of palette swatches; and the query builder's sections. Validation errors show inline, each under its field in the section footer, and Save is disabled while there are any. Cancel and Save are in the toolbar. Delete Card… is at the bottom of an existing card's form, with a short confirmation: "Delete “Steps”?", "It's deleted on all your devices.", Delete. Deleting from the context menu asks the same.
- **The query builder** (851-3209) writes the spec through sections: **Data** (a series each: type, picked with the sidebar's search; aggregation, offering only the type's; window, None, Asleep, Before Falling Asleep or After Waking with a minutes stepper, During Workouts with an activity picker, or Time of Day with From and To time pickers; filter, under a disclosure; Add Series, up to 4), **Chart** (bucket, default range, style, goal), and **Formulas** (moving average, difference, up to 2). Choices the rules forbid aren't offered (no Sum for heart rate, no Night without a sleep window). Errors that remain are shown inline. It covers the five example cards, which its catalog shows filled in.
- **Reordering** (851-3210): drag rows within Summary's section, where the grouped form takes `onMove` (as `List` does); otherwise the context menu's Move Up and Move Down, and an Edit Cards sheet with a reorderable list as the pins' editor had (851-2990). 851-3210 checks drag in a real window first. One write per move (fractional positions), synced. Another device's reorder shows when it's pulled.

### iPhone

The iPhone stops being only a bridge (`health.md`, iOS app): it gets a Summary of cards, its first screen for browsing data, computed from HealthKit on the phone.

- **Summary** (851-3211): the root screen once set up (signed in, consent, Health access), a `NavigationStack` with an inset grouped `List` of preview rows, as the Mac's rows but in iOS's size classes. Sync status, today's main screen, becomes a row at the top while the upload is running, and a toolbar button otherwise, and opens today's status screen. Settings stays a toolbar button. Rows load from HealthKit, with the same loading, empty and failed states as the Mac's. No new permission prompt: setup already asks to read every type, and a type the person didn't allow reads as No Data, since HealthKit doesn't say which reads it refused.
- **The legend** shows on the iPhone's rows and pages by the Mac's rule (UI › Mac, The legend).
- **The full-page card** (851-3212): pushed from a row. The range as a segmented control under the title, as Health's pages have it, then the header, the chart and About This Card, with the same period and layout rules. Charts in `HealthUI` (shared by both apps): the chart, sparkline, `fittedDomain` and `MetricFormat` move there from `HealthMacApp` and `HealthPages` so the iPhone draws exactly what the Mac does.
- **The editor and builder** (851-3213): a sheet, a `Form` with the same sections and live preview. **Reordering** via the list's Edit mode (drag handles), and swipe to delete with the same confirmation.
- **iPhone catalogs** for each screen's states (`StateCatalog(phone:states:)`), with the catalog's synthetic data fed through a fake HealthKit source, not the simulator's HealthKit, so images never depend on it.

## What changes elsewhere

Once the tickets land, these statements in `health.md` change. Each ticket updates its own:

- "iOS app: a minimal bridge" and "The iPhone shows no charts": the iPhone shows cards (851-3211).
- "Summary (Mac) shows the everyday metrics": it shows the account's cards (851-3206).
- "`lil-health mcp` stays read-only": it writes cards, through the app (851-3216).
- "Every tool is annotated read-only": the card write tools aren't (851-3215).
- `accounts.md`'s `health:read` as lil health's one scope: plus `health:cards` (851-3214).
- `protocol.md`'s client-writable entities, the `entities` filter and catching up a new entity (851-3202, 851-3221, 851-3222).

## Tickets

In order. Each is one PR, and keeps this file current.

| Ticket | Implements | Sections |
|---|---|---|
| 851-3193 | This design, and the principles in `DECISIONS.md` | all |
| 851-3194 | `HealthCards`: the Codable spec, canonicalizer and validator (every rule and message); curated symbols, palette and units, with the symbol test; `welcomeSeed`; generating `card-spec.schema.json` and `card-seed.json`; `validation-cases.json` | The card spec; Validation |
| 851-3195 | The engine core in `HealthCards` (periods, buckets, weights, aggregations, formulas, summary, headline), with `discreteStatistics`' weights moved in; the Mac's fetching for series without windows | What an engine computes; The Mac |
| 851-3196 | Nights and windows in the core, with `sleepNights`' grouping moved in; the Mac's fetching for windows and filters; tests of the five example cards | Event windows; The Mac |
| 851-3197 | The server's engine, a port of the core | The server |
| 851-3198 | The engines' conformance cases and dataset, run by the Mac and the server | Conformance |
| 851-3199 | The iPhone's HealthKit fetching for series without windows, into the core | The iPhone |
| 851-3200 | The iPhone's nights, windows and filters from HealthKit | The iPhone |
| 851-3201 | The iPhone against the conformance cases, with the skips documented | Conformance |
| 851-3202 | The `health_card` entity: store migration, row check (Effect Schema matching `card-spec.schema.json`, and the TS validator port passing `validation-cases.json`), limits | The `health_card` entity |
| **851-3221** (new) | The change feed's `entities` filter, with the `(entity, seq)` index | The `health_card` entity |
| 851-3203 | The welcome seed in the store | The welcome seed |
| **851-3222** (new) | LilSync: catching up a newly stored entity without bootstrapping again | The `health_card` entity |
| 851-3204 | The Mac: syncing `health_card` into `healthCards` (after 851-3222), and a cards feature (read, create, update, delete, reorder through `push`) | The `health_card` entity; UI |
| 851-3205 | The iPhone: syncing `health_card` alone (after 851-3221) into a small local store, signed-out cleanup | The `health_card` entity |
| 851-3206 | Mac Summary from cards | UI › Mac |
| 851-3207 | Mac full-page card | UI › Mac |
| 851-3208 | Mac editor | UI › Mac |
| 851-3209 | Mac query builder | UI › Mac |
| 851-3210 | Mac reordering | UI › Mac |
| 851-3211 | iPhone Summary, with the chart views moved into `HealthUI` | UI › iPhone |
| 851-3212 | iPhone full-page card | UI › iPhone |
| 851-3213 | iPhone editor, builder and reordering | UI › iPhone |
| 851-3214 | `health:cards`, the consent page, the privacy policy, the consent policy version | The consent scope |
| 851-3215 | The remote card tools, the access log's card columns | MCP tools |
| 851-3216 | The local card tools, and the app's card actions | MCP tools |
| 851-3217 | The card tools' conformance across both servers | MCP tools |
| 851-3218 | Acceptance: the five example cards by an agent, on the Mac and the iPhone; lil.tech/agents | The five example cards |
