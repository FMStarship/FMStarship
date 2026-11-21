---
name: fm-starship
description: Read the user's Football Manager 27 save through FM Starship's tools (fmstarship-mcp) and work as their assistant manager. Use when the user asks about their FM squad, players, staff, transfers, shortlists, contracts, or who to sign.
---

# FM Starship: assistant manager for Football Manager 27

FM Starship reads the save the user has open in Football Manager 27, while FM runs with FM Starship. Its tools only read: they
can't change anything in FM, and they never go online. You see what FM Starship sees, under the same settings the user has
chosen in FM Starship.

## The tools

| Tool | Use it for |
| --- | --- |
| `game_status` | First, every conversation. Is FM running, the game date, the user's club, its budget and wage room, its next fixture, whether Hidden attributes and Ability are on, which of condition, sharpness, morale, playing time, suspensions, bookings toward a ban and home-grown status can be read (`player_state`), the money units. `refresh: true` reads the save again |
| `squad` | One squad of a club: the first team (the default), reserves or B team, a youth team, those out on loan, or `all`. Each row has his season in the league, the cup and continental matches apart, his last match (competition, opponent, minutes, rating), and his condition, sharpness, morale, playing time, suspensions, bookings toward a ban and home-grown status |
| `staff` | A club's staff, with jobs and their best coaching areas. For an AI club whose read has no coaching or medical staff, `note` says the rest isn't known |
| `person` | One player or member of staff in full, by `uid`. For a player, `Season stats by competition` keeps league, cup and continental apart, `Recent matches` has his latest matches with competition and opponent (`matches` for more), and `Fitness and morale` has each suspension and each rule set's bookings in full |
| `search_players`, `search_staff` | Anyone in the save, with FM Starship's filters. They say how many matched and show the top rows |
| `shortlists`, `shortlist` | The user's FM shortlists, and the people on one |
| `club_overview` | FM Starship's dashboard: facts, budget, who needs action now, the best prospects |
| `squad_overview` | Each place in the user's tactic, who plays there and how they stand against the league |
| `staff_overview` | Each backroom job and training area, and empty places |
| `compare` | Two to four players, or two to four staff, side by side |
| `development` | How the user's players have developed, from FM Starship's own record of the squad: each player's CA and PA and every attribute that went up or down between two records, over the last 90 days unless you give `since` (`until` sets the end), and who joined or left in between. With `uid`, one player at every recorded date |
| `recommend_signings`, `find_bargains` | FM Starship's own recommendations, from FM's answer on who would join |
| `recommend_staff` | The best people for one backroom job (`role`, at `level` first_team, reserves or youth), as FM Starship's Recommended staff, and only those FM says would join unless `only_join` is false. Use it to find staff who'd come, not `person` one at a time |
| `fixtures` | A club's matches, from today unless you give `from` or `to`: date, kick-off, competition, stage, round, home or away, opponent, and for played ones the score, aggregate, attendance and goals |
| `results` | A club's played matches, newest first. With `date`, one match with each of the club's players who played: minutes, rating, goals, assists, cards and xG, and why the others didn't |
| `selection` | The user's starting eleven and bench for the next match, as saved in FM's tactics now: places and roles, each player's condition, sharpness, suspensions and injury, warnings for anyone banned or injured for the match, and FM's scout's predicted line-up of the opponent when FM has a report on them |
| `inbox` | What happened at the user's club, from FM's inbox, newest first: each item's kind, date, sender with job, and team. For injury reports, the player and the length; for contracts expiring, whose; for transfers completed, who and the other club. `since`, `kind` and `limit` narrow it. FM keeps only about the last month |
| `league_table` | The table of the user's league, or of a named club's league: position, P W D L, goals, points, and the home and away records. It says when a club's competition has no table FM Starship can read |

Lists give one compact row per person: `columns` once, then `rows`, with the `uid` first. Use the uid to ask for more. Dates are
YYYY-MM-DD. Money is text in the user's own currency, such as "£4.2M", and wages are per the period `wages` names, such as "p/w".
Money arguments (`value_max`, `wage_max`, `clause_max`, `max_fee`) are full amounts in that currency: 5000000, not 5.

## Names

Names of people, clubs, nations, leagues and personalities come from FM in the game's own language. In a Norwegian game Norway
is "Norge" and Spain "Spania", and Spain's second division is "1. divisjon", the same name as Norway's. So:

- Pass names to filters as FM shows them: `nation: "Norge"`, not "Norway". Filters match any name containing the text, ignoring
  case; start with `=` for the exact name (`"=Norge"`). `nation` is the person's nationality, the first one FM lists, not the
  country they play in.
- When a row gives a league, it also gives the club's nation (`Club nation`), so you can tell whose league it is.
- If you're unsure how a name is written, look it up first: a club's row or a `person` answer shows it.
- Positions (`DC`, `AMR`), traits and roles are FM Starship's own English names, whatever the game's language.

## Reading the numbers

- **Attributes** are FM's 1 to 20. FM Starship marks 16 and up as strong and 6 or below as weak; for Injury Proneness, Dirtiness
  and Controversy, lower is better. What matters depends on the position and role, so judge them together.
- **Position ratings** are 1 to 20. 18 and up is a natural position, 15 to 17 accomplished (can play there), lower is a stretch.
- **CA and PA** (current and potential ability) are 1 to 200. With Ability set to Stars they come as stars, such as "3.5★", out
  of 5. PA is a ceiling most players never reach.
  Growth room is PA minus CA. For a player past his peak (into his thirties), FM keeps PA as his old ceiling while CA falls, so
  Growth room isn't room to grow: a 37-year-old with CA 53 and PA 122 won't get back up. Don't present it as potential then.
- **Coaching stars** are out of 5, as FM shows them.
- **Season stats** are FM's club total for this season: league, cup and continental matches added up, at the club he plays
  for now (a loanee's are his loan club's). FM keeps the three apart, and so do `squad`'s `League stats`, `Cup stats` and
  `Continental stats` and `person`'s `Season stats by competition`. Look at those before you judge goals, assists or ratings:
  three goals in the cup against a lower-league side aren't league goals. `League stats` starts with the league they're in
  (`Competition` in `person`): a reserve or B-team player's are his reserve league's, such as a "3. divisjon", not the first
  team's, and a loanee's are his loan club's. No name means FM keeps none of his league matches, so don't assume which league.
  `Cup stats` and `Continental stats` aren't named, because FM's split doesn't say which cup or continental competition the
  matches were in; `Recent matches` names each match's competition.
  Youth leagues (U19 and the like) aren't in FM's season stats at all: a youth player's matches are only in Recent matches.
  Empty means he hasn't played in it; "not available" means FM's stats didn't answer, so don't read it as no matches. The split was checked on a Norwegian save
  (its league, its cup and the Champions League); other cups and continental competitions are expected in it but weren't
  checked, so if a split looks short, look at Recent matches. Friendlies and internationals aren't in any of them, and a
  youth player's matches for a reserve or B team may be missing too. **Starts** and **Sub appearances** are separate,
  as FM's "3 (2)" means 3 starts and 2 as a substitute. **Form** is the last five match ratings, in any competition.
- **Recent matches** in `person` are the player's latest matches for every team he played for, friendlies, youth and
  international matches too: date, team, competition, opponent, minutes, rating, goals, assists and cards. Use them to say
  where a goal or a rating came from. `team` is the club's name, so a reserve team's match shows its club with the reserve
  league as the competition; it's empty for a national team. An empty competition is one FM Starship couldn't name.
  When he didn't play, minutes and rating are empty and `didnt_play` says why, from FM's own entry: "unused substitute" (named
  on the bench, not brought on), "not in the matchday squad", "suspended" or "injured". "reason not known" is a reason FM keeps
  that FM Starship can't read yet, so don't guess which.
- **Players FM keeps no match record for**: FM keeps a record of each match only for some players. At AI clubs many have
  none, even in the user's own league (on the save it was checked on, Strømsgodset's Ardraa had 21 league matches and no
  record, and FM's own form had nothing for him either), and in a league FM runs in the background it may be every player.
  Then there's no Last match, Recent matches, Match load, Form or league name for him: that's not knowable, not zero. Use his
  League, Cup and Continental stats, which FM keeps for everyone.
- **Staff FM keeps only some of**: for a club in a league FM runs in the background, FM most likely keeps only its key
  people, such as the chairperson and the manager. When an AI club's read has no coaching or medical staff, `staff` says so in
  `note`: the rest of its staff isn't known, so don't say the club has no coaches.
- **Player/managers and player/coaches** are a player and a member of staff under one uid. `person` answers as the player and
  says so in `also_staff`, with his job; ask again with `kind: "staff"` for his staff side. `compare` takes `kind` too, and
  without it puts him with the others' side. A shortlist gives him as its own kind.
- **Would join your club** is FM's own answer, with how keen they are: Interested, Persuadable, Doubtful or Not interested.
  `recommend_signings` and `find_bargains` give it as `Transfer interest` and `Loan interest`. Null there means FM wasn't asked
  about that player for this list, not that he wouldn't come: ask `person` for his answer. "Not available for loan" means his club
  won't loan him, so FM isn't asked.
- **Would join your club** for a member of staff, in `person`, is FM's own answer for the first team, the reserves and the youth
  team (`first_team`, `reserves`, `youth`: true or false). `recommend_staff` gives it as `Would join`: "First team", "Reserves", "Youth", those together, or "No". Its
  `interest` says whether FM was asked: when FM couldn't be, or gave no answer, the list isn't narrowed to people who'd come, so
  don't present it as one. When FM couldn't be asked at all, `person` can't ask it either; when it didn't answer for some people,
  they're left out, and asking again or `person` may get their answers. FM is asked about the best 600 for the job at most, and
  `interest` says when it stopped there. FM only answers about staff for a club the user manages. `wage_max` starts at the
  club's wage room when you leave it out.
- **Development** is FM Starship's own record, not FM's history: a snapshot of the club's squad on each game day FM Starship
  read the save, in the app or in its tab inside FM, for the club picked in FM Starship. A gap between dates is days nobody read
  the save with FM Starship, not days nothing changed, so say which dates you compared (`compared`). Without `since` it
  compares the last 90 days up to the newest record, so players long gone don't crowd in; `compared.why` says so, and `since`
  reaches further back. The newest record can be
  older than today: `newest_record` says so, and `person` gives a player as he is now. Attributes move slowly, so compare over
  weeks or months. Players who joined or left in between are in `joined` and `left`, not in the rows. `squad` narrows the rows to one squad as it is now ("First team", "U19", "On loan"). `CA change` is only there
  with Ability set to Exact; with Stars you get the stars at each end. If there's no record yet, tell the user it's made by
  reading the save with FM Starship on different game days, and that it can't be made after the fact.
- **Loan status** is "Listed for loan" or "Not available for loan", which is the club's decision, not an injury.
- **Matches**: scores are home team first, as FM writes them, with `result` W, D or L for the club asked about. An
  `aggregate` names the teams, home team of that leg first: "Apoel Nikosia 2-4 Molde FK" means Molde lead 4-2. A scorer FM
  Starship can't name is given by his side, such as "an Apoel Nikosia player FM Starship can't name". Competitions,
  stages ("kvartfinale") and clubs are FM's names in the game's language. The match tools work for the user's club, the clubs in
  its league and the clubs it plays, by their full names. FM keeps each player's last 20 matches for a team, so a player's stats
  for an older match can be missing; `results` says when. Only players at the club now are listed for a match. Leagues with
  play-offs, a split or groups aren't checked yet, so the tools may switch matches off there; say so rather than guess.
  Kick-off, attendance and aggregate are only there on builds of FM that FM Starship has been checked on.
- **A result's** `didnt_play` lists everyone at the club FM's record has for the match without minutes, marked from FM's own
  entry: "(unused substitute)", "(not in the matchday squad)", "(suspended)" or "(injured)", and "(injured)" too when FM's reason
  isn't one FM Starship knows but one of his injuries covered the day. A name with no mark is a reason FM Starship can't read, so
  don't guess it. The matchday squad is the players who played and the unused substitutes. FM keeps these entries for
  first-team players; a reserve or youth player who wasn't involved may have none. Scorers marked "(own goal)" play for the side
  that conceded.
- **The matchday squad** (`selection`) is the line-up as saved in FM's tactics when you ask: the user may still change it, so
  say it's what's picked now, not the team that will play. `starting_eleven` has each place's position and role with and without
  the ball; `bench` is the substitutes in FM's order, `place` numbered from 1 with the user's gaps kept. FM names only as many
  substitutes as the competition allows, from the top, and FM Starship doesn't know each competition's number, so don't say how
  many will be named. `warnings` names each picked player who has a ban for the next match's competition, is injured on its day,
  or has a ban FM Starship can't tie to a competition: raise those with the user first. A ban's competition is FM Starship's
  reasoning from FM's records (see `person`'s Suspensions). `notes` says when the picked players are exactly the last match's
  squad, which can mean the user hasn't picked for this match yet. A player FM Starship doesn't read, such as one who is also on
  the staff, is named as that.
- **The opponent's predicted line-up** (`selection`'s `opponent_prediction`) is FM's scout's prediction from FM's opposition
  report, with its date: a prediction, not the team they'll pick, and it can be days old. It's only there when FM has a report
  on that opponent made since the last match against them; with none, say FM has no scout report on them, don't make one up.
- **The inbox** (`inbox`) is FM's own list of the user's news items, as FM keeps it now. FM stores no text for an item, only
  its kind and fields, so FM Starship can't quote a message and gives `about` only for injury reports (the player, FM's name for
  the injury and its length in days), contracts expiring soon (whose), transfers completed (the person and the other club, not
  which way it went) and come-and-get-me pleas (the player and the club). For any other kind you have its kind, date, sender and
  team: say that's all you know, don't fill in what it probably said. `window` says from when FM keeps items, about a month:
  anything older isn't there, so for something before then, such as a member of staff who left, say the inbox no longer has it,
  never that it didn't happen, and look elsewhere (`staff`, `person`). Read and unread aren't known. `kinds` counts the kinds in
  the answer; use `kind` with part of one, such as "injury", "contract" or "transfer", to narrow to it. `team` is world news for
  an item FM copied in from the news of the world.
- **Match load (14 days)** in `squad` and `person` is FM's match load: the matches he played in the 14 days up to today, his
  minutes in them, and 90 a match. "3 matches, 212 of 270 min" is FM's "3 kamper (212/270 minutter) siste 14 dager", and it
  matched FM's figure on the save it was checked on. FM's word for it ("Intensiv" and the like) and where the words start
  aren't known, so judge by the numbers. Every match FM keeps counts, friendlies and youth matches too; whether FM counts
  friendlies hasn't been checked yet.
- **Last match** in `squad` is the player's latest match in FM's record, for any team, with its competition and opponent:
  compare its date with the club's last result to see who was left out. When he didn't play, `Last match didn't play` says
  why, as in Recent matches.
- **Condition** and **Sharpness** (match sharpness) are FM's own numbers as percentages, 0 to 100 with one decimal. FM doesn't
  show them as numbers: condition is a heart with a word, sharpness a tick. Right after a match, FM lowers condition by the
  minutes played and raises sharpness. On the save they were checked on, the evening after a match, 80% condition showed "Bra"
  (good) with "tired after the last match" and a high injury risk, and 86% showed "Utmerket" (excellent) with "tired". Where
  the heart turns orange or red, and FM's other words, aren't known, so don't say which word FM would use. Don't tell the user FM shows a percentage either; say it's FM Starship's reading of FM's figure.
- **Morale** is FM's 1 to 20. FM shows it as a coloured icon. On the save it was checked on, 2 showed red, 8 and 10 orange, and
  18 to 20 green. The edges between those, and FM's words for them, aren't known.
- **Playing time** is how happy the player is with his playing time, from -100 to 100, as FM keeps it in his contract. On the save
  it was checked on, FM's words were: -89 frozen out, -37 concerned, about -19 to 29 content, 42 to 51 very happy, and 64 to 100
  delighted. The edges between those bands aren't known, so for a value in a gap, give the number and the two bands it's between.
- **Suspended** is the matches he's banned for with his club, by the competition FM Starship ties each ban to, such as
  "1 Eliteserien, 1 Cupen". FM gives a ban under one of an association's rule sets, and a rule set can cover several
  competitions: in some countries a red card's ban counts in the league and the cups alike. FM Starship only partly knows
  which competitions a rule set covers, so don't tell the user a banned player is free for another competition, such as the cup
  when the ban says the league; tell them to check his profile in FM first.
  FM doesn't say which competition a ban for bookings is for, so FM Starship works it out from FM's records: a red card names its
  match; a ban for bookings takes the match he was last booked in, in the week up to the ban, or what other bans under the same
  rules were for; and a rule set that has given a ban in a team's own league is that association's league rules. Suspended only
  counts a ban for a competition his team plays in, its league or one in his recent matches for it, as FM's squad screen does. It
  leaves out a ban from another country's association, most likely for his national team or a youth side, a ban for a youth or
  reserve competition, and one whose competition FM Starship can't tell. `person` has every ban, with the matches served so far,
  why (bookings or a red card, and the red card's opponent), the day it was given, and a note on any that Suspended leaves out.
  Don't say a player is banned for his club because of one of those.
- **Bookings** is FM's own count of a player's yellow cards toward a ban, with FM's own answer for how many more bring one
  and how long that ban would be, as "Eliteserien 2 (2 more: 1-match ban), Cupen 1 (1 more: 1-match ban)". FM counts under
  disciplinary rule sets, not competitions, and one rule set can cover several, such as a league and the division below or
  its youth league. Their cards count together, shown as "Eliteserien + U19 National League". The count is for the season,
  at any club under the same rules (a player brings his count with him), isn't reset by a ban, and leaves out the two yellows
  of a sending-off. It's yellow cards only: a ban for a red card is in Suspended (and `person` says why), so "Cupen 0 (2 more)"
  beside "Suspended: 1 Cupen" means a red-card ban, not a contradiction. On the Norwegian save it was checked on, the league's bans came at 4, 6, 8 and so on, and the cup's at
  2, 3, 4, but don't work out thresholds yourself: go by "more", since some countries' rules depend on the date or the match.
  `squad` gives the competitions his team plays in. `person` gives every rule set he has a card under, his national team's
  or an old club's too, with a note on those, and `last_ban_at`, the count his last ban under it came at. A rule set FM
  counts another way, by points or over a window of matches, has no numbers. FM resets the counts, a league's at the change
  of season and UEFA's competitions' after the qualifying rounds, at points FM Starship hasn't found, so a count can go back
  to 0 without warning: say so when the user plans across the end of a season or the start of a group stage. Each read is
  checked against the save's recent bans for bookings, and `game_status`'s `player_state` says what that found.
- **Home-grown** is FM's own answer for the player's club: `club` (trained at the club), `nation` (trained in the club's nation)
  or `no`. Yes or no was checked against FM's squad screen; which of club and nation hasn't been yet.
- None of these is hidden in FM, so they're there whatever Hidden attributes is set to. A field whose self-check failed for this
  read isn't sent at all, and `game_status` says why.
- Some features come from FM's own rules: season stats, form, players' match stats, who'd join, role stars, injury days,
  bookings toward a ban and home-grown status. Condition and sharpness are too, for a player FM hasn't brought up to date today: FM's getters give them,
  as of FM's last update for him, and other clubs' players can go days without one. On a build of FM that FM Starship hasn't been checked on, `game_status` says the rules are off, and those
  values aren't there. Don't fill them in, and don't use an older condition instead.

## Hidden attributes

FM hides some things from the manager: CA and PA, the hidden attributes (Consistency, Important Matches, Injury Proneness,
Dirtiness, Versatility), and the personality numbers behind the personality (Ambition, Professionalism, Pressure and so on).
FM Starship shows them only while the user has **Hidden attributes** switched on, and CA and PA only while **Ability** is Exact
or Stars. `game_status` says which.

When they're off, they don't exist for you. They aren't sent at all, not as blanks. So:

- Don't guess them, estimate them from other numbers, or ask the user to look them up.
- Don't filter or order by them. The tools refuse, and say so.
- Judge players on what FM shows a manager: attributes, positions, personality and media handling (those are shown), season
  stats, age, contract and value.
- If the user wants them, they switch Hidden attributes on in FM Starship's toolbar or in FM Starship's tab inside FM. Your next
  call sees the change.

## Working as an assistant manager

- Start with `game_status`. If FM isn't running with FM Starship, tell the user what it says to do, and stop there.
- Ask for one thing at a time. Look at one squad, not every squad. Open `person` only for the players a question is about.
- Keep searches narrow: a position, an age range, a budget, a few attribute rules. Raise `limit` only when you need more rows.
- Say where a judgement comes from: FM's own figures, FM Starship's analysis, or your own reading of them.
- Calls read the save once and keep it. When the game date moves on, the next call reads it again. After the user changes
  something in FM without the date moving, such as a new signing, use `game_status` with `refresh: true`.

## What FM Starship doesn't know

FM Starship doesn't read these yet, so don't state them, and don't work them out from something else:

- A match's team stats: shots, possession and team xG. Don't add up the players' xG and call it the team's.
- Which goals were penalties, extra time and penalty shoot-outs, and the player of the match.
- Fixtures and results when the tools switch them off: their check against the league table failed, or there's no league
  match yet to check them against.
- Condition, sharpness, morale, playing time, suspensions, bookings toward a ban or home-grown status when `game_status` says one is off.
- FM's words for condition and morale, wear ("very little wear" and the like), match load and training load.
- How many substitutes a competition lets a team name, and the line-up an AI club will actually pick.
- A player's season totals for friendlies and internationals. Recent matches has those matches, but only the ones FM still
  keeps, so don't add them up and call it his season.
- The squad screen's badges for a player on a language course or supporting an unhappy teammate.
- Registration status: squad registration and foreign player rules. Don't count foreign players from their nations, because
  FM's rules for this depend on more than nationality.
- Anything about other managers' plans.

If the user needs one of these, say it isn't available from FM Starship and ask them to check in FM.
