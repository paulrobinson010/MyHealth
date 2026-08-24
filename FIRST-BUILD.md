# Getting to a first green build

Notes from the machine that wrote this code but could never compile it. Ordered
by when you are likely to hit each one.

## Compile the packages before the apps

`Packages/HealthCore` is pure Swift with no UI and no platform frameworks, and
it is where most of the logic lives. It also has by far the best test coverage.
Build and test it on its own first:

```sh
swift test --package-path Packages/HealthCore
```

That validates calendar arithmetic, the export parser, the ZIP reader, unit
normalisation, the fitness index, energy balance, the sync engine's guarantees
and the deficit audit — without Xcode, code signing or entitlements being
involved at all. Every error it reports is a real error in the logic layer, not
a project-configuration problem, which makes them much cheaper to fix.

## Known blockers, in likely order

### 1. iCloud container does not exist

`Config/*.entitlements` reference `iCloud.com.example.MyHealth`, and
`CloudKitSyncBackend` is constructed with the same string in three places:

- `MyHealth/AppModel.swift`
- `MyHealthPhone/PhoneModel.swift`
- `MyHealthWatch/WatchModel.swift`

That container almost certainly does not exist under your team. Either create a
CloudKit container with that identifier in the Developer portal, or change all
four places to one you own. They must match, and all three apps must use the
same one or the log will not sync between them.

Until then, sync fails at runtime with `notSignedIn` or a `backendFailure`. It
should not stop the app launching — logging stays local and durable — but it is
worth fixing before trusting anything cross-device.

### 2. HealthKit entitlement needs provisioning

HealthKit is a gated capability. With a team set, Xcode should provision it
automatically. If it refuses, remove the HealthKit capability from the target
and the app still works through `Import from export.zip` on the Mac; the phone
and watch lose their point, so fix it properly there.

### 3. Foundation Models availability

`Packages/HealthIntelligence` is the only place `FoundationModels` appears, and
it is all behind `#if canImport(FoundationModels)` plus
`@available(macOS 26.0, iOS 26.0, *)`. If the `@Generable` / `@Guide` macros
fight you, the whole file can be stubbed without touching anything else —
`LoggingAgent` already has a keyword-matching fallback path and
`LanguageModelRefiner` already falls back to `HeuristicRefiner`.

### 4. macOS HealthKit needs macOS 26

`HealthKitSource` is annotated `@available(macOS 26.0, iOS 17.0, watchOS 10.0, *)`.
Building against an older macOS SDK compiles it out via `canImport`, and
`HealthKitBridge.availability` reports why on screen.

## What is deliberately not verified

Nothing in `MyHealth/`, `MyHealthPhone/` or `MyHealthWatch/` has ever been
compiled. Expect SwiftUI errors — argument-order mismatches in memberwise
initialisers, `Table` column builders, chart modifiers. They are individually
small and the compiler names them precisely.

The fastest way through is to paste the errors back rather than have anyone
guess: the first real compile turned up an anonymous-closure-argument mistake
that no amount of reading had caught, and a scan for that same pattern across
the tree found no others. Every real error narrows the search.
