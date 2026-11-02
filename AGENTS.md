# Instructions for AI coding agents

This file is for AI agents working in this repo. [CONTRIBUTING.md](CONTRIBUTING.md) applies to you as well, so read it too.

## What this is

FM Starship is a native macOS app in Swift, SwiftUI and AppKit: a scouting and club companion for Football Manager 27. It's an
unofficial Mac port of FM Moleman. It reads the running game through a small agent loaded into FM, and it runs FM's own rule functions
in an ARM64 interpreter. It's source available under PolyForm Noncommercial, so never call it open source.

## Commands

| Task | Command | Safe while FM is running? |
| --- | --- | --- |
| Run the tests | `swift test` | Yes |
| Compile | `swift build` | Yes |
| Check the interpreter against the real CPU | `tools/run-emutest.sh` | Yes |
| Build `build/FM Starship.app` | `Scripts/build-app.sh` | **No** |

The build needs Xcode and `brew install zstd`. Tests that need FM skip themselves when it isn't installed.

## Where things are

| Path | What |
| --- | --- |
| `agent/` | The library loaded into FM. It answers read requests and nothing else |
| `Sources/CA64` | The ARM64 interpreter |
| `Sources/StarshipCore` | Memory access, the reader, the data model, the rules engine |
| `Sources/StarshipSearch` | Columns, filters, units, settings |
| `Sources/StarshipAnalysis` | Recommendations, planner, bargains, club reports |
| `Sources/StarshipFiles` | Shortlists, snapshots, export, themes |
| `Sources/FMStarship` | The app |
| `Sources/fmprobe` | Developer probe, for finding things after a patch |

[README.md](README.md) explains how it works and what to do after an FM patch. [PRODUCT.md](PRODUCT.md) says who it's for, and
[DESIGN.md](DESIGN.md) is the visual reference. Read them before you change a screen.

## Never do these

- **Don't push to `main`.** Work on a branch and open a pull request. Don't look for a way around the branch rules, and don't force-push
  a branch someone else is using.
- **Don't start, stop or kill Football Manager**, unless your user asks you to. The app itself must never close the game.
- **Don't run `Scripts/build-app.sh` or `Scripts/release.sh` while FM or FM Starship is running.** They delete the running app.
- **Don't write to `~/Library/Application Support/Sports Interactive/`.** That's the player's real data, so tests use a temporary folder.
- **Don't add a write operation to the agent**, or anything that patches FM or changes a save. Reading is the promise this app makes.
- **Don't show or use hidden values while Hidden attributes is off.** CA and PA count as hidden, including in exports, filters,
  differences and list order. The one exception is CA and PA deciding a rank, a standing or an order. Off means gone, not dashes.
- **Don't guess at numbers.** If the game's answer isn't available, switch the feature off and say so.
- **Don't commit game files, saves, snapshots, Sports Interactive's assets, or code decompiled from FM.**
- **Don't add more code from FM Moleman**, or new dependencies, unless the maintainers have agreed.
- **Don't remove the credit or notices** in `README.md`, `LICENSE.md` and `AboutWindow.swift`, or the comments saying where code was
  ported from.

## Making a change

1. Keep to what was asked. Don't refactor nearby code, and don't reformat files.
2. Match the code around you, including how much it comments.
3. Add a test for any change in behaviour. `Tests/StarshipAnalysisTests/AbilityOffTests.swift` shows how to build test data with no game.
4. Run `swift test`, and `tools/run-emutest.sh` if you touched `Sources/CA64`.
5. If you changed a screen, a list or an export, check it with Hidden attributes both on and off.

## Pull requests

- Only open a pull request, issue or comment when your user has asked you to, and let them read it first.
- Fill in the template, and say that an AI tool helped.
- Say what you tested, and be plain about what you couldn't. CI has no FM and no save, so a green check says nothing about the reader,
  the rules or how a screen looks with real data.
- Keep each pull request to one change. The title becomes the commit message, so write it as what changed.
- Don't claim something works unless you've seen it work.
