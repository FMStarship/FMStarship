# Contributing to FM Starship

Thanks for helping. Bug reports, fixes, tests, docs and ideas are all welcome, and a lot of the work doesn't need Football
Manager at all.

New here? The [good first issues](https://github.com/FMStarship/FMStarship/labels/good%20first%20issue) are small, and each one
says where to look. Comment on one to claim it, so nobody else starts the same work.

## Where things go

- **Something's broken:** [open a bug report](https://github.com/FMStarship/FMStarship/issues/new?template=bug_report.yml). Include
  your FM build, because many problems come from a game patch.
- **You'd like something new:** [open a feature request](https://github.com/FMStarship/FMStarship/issues/new?template=feature_request.yml).
- **You have a question or a half-formed idea:** ask in [Discussions](https://github.com/FMStarship/FMStarship/discussions).
- **You found a security problem:** report it privately, as [SECURITY.md](SECURITY.md) explains.

Please bring Mac problems here, not to FM Moleman's author, who doesn't make or support this version.

## Getting set up

You need:

- A Mac with Apple Silicon, on macOS 14 or later
- A recent Xcode. CI builds with Swift 6.3, so anything older may not compile
- Homebrew's `zstd`: `brew install zstd`
- The Steam version of Football Manager 27, but only for work on the reader, the game's rules, the plugin, or anything you want to
  see with real data

Fork the repo, then:

```bash
git clone https://github.com/YOUR-NAME/FMStarship.git
cd FMStarship
swift test
Scripts/build-app.sh
open "build/FM Starship.app"
```

`swift build` and `swift test` are safe at any time. **Don't run `Scripts/build-app.sh` while FM or FM Starship is running**,
because it deletes the running app.

To try the plugin inside FM, run `Scripts/install-plugin.sh` and set the Steam launch option it prints, as the
[README](README.md#installing-it) explains. That's safe while FM is running, and the next start of FM gets the new copy.

### Working without FM

Search, analysis and file code can all be tested with made-up data, and `Tests/StarshipAnalysisTests/AbilityOffTests.swift` shows
how to build a small world of players. Tests that need the game skip themselves when it isn't installed.

If you own FM27, **File > Save Snapshot** keeps a copy of your save's data, and **File > Open Snapshot** opens it later without the
game. Role stars, who'd join and the planner's picks need the live game, so they stay off in a snapshot.

The plugin's screens are built from the same engine output as the app's, so the logic behind them can be tested without FM too.
`Tests/StarshipPluginTests` shows how.

### Working on the plugin

The plugin runs in FM's own process, so:

- A trap in it, such as a force unwrap, an index out of range or a NaN made into an `Int`, closes FM. Handle the failure and write it
  to the log instead.
- It only goes through the IL2CPP API that FM's game code exports. It never patches FM's code.
- It never looks in `~/Documents`, because macOS would then ask the player whether FM may.
- Its log is `~/Library/Logs/FM Starship/plugin.log`, and FM's own is
  `~/Library/Logs/Sports Interactive/Football Manager 27/Player.log`, which names errors our elements cause in FM's code. Check both
  after trying a change.

`Scripts/install-plugin.sh --developer` builds in the developer tools, which a plain install leaves out:

- **Control-Option-D** writes FM's live interface, with each element's classes, size, text and colours, to `~/Library/Logs/FM Starship`.
  That's where the element names and style classes the screens use come from.
- **The command file**, `~/Library/Application Support/FMStarship/Plugin/command`, is read twice a second and then removed. Its
  commands open, switch and close FM Starship's screen, write FM's interface and tables out, and try out FM's table settings, so you
  can check a screen without clicking in FM. An unknown command writes the list of commands to the log.
- **`watch-tables`**, an empty file in the same folder, makes the plugin write out the tables of each screen FM opens, if it's there
  when FM starts.

Any program running as you can write that command file, so only run a developer build while you're working on the plugin. The tools
are behind the `STARSHIP_DEVELOPER` flag, and CI builds the plugin with it too, so they keep compiling.

## Testing

- `swift test` has to pass, and a change in behaviour needs a test.
- If you changed `Sources/CA64`, run `tools/run-emutest.sh`. It checks the interpreter against the real CPU.
- If you changed the reader or the rules, check it in the app on a real save, and look at **Help > Compatibility**.
- If you changed a screen, check it in the app, in both light and dark themes.
- If you changed the plugin, check it inside FM on a real save, with Hidden attributes on and off, and look at both logs.

CI runs the tests, the interpreter check, the plugin's developer build and a full app build on every pull request. It doesn't have
FM, so it can't check anything that needs a real save. That part is on you, and the pull request template asks what you checked.

## Pull requests

1. Make a branch on your fork, and keep each pull request to one change.
2. Fill in the template. It's fine to open a draft early and ask for help.
3. Wait for CI to pass, and answer any review comments.

`main` is protected for everyone, maintainers included. Every change goes through a pull request, CI has to pass, and review threads
have to be resolved. Pull requests are squashed when they merge, so the title becomes the commit message. Write it as what changed:
`Fix the plural in the health check`.

## The rules the app lives by

1. **It never changes the game by itself.** The app and the plugin read the game, and neither writes a save or patches FM's code. The
   agent's protocol has no write operation and has to stay that way, and FM's rules run in a sandbox whose writes are thrown away. The
   plugin adds screens to FM's interface through FM's exported IL2CPP API and does nothing else to the game. FM's own right-click
   menu on our rows acts in the game, as it does in FM's lists, because the player chooses to. The only files the app writes for FM
   are shortlists, when asked.
2. **It never closes the game.** If FM is already running, the app asks the player to save and quit. Inside FM, the plugin mustn't
   crash either, because FM would go with it.
3. **Hidden means hidden.** With Hidden attributes off, nothing hidden may be shown or used. CA and PA count as hidden, and off means
   gone, not dashes. The one exception is CA and PA deciding a rank, a standing or an order, because those screens have nothing else to
   go on. Exports follow the same rule.
4. **No answer beats a wrong answer.** After a patch, features switch off rather than show bad numbers.
5. **Say where a number comes from.** The player should be able to tell FM's answer from this app's judgement.
6. **It has to look right.** [PRODUCT.md](PRODUCT.md) says who the app is for, and [DESIGN.md](DESIGN.md) is the visual reference. Text
   is never cut off, and it's a plain, dark analytics dashboard with no football costume.

## What can't go in the repo

- Game files, or Sports Interactive's data, images or other assets
- Save files or snapshots, which hold a whole game world
- Code decompiled from FM. Addresses, offsets and notes on how something works are fine, and the README shows how they're found
- More code from FM Moleman, unless we've talked first. What's here is used with its author's permission, which doesn't cover taking more

Keep the credit and notices in the README, the About window and `LICENSE.md`, and the comments saying where code was ported from.
The licence isn't an open-source licence, so please call the project source available.

## Style

- Match the code around you, including how much it comments. A comment says why, not what.
- Write text in the app in plain words, and when something is off, say what to do about it.
- Don't add a dependency without asking first. So far there's `zstd` and [Sparkle](https://sparkle-project.org), which installs updates.

## Using AI tools

AI coding tools are welcome. Point yours at [AGENTS.md](AGENTS.md), which has the rules it needs. The work is still yours: read every
line, make sure it's been tested, and say in the pull request that you used one.

## Licence of your work

By opening a pull request, you agree that your work is shared under the project's [licence](LICENSE.md), and you confirm that you have
the right to share it.

## For maintainers: making a release

Close FM and FM Starship first, because this rebuilds the app.

1. Change the version and raise the build number in `Scripts/build-app.sh`, and rename the Unreleased heading in
   [CHANGELOG.md](CHANGELOG.md) to the version, in a pull request, and merge it. Updates compare the build number, so it must go up
   every time.
2. Update `main`, then run `Scripts/release.sh NOTES.md`, with the notes people will see in the update window, taken from that
   version's part of the changelog. It needs your Developer ID certificate, a notary login and the update signing key, as the script
   explains.
3. Publish `build/FM-Starship-VERSION.dmg` and `build/appcast.xml` with `gh release create`, targeting `main`, and put the disk image's
   SHA-256 in the release notes. The app finds updates through the latest release's `appcast.xml`, so don't leave it out.
4. Download the disk image again from the release and check the hash matches.
