# Contributing to Waterline

Thanks for helping! Bug reports, model-size corrections, and small focused PRs are all welcome.

## Setup

You need Swift 6.2+ (Xcode 26, or just the Command Line Tools) on an Apple Silicon Mac running macOS 14 or later.

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

Tag a version (`git tag v1.0.0 && git push --tags`). The release workflow builds `Waterline.zip` and attaches it to a GitHub release. Bump `CFBundleShortVersionString` in `Resources/Info.plist` first.
