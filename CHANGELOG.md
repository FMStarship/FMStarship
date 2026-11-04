# Changelog

What's new in each version of FM Starship. Versions up to 27.0.5 are on the
[Releases](https://github.com/FMStarship/FMStarship/releases) page.

## Unreleased

- **Doubtful and Persuadable players count as willing to join.** "Would join" used to mean only players FM calls Interested. It
  now also takes in FM's Persuadable and Doubtful players, the levels FM's own recruitment search offers. Recommended signings,
  Bargains, Squad overview, the Squad planner and the "Would join you" filter all find more players, though the less keen may want
  a higher wage. A player's profile shows FM's word for how keen they are, for a transfer and for a loan.
- **Players at clubs without a manager.** FM Starship couldn't work out whether players at clubs with no manager would join, so it
  left them out of every "would join" list. On a test save that was about 1,500 players. It now gets FM's answer for them.
- **Free agents FM no longer has.** FM can keep an old copy of some players in memory. A free agent who only existed there could
  show in the Players list as someone you could sign, and checking whether he'd join never finished. Those players are now left out.
