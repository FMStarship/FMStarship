# FM Starship

[![CI](https://github.com/FMStarship/FMStarship/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/FMStarship/FMStarship/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/FMStarship/FMStarship)](https://github.com/FMStarship/FMStarship/releases/latest)
[![Licence: PolyForm Noncommercial](https://img.shields.io/badge/licence-PolyForm%20Noncommercial-blue)](LICENSE.md)

A native Mac scouting and club-management companion for Football Manager 27. It reads your running save and shows everything
the game knows about every player and member of staff, using the game's own rules for things like who would join you. On top of
that it has a club dashboard, squad and staff overviews, a squad planner built on your own tactic, a best eleven, and tactic advice
fitted to your squad.

![The club dashboard](Assets/Screenshots/01-dashboard.jpg)

## An unofficial Mac port

FM Starship is an unofficial Mac port of [FM Moleman](https://sortitoutsi.net/content/78068/fm-moleman-27), the free Windows tool.
FM Moleman's author doesn't make or support this version, so please [report Mac problems here](https://github.com/FMStarship/FMStarship/issues),
not to them.

Credit: **[MCM Gaming (FM Moleman)](https://ko-fi.com/mcmgaming)**. Much of FM Starship still comes from FM Moleman: the features,
the way the reader finds things in FM's memory, and the search, recommendation and file code, which were translated to Swift from
the Windows app. The Mac-only parts are listed further down. If FM Starship is useful to you, you can support MCM Gaming on Ko-fi.

## What you need

- A Mac with Apple Silicon, on macOS 14 or later
- The Steam version of Football Manager 27. Other stores aren't supported.
- FM27 build 27.0.0 for everything to work. When SI patches the game, features that run FM's own code switch off until FM Starship
  catches up. They switch off rather than show wrong numbers, and Help > Compatibility shows what's working on your build.

## Using it

1. Download the disk image from [Releases](https://github.com/FMStarship/FMStarship/releases/latest), open it and drag FM Starship to
   Applications. To build it yourself, run `Scripts/build-app.sh`, then open `build/FM Starship.app`.
2. **Start Football Manager from FM Starship**, not from Steam. Press Start Football Manager. Steam stays connected.
3. Load your save in the game, then press **Load Save** in FM Starship.

The app opens on your club's dashboard: what needs a decision, who's coming through, and what the health check wants done. Press
Load Save again whenever you want fresh numbers.

CA, PA and hidden attributes stay off until you press **Hidden attributes** in the toolbar, because FM keeps them from you as well.
With that on, Ability chooses whether CA and PA show as numbers, as stars or not at all.

If FM is already running when you open FM Starship, the app asks you to save and quit it first. It never closes the
game for you.

## Screenshots

These come from a real save played in Norwegian, so formation names read the way FM shows them in that language.

**Squad planner**

![Squad planner](Assets/Screenshots/02-squad-planner.jpg)

**Best eleven**

![Best eleven](Assets/Screenshots/03-best-eleven.jpg)

**Optimized tactic**

![Optimized tactic](Assets/Screenshots/04-optimized-tactic.jpg)

**Player profile**

![Player profile](Assets/Screenshots/05-player-profile.jpg)

**About, with the credit and licence**

![About](Assets/Screenshots/06-about.jpg)

## How it works

On Windows, FM Moleman reads the game's memory from outside. macOS refuses that for hardened apps, and a process that
hands out its own task port is killed by the kernel. So on Mac:

- **A small agent is loaded into FM at launch** (`agent/agent.c`, about 200 lines), through the
  `allow-dyld-environment-variables` entitlement FM27 ships with. No game file is changed, and the agent only
  exists for launches made from FM Starship. FM loads a copy from `~/Library/Application Support/FMStarship`, so
  replacing the app never touches the agent a running game is using.
- **The agent only answers read requests**, over a private Unix socket. The protocol has no write operation. It
  hooks nothing and patches nothing. This is a promise made by the code, not one enforced by the kernel.
- **Stale pointers are safe.** Reads report bad addresses as errors, and the socket cannot raise SIGPIPE in the game.

**The game's rules** ("would he join you", staff interest, season stats) are not reimplemented. As on Windows, FM's
own compiled code is run on a copy of its memory, inside an interpreter (`Sources/CA64`). FM Moleman's emulator runs
x86-64; this one runs ARM64, because that is what FM runs on a Mac. All writes go to a private overlay that is
thrown away after each call, so this code can never change your game or save.

## What works

Everything FM Moleman does on Windows, on FM27 27.0.0 for Mac:

| Feature | How it's done |
| --- | --- |
| Players, staff, attributes, hidden attributes, CA/PA, personality, traits | Read from memory |
| Contracts, clauses, loans, squads, injuries, values, currencies, budgets | Read from memory |
| Would join you (transfer and loan), staff interest | FM's own functions |
| Role stars, in and out of possession, at every position | FM's own functions |
| Season stats, board staff limits, preferred job | FM's own functions |
| Formation names, in the game's language | FM's own function |
| Exact injury return days | FM's own function |
| Form, job preferences | Read from memory |
| Your tactic: formation, roles with and without the ball, your XI | Read from memory |
| Squad planner: one row per slot in your tactic, cover, best position and role | FM's own role ratings |
| Best eleven: your tactic's places and roles with the best the club has in each, against your own picks | FM's own role ratings |
| Optimized tactic and roles: FM's 90 preset tactics fitted to your squad | FM's own files and role ratings |
| Filters, columns, search, shortlists, snapshots, export, themes | Ported |
| Recommendations, planner, bargains, staff tools, club reports | Ported |

Help > Compatibility shows what is working on the build you have.

## After an FM patch

Records are found by class name, so the reader usually keeps working. Its offsets are all in
`Sources/StarshipCore/Reader/MacLayout.swift`. If they move, Load Save's self-check fails rather than showing wrong
data.

The rule functions are found by address, which only holds for one build. `RulesEngine` compares a fingerprint of
`game_plugin` and **refuses to start on any other build**, so those features switch off rather than give wrong
answers. To bring them back, find the new values for the `Mac27` constants in
`Sources/StarshipCore/Emu/RulesEngine.swift`.

The binary is stripped, so the method is to **run every function through the sandbox and keep the ones that reproduce
an answer the game has already stored**. Crashes and wild jumps only stop one emulated call. `tools/scan_a64.py`
extracts the function list, and `fmprobe hunt` / `fmprobe huntmore` do the search.

| Value | How it was found |
| --- | --- |
| `fingerprint` | First 16 hex digits of the SHA-256 of the arm64 slice (`fmprobe fingerprint`) |
| `interestSlot` | `GAME_ACTUAL_PLAYER` vtable; calls with `w3` = 3 or 4 through `ldr x8, [x8, #0xf0]` |
| `interestManagerGlobal` | The `adrp`/`ldr` just before those calls |
| `statusFunction` | The `bl` just before them, followed by `cmp w0, #7` |
| `staffRuleSlot` | Last slot of `PERSON_NON_PLAYER_INTERESTED_FILTER_RULE` |
| `statFunction` | Called most often with `w1` = 84 (Apps) and `w2` = 5 |
| `statsContainerSlot` | The vtable call producing `x0` at those sites |
| `roleInPossession`, `roleOutOfPossession` | `fmprobe hunt ip` / `oop`: the player's stored best role must outrank every other |
| `roleBand` | Right after the in-possession rating; takes (player, rating, team, out) |
| `roleListInPossession`, `roleListOutOfPossession` | `huntmore rolelist3`: most players' top role is in the list for their position |
| `preferredJob` | `huntmore job`: staff with one clear favourite job |
| `injuryInfo`, `bagSet`, `bagClear` | The function that uses key `0x50504d69` with a 4-argument signature |
| `staffNumbersGlobal`, slots | `fmprobe huntlimits`: the per-team tables must add up to the club's real staff |
| `staffModeFlags` | The two bytes the staff-number functions compare against 2 and 3 |
| `shapeName` | Takes eleven sorted place numbers in `x0` and returns a string through `x8`. `fmprobe shapenames` shows when it's right |

The optimizer reads FM's own tactic data from `game_plugin.bundle/Contents/Resources/shared/data/simatch.fmf`, so it follows
patches: the `.tac` presets, `styles.xml` (favoured attributes, preferred roles, features of play) and the role complexity
table. `FMData` reads the container and `.tac` format, and `swift test` checks them against the installed game. Fit is this
app's own blend, not an FM number; the tactics, roles, stars, attributes and complexity are FM's. A preset's role only changes to
one FM uses in that place in that style, and only if FM's presets put it next to the neighbouring roles.

Things FM Starship has that FM Moleman doesn't:

- **Your tactic** is read from `TACTIC_EDIT_SESSION` objects, with offsets in `MacLayout.Tactic`. If they move, the planner
  falls back to FM Moleman's ten position groups, and Help > Compatibility says so. To find them again, search memory for your
  XI's player indexes in order (`fmprobe cluster`), then see which class holds them (`fmprobe census`, `fmprobe fields`).
  `fmprobe tactic` prints what the app read. Stars are the check: FM's tactics screen shows the two phases' average, rounded up.
- **Squad overview and Staff overview** are `OverviewReport`s: each place, how it stands against the league, and the best
  person who'd join. Staff jobs come from FM's own board table, `StaffLimits.Club`. Its entries were matched to jobs by comparing
  them with who holds each job at 600 clubs, which `fmprobe staffmap 7 600` repeats if a patch reorders them.
- **Development** comes from the save, not from a rule of thumb: `DevelopmentCurve` measures how much of their PA players of each
  age have reached, across the world, and projects each young player along their own line. `fmprobe agecurve` prints those lines.
  It also measures the odds of getting close to PA by Determination + Professionalism + Ambition, and by Injury Proneness, from
  everyone aged 25-29. `fmprobe hiddencsv` dumps the numbers behind that. Nothing about this is a formula from the game: the growth
  routine wasn't found. What the code does show: player creation at `game_plugin+0x112c0e4` gives high-PA players a floor for those
  three stats (PA 125+ 8, 150+ 10, 175+ 12) unless a roll skips it, and `+0xd34458` is a one-off jump of 10-20% of CA, capped by PA.
- **Formation names** are FM's, and nothing here works them out. `RulesEngine.shapeName` runs FM's own routine, which answers in the
  language the game is set to, so a custom shape gets its name too. `fmprobe shapenames` tries it on FM's built-in formation table.
  When the rules are off, `TacticLibrary` falls back on the presets in the player's own install, whose file names carry the names
  (`4--4-2-3-1 DM AM Wide _ 4-4-2 2DM - gegenpress.tac`), and a shape no preset uses gets a plain count of its lines: `4-1-1-4-0`.
  The routine reads a language file from disk for an Asymmetric name, which the sandbox can't do, so lopsided shapes are counted too.
- **The dashboard** is `ClubDashboard` plus the two overviews, which it starts itself so their answers are ready when you open them.
- **The look** lives in `AppColors` (colours by job, from a `Theme.Palette`, or the system's for the System theme), `DesignSystem.swift`
  (panels, pills, `Flow`, range bars) and `TableSupport.swift` (both grids). DESIGN.md is the reference. Grids never cut text off: `AnalysisGrid`
  wraps sentences, then scrolls sideways, and `PeopleTable` fits columns to a sample of the rows once per list. `PitchPlan` places cards on a
  pitch without any UI, so `swift test` can hold every shape FM ships to having no overlaps.
- **Currency** comes from `selected_currency` in FM's preferences. It counts a 66-entry list of FM's own, held at
  `game_plugin+0x56c0860` as 32-byte entries of (double rate, ...), which is how `Units.fmCurrencies` was named.

`tools/run-emutest.sh` proves the interpreter still matches the real CPU, so run it after any change there.
`swift test` covers the shortlist and export file formats and the tactic logic.

## Layout

| Path | What |
| --- | --- |
| `agent/` | The library loaded into FM |
| `Sources/CA64` | ARM64 interpreter, verified instruction-for-instruction against the real CPU |
| `Sources/StarshipCore` | Memory access, RTTI, the reader, the data model, the rules engine |
| `Sources/StarshipSearch` | Columns, filters, units, settings |
| `Sources/StarshipAnalysis` | Recommendations, planner, bargains, club reports |
| `Sources/StarshipFiles` | Shortlists, snapshots, export, themes |
| `Sources/FMStarship` | The app |
| `Sources/fmprobe` | Developer probe |
| `Assets` | The app icon and the README's screenshots. `Scripts/make-icon.py` draws the icon, and needs `rsvg-convert` |

Building needs Xcode and Homebrew's `zstd` (`brew install zstd`). It is linked statically, so the finished app has no
Homebrew dependency. `Scripts/release.sh` makes the signed, notarized disk image; the top of that script says what it needs.

## Known limits

- FM keeps some B teams (in Spain and the MLS, for example) as clubs of their own. Best eleven counts a club's players there, but
  other screens show them as on loan, the way FM's data has them.
- Rule functions are tied to one FM build, so expect those features to switch off for a while after each patch.

## Contributing

Bug reports, fixes and ideas are all welcome, and a lot of the work doesn't need FM27. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to
get set up, and the [good first issues](https://github.com/FMStarship/FMStarship/labels/good%20first%20issue) are the place to start.
Questions go in [Discussions](https://github.com/FMStarship/FMStarship/discussions). If you use an AI coding agent, point it at
[AGENTS.md](AGENTS.md).

## Licence

FM Starship is source available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). You can read, use and change it for
free for any noncommercial purpose, but you can't sell it or use it commercially. It isn't an open-source licence in the strict sense.
Much of the code comes from FM Moleman and is shared here with its author's permission.

## Disclaimer

Not affiliated with or endorsed by Sports Interactive or SEGA. Football Manager is a trademark of Sports Interactive
Ltd. No game files, assets or game data are included. Use at your own risk.
