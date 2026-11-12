# Changelog

What's new in each version of FM Starship. Versions up to 27.0.5 are on the
[Releases](https://github.com/FMStarship/FMStarship/releases) page.

## Unreleased

- **Add FM Starship to FM from the app, without Xcode.** FM Starship > Add FM Starship to FM… copies the plugin and its launcher
  into place and shows the Steam launch option to set, with a Copy button and the steps. If you added a build you made yourself, it
  asks before replacing it. The app carries both, notarized with it, and refreshes the plugin it installed when it updates.
  FM Starship > Remove FM Starship from FM… takes it away again.
- **Remove keeps the launcher.** Removing FM Starship from FM takes away the plugin and FM's table files but leaves the launcher, so
  Steam still starts FM if the launch option is still set. FM then starts without the FM STARSHIP tab. Clearing the launch option is
  still recommended, and Add puts everything back.
- **Position columns sort in FM's order.** Clicking a Position column now goes goalkeeper first, then each line from right to left
  (DR, WBR, DC, DL, WBL), then DM, midfield, attacking midfield and strikers, as FM's own lists do. Columns of a player's positions
  go by the position they're rated best at; columns of places in a tactic go by the place, so DC (R) comes before DC (L).
- **Ability inside FM.** The FM STARSHIP tab has an Ability dropdown beside its Hidden attributes switch, for showing CA and PA
  exactly, as stars, or not at all. It sets the same setting as the app's toolbar, and every screen is drawn again when it changes.
  While Hidden attributes is off, it says Off and can't be changed, as in the app.
- **Both settings moved to each screen's title row** inside FM, at its right. In the row of screen names they squeezed the names
  until they wrapped.
- **A menu on the FM STARSHIP tab.** Like FM's own tabs, it has an arrow beside its name. Hovering it opens a menu of its seven
  screens, from any of FM's screens, and FM dims the rest of its screen as it does for its own menus. Choosing one opens the tab on
  that screen. Like FM's, the menu goes as soon as the pointer leaves the arrow and the menu.
- **Role, not Stars.** In the Squad planner's first team, Best eleven and Optimized tactic and roles, the column of FM's stars for
  each player in the role at their place is now called Role, in the app and inside FM. Inside FM, in Stars mode, CA and PA are
  called Ability and Potential, as FM's own star columns are, so the two kinds of stars no longer look like the same column twice.
- **FM's own stars inside FM.** In Stars mode, Ability, Potential and Role are drawn as FM's yellow stars, with room for all five,
  and they sort by stars. They're FM Starship's values, on its own scale, where CA 200 is five stars.

## 27.0.6

- **Works with FM27's full release.** FM's launch update (27.0.1.2494769) moved the game functions FM Starship runs for "would
  join", role stars, season stats, staff numbers, injury days and formation names. They're found again on the new build, and
  checked in FM with a live save.
- **FM Starship inside FM, as a preview.** A plugin adds an FM STARSHIP tab to FM27's top bar, with the Dashboard, Recommended
  signings, Bargains, the Squad planner, Shortlists, Players and Staff. Its screens are made of FM's own interface elements, and its
  lists are FM's own player and staff tables: names open FM's profiles, every column sorts, and FM's right-click menu works on the
  rows, acting in the game as it does in FM's lists. Recommended signings and Bargains have an Edit Search like FM's. The plugin
  never writes your save. It isn't in the disk image yet, so build it from the source with `Scripts/install-plugin.sh` and set the
  Steam launch option it prints, as the README explains. It has been tried on FM 27.0.1.2494769, the full release.
- **Reading FM is much quicker.** The agent now sends FM's memory in larger pieces. FM's own rules run faster in the interpreter,
  and FM is asked whether a player would join once per read rather than once per screen. On a 34,000-player save, a full read
  with season stats now takes about 5 seconds. You get the agent's part after updating and starting FM from FM Starship again.
- **Less work while FM runs.** FM Starship no longer looks through every process on the Mac every two seconds to find FM, and
  inside FM it doesn't look at all. Search lists are built in the background after a read.
- **Inside FM, the preview plugin is steadier:**
  - **On an FM build it hasn't been checked on,** it turns off what doesn't fit and says so, rather than crash or leave FM's
    screen blank.
  - **If the plugin is missing,** FM still starts from Steam, and `Scripts/install-plugin.sh --uninstall` removes it.
  - **After Load Save, a new day or a match,** the FM STARSHIP tab reads your save again, so it never shows another save's players
    or old figures.
  - **When FM quits,** the plugin stops cleanly.
  - **It does less on FM's main thread.**
- **A Hidden attributes switch inside FM.** The FM STARSHIP tab has its own Hidden attributes switch. Switching it, or the app's
  eye, redraws every screen at once, so no CA, PA or other hidden value is left showing.
- **Lists say why they're empty.** A list with nobody in it now says why: for example, that young signings are picked on PA,
  which is off.
- **Read timings in the log.** The app writes how long each part of a read takes to `~/Library/Logs/FM Starship/app.log`, to help
  find what makes a read slow.
- **Doubtful and Persuadable players count as willing to join.** "Would join" used to mean only players FM calls Interested. It
  now also takes in FM's Persuadable and Doubtful players, the levels FM's own recruitment search offers. Recommended signings,
  Bargains, Squad overview, the Squad planner and the "Would join you" filter all find more players, though the less keen may want
  a higher wage. A player's profile shows FM's word for how keen they are, for a transfer and for a loan.
- **Players at clubs without a manager.** FM Starship couldn't work out whether players at clubs with no manager would join, so it
  left them out of every "would join" list. On a test save that was about 1,500 players. It now gets FM's answer for them.
- **Free agents FM no longer has.** FM can keep an old copy of some players in memory. A free agent who only existed there could
  show in the Players list as someone you could sign, and checking whether he'd join never finished. Those players are now left out.
- **The transfer budget is what's left to spend.** FM Starship read the budget as the board last set it, not what FM shows as
  Available after the season's signings and sales. On a test save it showed Kr 30.12M where FM had Kr 9.01M left, so the Squad
  planner and Squad overview could pick signings you couldn't pay for. The Dashboard, Squad overview, the Squad planner and
  Bargains' max fee now use FM's figure.
- **Money is cut off, not rounded.** FM cuts figures in millions off, so a budget FM shows as Kr 9.01M read Kr 9.02M here. Money
  is now cut off the same way, and Bargains' max fee and the staff wage box no longer start above what you have.
