# Contributing to Waterline

Thanks for helping! Bug reports, model-size corrections, and small focused PRs are all welcome.

## Setup

You need Swift 6.2+ (Xcode 26, or the Command Line Tools for Xcode 26), which requires macOS 15.6 or later. Either Apple Silicon or Intel works; the app you build runs on macOS 14 and later.

```bash
swift build
scripts/test.sh          # works with either Xcode or the Command Line Tools
./build.sh --install     # build the .app, install to /Applications, launch
```

## Where things live

| Path | What |
| --- | --- |
| `Sources/WaterlineCore/` | Measurement and analysis — no UI. `SystemMemory`, `ProcessSampler`, `VerdictEngine`, `LeakDetector`, `LocalAI`, `UsageHistory`, `Report`. |
| `Sources/Waterline/` | The SwiftUI menu bar app. `MemoryMonitor` owns all state; `Panel/` holds the popover tabs. |
| `Tests/WaterlineCoreTests/` | Swift Testing suite for the core. |
| `scripts/` | Icon generation and the test runner. |

## Guidelines

- **Keep logic in `WaterlineCore` and test it.** If a change alters what the app *decides* (a verdict, a leak threshold, a model estimate), it belongs in the core with a test.
- **Stay honest.** No "free up RAM" tricks that don't really work (purging cache, `memory_pressure -S`, etc.). Waterline only offers actions that genuinely free memory.
- **Stay light.** The app should sit near 0% CPU. Anything that scans processes runs off the main actor and only as often as it must.
- **Check the UI in both appearances.** `.build/debug/Waterline --snapshot ./shots` renders every tab in light and dark mode.
- Match the existing style: value types by default, Swift 6 strict concurrency, `@Observable`, Swift Testing.

## Releasing

Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`, commit, then tag that version (`git tag v1.0.1 && git push origin v1.0.1`). The release workflow checks that the tag matches the plist, builds `Waterline-AppleSilicon.zip` and `Waterline-Intel.zip`, and attaches both to a GitHub release.
