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

## What it shows

| Screen | What it answers |
| --- | --- |
| **Dashboard** | Where am I right now, and what changed in the last four weeks? |
| **Fitness Rank** | How does my fitness now compare with every other period of my life? |
| **Activity** | How much did I move — by day, week, month, weekday, and as a calendar heatmap? |
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
swift test
```

Coverage includes calendar arithmetic, export timestamp parsing, unit
normalisation across locales, multi-source de-duplication, the XML parser
against a fixture covering both modern and legacy workout layouts, the ZIP
reader, rolling windows and regression, the fitness index and the ranking logic.

## Layout

```
MyHealth/
  Core/                    pure Swift, no UI — also the HealthCore SwiftPM target
    Models/                DayKey, Metric, DailySummary, HealthDatabase, persistence
    Import/                ZIP reader, streaming XML parser, HealthKit identifier mapping
    Analytics/             TimeSeries, TrendAnalysis, FitnessIndex, Rankings, ReferenceRanges
  Features/                one folder per screen
  Support/                 HealthKit source, folder watching, formatting
Config/MyHealth.entitlements
Tests/HealthCoreTests/
```

## Privacy

Nothing leaves the machine. The app is sandboxed, has no network entitlement,
and stores its database in its own container. **Erase stored data** on the Data
Source screen deletes MyHealth's copy only — HealthKit and your iPhone are never
written to.
