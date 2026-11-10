# Changelog

What's new in each version of FM Starship. Versions up to 27.0.5 are on the
[Releases](https://github.com/FMStarship/FMStarship/releases) page.

## Unreleased

- **FM Starship inside FM, as a preview.** A plugin adds an FM STARSHIP tab to FM27's top bar, with the Dashboard, Recommended
  signings, Bargains, the Squad planner, Shortlists, Players and Staff. Its screens are made of FM's own interface elements, and its
  lists are FM's own player and staff tables: names open FM's profiles, every column sorts, and FM's right-click menu works on the
  rows, acting in the game as it does in FM's lists. Recommended signings and Bargains have an Edit Search like FM's. The plugin
  never writes your save. It isn't in the disk image yet, so build it from the source with `Scripts/install-plugin.sh` and set the
  Steam launch option it prints, as the README explains. It has been tried on FM 27.0.1.2494769, the full release.
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
