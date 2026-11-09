# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app in SwiftUI with AppKit tables, not a web view. Follow Mac conventions.

A preview plugin also shows some of its screens inside FM27, as an FM STARSHIP tab built from FM's own interface elements and tables. There, FM's conventions win.

## Users

Football Manager 27 players on a Mac, running a club in their own save. The first user manages Molde FK and plays FM in Norwegian; the app may be shared with other FM players later, so a screen has to explain itself to someone who has never seen it.

They are in the middle of a game. FM runs full-screen and they swipe across to FM Starship on the same display, usually laptop-sized, to answer one question, then swipe back. They read several numbers per player and think in CA, PA, stars and roles.

## Product Purpose

FM Starship reads a running FM save and answers the questions FM makes slow to answer: what is wrong with my club, who should I sign, who would actually join, which youngsters are real, and which staff are holding us back. Success is a decision made in seconds, with the reasons visible.

## Positioning

It reads the live game's memory and runs FM's own role and interest rules, so stars, board limits and "would join" are the game's own answers rather than guesses. Talent odds and development curves are measured from every player in the user's own save at each load, and it says where an answer is the app's judgement and not FM's.

## Operating Context

- Load Save reads the game. The app is read-only towards the save and writes only shortlist files when asked.
- Inside FM, the plugin reads the save in FM's own process and never writes it. FM's own right-click menu on its rows acts in the game, as it does in FM's lists.
- Many answers come from asking the game, so results can fill in over seconds.
- Typical window is around 1380 by 830 points. Tables hold 32,000 players, 150 attributes-worth of columns, and club views of 11 to 50 rows.
- FM's own language can differ from the app's English.

## Capabilities and Constraints

- Screens: Players, Staff, My club (health check, set pieces, loan out, development, young talent, training), Squad overview, Staff overview, Squad planner, Recommended signings, Recommended staff, Staff review, Bargains, Open squad, Shortlists, player and staff profiles, Compare.
- Hidden attributes can be switched off, and then nothing hidden may be shown or used. CA and PA are hidden in FM, so they go with them. While Hidden attributes is on, Ability can be shown as numbers, stars or not at all. Off means gone, not dashes: no column, filter, difference, bar or list that only exists because of those numbers. The one exception is CA and PA deciding a rank, a standing or an order ("16th of 16", "Below the league", which recommendation comes first), because those screens have nothing else to go on.
- Users can choose a colour theme in Settings; themes and light and dark mode must keep working.
- Some features need the live game; snapshots and exports work without it.
- Terms: CA, PA, Det, Pro, Amb, role names and position codes are FM's and stay as they are.

## Brand Commitments

The name is FM Starship. It is an independent companion and must not imitate Football Manager's or Sports Interactive's identity. Inside FM, the plugin's screens are made of FM's own elements, style classes and tables, so they sit in the game like its own screens, but the tab is always FM STARSHIP and nothing of FM's ships with it.

It looks like a clean, dark, modern analytics dashboard, with no football costume and no fuss. The user chose this over more characterful directions on 2026-10-31, so keep to the category standard.

## Evidence on Hand

Real data comes from the user's live save. There are no testimonials, customers or benchmarks, and none may be invented.

## Product Principles

- Lead with the answer, then show the reasons.
- Never hide a value: a person reading the screen should not have to widen a column or guess at cut-off text.
- Say where a number comes from, FM or this app, and how sure it is.
- Respect a player's time: one glance, one decision, back to the game.
- Dense is fine; muddled is not.
