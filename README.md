# MyHealth

A native macOS app that reads your Apple Health data and shows what has actually
happened to your fitness over the years — activity over time, trends with fitted
lines, and a single 0–100 **Fitness Index** that ranks every month, quarter and
year of your history against every other one.

Built with SwiftUI and Swift Charts. No servers, no accounts, no network calls:
everything stays in `~/Library/Application Support/MyHealth`.

---

## Getting the data in

There are two paths, and the app supports both.

### 1. Native HealthKit (macOS 26 Tahoe or later)

macOS 26 was the first release to give Mac apps HealthKit access. The Mac does
not talk to your Apple Watch directly — data travels
**Watch → iPhone → iCloud Health sync → this Mac's HealthKit store** — so your
iPhone still has to be syncing for anything to be there.

Press **Sync** in the toolbar (⌘R). The app asks for read permission and pulls
daily statistics, activity rings, sleep and workouts for the history window set
in Settings.

**Signing:** HealthKit is a gated entitlement. In Xcode, select the `MyHealth`
target → *Signing & Capabilities* → set your **Team**. A free Apple ID works.
If you would rather not sign at all, switch signing to *Sign to Run Locally* and
remove the HealthKit capability; the export path below still works.

### 2. Health export file (any macOS version)

On your iPhone: **Health → your picture (top right) → Export All Health Data**.
Save the resulting `export.zip` somewhere the Mac can see it — iCloud Drive is
the easy option — then use **Import** (⌘O) in the app.

Multi-gigabyte exports are fine. The zip is decompressed in a stream and the XML
is parsed as an event stream, folding straight into daily rollups, so memory use
stays flat no matter how long your history is.

On the **Data Source** screen you can also point the app at a folder to watch. A
newer `export.zip` landing there gets imported on its own.

No data yet? **Explore with sample data** generates four years of plausible
history so you can see what every screen does.

---

## Apple Intelligence: what it does and does not do

The on-device Foundation Model is a ~3 billion parameter language model. It
cannot tell you whether you are fitter — ask it and you get fluent prose, not a
measurement. So the architecture enforces the division rather than trusting it:

| Job | Who does it |
| --- | --- |
| Deciding whether you are fitter | `FitnessIndex` + `FitnessNarrator` — plain arithmetic, unit tested |
| Writing that conclusion up readably | The model, handed the findings and forbidden from adding any |
| Turning "three pints and a curry" into structured nutrition | The model — this is what it is genuinely good at |
| Deciding you were at the pub | `ContextClassifier` first; the model may propose, but a low-confidence guess loses to the classifier |
| Reformulating a failed food search | The model — an open-ended language problem, run in a loop |
| Deciding a looked-up figure is good enough | `NutritionValidator` — deterministic, and the only thing that can end the loop |

Every one of those has a working path with Apple Intelligence switched off. The
verdict falls back to generated English, the food diary falls back to keyword
matching, and search reformulation falls back to rules. The Coach screen says
which is in use rather than quietly degrading.

The model is not one-shot. It gets tools and a loop — see
[Where nutrition figures come from](#where-nutrition-figures-come-from) — but
never the authority to decide when it is done.

## The food diary

Talk to it, on the **Coach** screen:

> **You:** two pints of IPA and a chicken tikka masala at The Eagle
> **It:** Logged 2 × pint of IPA and a chicken tikka masala — 1,470 kcal, 5.2 UK units. Pub, The Eagle.

The session has memory, so "and another two of those" resolves against what you
just said. Items are written to HealthKit; the venue and the names — which
HealthKit has nowhere to put — are kept alongside, and that is what makes the
occasion analysis possible.

Alcohol is stored as **grams of ethanol** internally and converted only for
display. UK units (7.89 g), US standard drinks (14 g) and HealthKit's own
`numberOfAlcoholicBeverages` are three different things, and mixing them up puts
a night out wrong by a factor of two.

## Energy balance, and what you actually burn

Anyone can subtract intake from expenditure. The number worth having is your
**real maintenance**, which no calculator can tell you:

```
maintenance = average intake − (weight trend in kg/day × 7,700 kcal/kg)
```

Eat 2,400 a day, lose 0.05 kg a day, and you are burning about 2,785 — not the
2,300 your watch claims. The app reports that gap explicitly, because Apple's
active-plus-resting estimate is systematically wrong for most people and knowing
the size of your own error is the whole game.

Two guards on it: the weight change comes from a **fitted trend on a smoothed
series**, never first-minus-last (day-to-day weight is mostly water, and two
noisy endpoints can invent a kilogram that never existed); and the calibration
**refuses to run** below 60% logging coverage, because unlogged days otherwise
masquerade as a deficit that never happened.

Waist is logged alongside weight for a reason: weight alone cannot tell losing
fat from losing muscle. When weight holds flat and the waist shrinks, the app
names it as recomposition rather than letting it read as stalled progress.

## What a night out costs you

Days are grouped by where you ate, and measured against your own average — both
the day itself and the morning after:

| Occasion | Days | Calories | vs typical | Units | Next-day HRV | Next-day RHR |
| --- | --- | --- | --- | --- | --- | --- |
| Pub | 14 | 3,180 | +1,090 | 8.4 | −12 ms | +4.1 bpm |
| Restaurant | 9 | 2,940 | +850 | 3.1 | −4 ms | +1.2 bpm |
| Home | 61 | 2,050 | −40 | 0.2 | +1 ms | −0.2 bpm |

There is also a hangover profile that needs no tagging at all — it compares
mornings after drinking days against dry ones straight from the health data —
and a lagged correlation engine, because last night's drinking shows up in
*this morning's* HRV. Correlating the same day gets the sign backwards, and
there is a test that pins exactly that.

## The Watch app

An independent watchOS app. Four screens on the vertical page stack:

- **Today** — calories, macros, UK units so far, and undo
- **Food** — frequent items first, then the catalogue by meal; long-press for a
  double or a half; Digital Crown for quick calories
- **Drink** — UK serves with real ABV maths, one tap per round
- **Body** — weight and waist on the Digital Crown

Everything logged is written **into HealthKit on the Watch**, so it reaches the
Mac through Apple's own sync rather than any channel of ours. Names and venues
travel separately through iCloud's key-value store, pruned to a rolling 120-day
window to stay inside its 1 MB budget. Entries carry stable UUIDs, so the same
meal syncing twice cannot be counted twice — also pinned by a test.

Note that Foundation Models only reaches watchOS in watchOS 27 (via Private
Cloud Compute), so the Watch logs and the Mac does the conversational parsing.

---

## Where nutrition figures come from

A calorie diary is fiction unless you know which numbers are measured and which
are guessed, so every entry carries its provenance and the UI shows it.

Lookup runs as a **loop**, not a single shot:

```
        ┌──────────────────────────────────────────┐
        ▼                                          │
   search a food database                          │
        │                                          │
        ▼                                    refine the query
   score relevance ──── irrelevant ──────────────► │   (Apple Intelligence,
        │                                          │    or rule-based)
        ▼                                          │
   validate the numbers ── fails ──────────────────┤
        │                                          │
        ▼                                          │
   confident enough? ── no ────────────────────────┘
        │ yes
        ▼
      accept
```

The stopping condition is **deterministic**. `NutritionValidator` and a
relevance threshold decide when an answer is good enough; the model never gets
to declare itself finished. That is the whole safety property — otherwise a
fluent wrong answer ends the loop, which is exactly the failure this design
exists to prevent. The loop is bounded, never repeats a query, and keeps the
best candidate it saw so running out of attempts still returns something useful.

What the model *does* decide is what to search for next, which is a language
problem: "chicken tikka masala at the Bengal Spice" finds nothing, and knowing
to drop the restaurant is not something a rule does well. There is a rule-based
refiner behind it so the loop still works without Apple Intelligence.

### Validation

More important than the source. Every figure is reconciled against physics:

- **Atwater reconciliation** — 4 kcal/g protein and carbohydrate, 9 fat, 7
  alcohol, 2 fibre. Both the EU convention (fibre excluded from carbohydrate)
  and the US one (included) are tried, and the closer wins. This catches the two
  commonest defects at once: a language model inventing a calorie count its own
  macros don't support, and an Open Food Facts entry where someone typed
  kilojoules into the kilocalorie field. Where the macros are sound, the energy
  is recomputed from them.
- **Density bounds** — nothing edible exceeds 900 kcal per 100 g, and macros
  cannot outweigh their own serving.
- **Cross-source agreement** — two sources agreeing raises confidence; a
  disagreement over 25% is shown, not hidden.
- **Relevance gating** — free-text search returns confident nonsense, so a
  grocery database offering "tikka spice paste" for a curry is rejected on word
  overlap before its numbers are even considered.

### Coverage, honestly

| What you logged | Covered? |
| --- | --- |
| Packaged groceries, barcodes | Yes — Open Food Facts |
| Generic foods ("grilled chicken breast") | Yes — USDA FoodData Central (free key) |
| Anything alcoholic | Yes — calculated exactly from volume and ABV |
| **Pub and restaurant meals** | **No.** Chains publish nutrition as per-site HTML and PDFs; scraping them is fragile and licence-bound. This is the gap, and it is the case you log most. Those stay as validated estimates. |

## Which device does what

Lookup needs a language model, a network and a battery that can afford several
round trips. The Watch has none of those, and nobody wants to wait four seconds
to log a pint. So the log doubles as a work queue:

| | Watch | iPhone | iPad | Mac |
| --- | --- | --- | --- | --- |
| Log instantly | ✅ | ✅ | ✅ | ✅ |
| Apple Intelligence | ✗ until watchOS 27 | ✅ | ✅ | ✅ |
| Runs the lookup loop | ✗ | ✅ | ✅ | ✅ |
| Deficit + integrity audit | ✗ | ✅ | ✅ | ✅ |
| Full analysis and charts | ✗ | ✗ | ✅ | ✅ |

The iPad runs the same target as the iPhone but lays out as a split view rather
than a stretched phone app.

The Watch logs against the built-in table and marks the entry `pending`.
Whichever device next has the capability finishes it and syncs the corrected
figures back. The queue is idempotent — two devices running at once produce the
same answer, because resolution *replaces* an entry's numbers rather than adding
to them, and merge prefers the better-resolved copy of an entry over the local
one. That last rule is load-bearing: without it the phone's correction is
silently thrown away every time the Watch's stale copy syncs back.

---

## Sync

The food log syncs through **CloudKit** in your own private database. Health
data does not sync through this app at all — it comes from HealthKit on each
device, through Apple's own sync.

`NSUbiquitousKeyValueStore` was the first attempt and was wrong for this: 1 MB
cap, best-effort delivery, no conflict resolution. A calorie ledger cannot be
built on best-effort. The engine now guarantees four things, each with tests
that fail if it stops holding:

1. **A local write is never lost.** Changes land in a durable outbox *before*
   any network call, so logging returns the moment it is safe on device. A
   failed, cancelled or crashed sync leaves the outbox intact and the next
   attempt resends it — including across a process death.
2. **Nothing is counted twice.** Records are keyed by UUID and applying one
   repeatedly is a no-op, so retrying after an ambiguous failure is always safe.
3. **Conflicts resolve identically everywhere.** The higher-ranked version wins
   — a looked-up entry beats the estimate it replaced — never the later clock,
   because two devices' clocks disagree and later is not better. Reconciling the
   same changes in opposite orders reaches the same state.
4. **A deletion stays deleted.** Tombstones are held until the server
   acknowledges them, so a stale copy elsewhere cannot resurrect a deleted meal.

Change tokens make pulls incremental; an expired token triggers a full re-read
rather than a guess about what was missed. Failures back off exponentially, and
a slow poll backs up CloudKit's push notifications, which are best-effort — a
dropped one would otherwise mean a pint logged at the bar never showing up.

## Can you trust the deficit?

A deficit is a small difference between two large, independently error-prone
numbers, so it inherits the worst of both. Quoting one without saying what could
be wrong with it is how a calorie tracker becomes confidently useless. So every
deficit figure is shown with an audit above it, not buried in a footnote:

| Check | Why it matters |
| --- | --- |
| Logging coverage | An unlogged day does not read as missing — it reads as a day you ate nothing. Under 60% and the figure is **blocked**, not caveated. |
| Verified vs estimated calories | The share of logged calories that came from a real lookup rather than a guess. |
| Weigh-in frequency | Without a weight trend this is arithmetic on an estimate, not a measurement. Under 8 weigh-ins and it is **blocked**. |
| Predicted vs actual weight change | The one check that catches *systematic under-logging*, where coverage looks perfect and the number is still wrong. |
| Measured vs estimated resting energy | A formula is wrong by 10–15% for any individual. |
| Alcohol logged at all | The densest and most commonly forgotten calories there are. |

Every finding carries a remedy, and the deficit is quoted with a plain error bar
that widens as the evidence thins — described as exactly that, not dressed up as
a statistical interval.

---

## What it shows

| Screen | What it answers |
| --- | --- |
| **Dashboard** | Where am I right now, and what changed in the last four weeks? |
| **Coach** | Am I fitter, in plain English — and the conversational food diary. |
| **Fitness Rank** | How does my fitness now compare with every other period of my life? |
| **Activity** | How much did I move — by day, week, month, weekday, and as a calendar heatmap? |
| **Energy Balance** | Whether the deficit is trustworthy, then intake against expenditure, true maintenance, waist vs weight, what each kind of day costs. |
| **Trends** | For any single metric: full history, rolling average, fitted trend line, year-on-year. |
| **Workouts** | Every session, plus volume by activity and by month. |
| **Body & Vitals** | VO₂ max, resting heart rate, HRV, weight, body composition, mobility. |
| **Data Source** | Sync, import, folder watching, and what is currently stored. |

## The Fitness Index

Each day gets a 0–100 score summarising the **trailing 28 days**, so the line
reflects sustained fitness rather than whether yesterday happened to include a
long run. Six components, each mapped onto 0–100 through published population
reference ranges:

| Weight | Component | Source |
| ---: | --- | --- |
| 28% | Cardio capacity | VO₂ max, against Cooper-Institute-style categories for your age and sex |
| 22% | Training volume | Exercise minutes per week and active energy per day |
| 14% | Resting heart rate | Age-adjusted; lower scores higher |
| 13% | Recovery | HRV (SDNN) against what is typical for your age |
| 12% | Daily movement | Average daily step count |
| 11% | Consistency | Share of days in the window you actually moved |

Weights are the **starting point**. If a component has no data — no VO₂ max
readings, say — its weight is redistributed across the rest rather than scoring
it zero, and the screen reports the resulting coverage. Every score carries its
component breakdown, so you can always see which pillar is carrying you.

Ranking works two ways: your current score's percentile against your own entire
history, and a leaderboard of your months, quarters and years sorted best-first.

**This is not a medical assessment.** The reference ranges are population
averages, there to make your own trajectory legible.

## De-duplication

An iPhone in your pocket and a Watch on your wrist both record the same walk.
Adding them together would roughly double every number in the app, so for
additive metrics MyHealth sums within each source and then takes the **largest
source** for the day. Where Apple's own de-duplicated activity rings are
available (active energy, exercise minutes, stand hours) those win outright.
The HealthKit and export paths use the same rule, so both produce the same
database.

---

## Building

Requires Xcode 16 or later. Deployment target is macOS 14; native HealthKit
needs macOS 26 at runtime and a macOS 26 SDK at build time — without it the
HealthKit code compiles out and the app falls back to file import.

```sh
open MyHealth.xcodeproj      # then ⌘R
```

or from the command line:

```sh
xcodebuild -project MyHealth.xcodeproj -scheme MyHealth -configuration Debug build
```

### Tests

The analysis engine in `MyHealth/Core` is pure Swift with no UI or platform
dependencies, and is also exposed as a SwiftPM library so it can be tested
without Xcode:

```sh
swift test --package-path Packages/HealthCore
```

`Packages/HealthIntelligence` wraps Apple Intelligence and needs a real SDK, so
it builds in Xcode rather than under a bare `swift test`.

Coverage includes calendar arithmetic, export timestamp parsing, unit
normalisation across locales, multi-source de-duplication, the XML parser
against a fixture covering both modern and legacy workout layouts, the ZIP
reader, rolling windows and regression, the fitness index and the ranking logic,
the three alcohol unit conventions, TDEE calibration (including its refusal to
run on patchy logging), lagged correlation, the venue classifier, and the
idempotence of Watch↔Mac sync.

## Layout

```
Packages/HealthCore/       shared by all three apps; pure Swift, no UI, no platform frameworks
  Sources/HealthCore/
    Models/                DayKey, Metric, DailySummary, Nutrition, FoodLog, LogSync, persistence
    Import/                ZIP reader, streaming XML parser, HealthKit identifier mapping
    Analytics/             TimeSeries, TrendAnalysis, FitnessIndex, Rankings, EnergyBalance,
                           Correlation, OccasionAnalysis, FitnessNarrator
    Nutrition/             providers, validator, resolver, the agentic loop, resolution queue
    Sync/                  the durable sync engine, outbox and conflict resolution
  Tests/HealthCoreTests/
Packages/HealthIntelligence/  the only place FoundationModels appears; shared by Mac and iPhone
MyHealth/                  the Mac app — full analysis, charts, import
MyHealthPhone/             the iPhone and iPad app — logging, the lookup loop, the deficit audit
MyHealthWatch/             the watchOS app — instant logging, no network
Config/                    entitlements, one per target
```

## Privacy

Health data never leaves your devices. The database lives in each app's own
container and is never uploaded.

The one exception is opt-in and narrow: with **Look up food online** switched on
(it is **off by default**), the *name* of a food you log is sent to Open Food
Facts, and to USDA FoodData Central if you supply a key, to fetch its nutrition
figures. That is the entire payload — a food name. Never your weight, your heart
data, your location, your workouts, or anything about where you were. Switch it
off and nothing leaves the device at all; the built-in table and Apple
Intelligence's own estimates still work.

Apple Intelligence runs entirely on-device.

**Erase stored data** on the Data Source screen deletes MyHealth's copy only —
HealthKit and your iPhone are never written to by it.
