# Security

FM Starship loads a small agent into Football Manager and reads the game's memory, so it matters that it does only what it says it does.

## Supported versions

Only the [latest release](https://github.com/FMStarship/FMStarship/releases/latest) gets fixes.

## Reporting a problem

Please don't open a public issue. [Report it privately](https://github.com/FMStarship/FMStarship/security/advisories/new) instead, and
include what you found, how to reproduce it, and the FM Starship and macOS versions you used.

This is a free project run in spare time, so there's no bounty and no promised response time, but every report will be read.

## What counts

- A way for another process or user to reach the agent or its socket
- The agent reading or returning anything beyond what the app asks for, or doing anything other than reading
- Code running in the interpreter that gets out of its sandbox, or that changes the real game
- A file the app opens, such as a shortlist, snapshot or theme, that can crash it or run code
- A release that isn't what the source says it should be

Crashes and wrong numbers after an FM patch are ordinary bugs, so [open a bug report](https://github.com/FMStarship/FMStarship/issues/new?template=bug_report.yml)
for those.
