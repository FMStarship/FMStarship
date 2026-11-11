## What changed

<!-- What does this do, in a sentence or two? A screenshot helps if a screen changed. -->

## Why

<!-- What problem does it solve? Use "Closes #123" if there's an issue. -->

## Changelog

<!-- The line for players, as it should read under Unreleased in CHANGELOG.md, or "none" if players see no change. Don't edit CHANGELOG.md in the PR: the maintainer adds the lines. -->

## How you tested it

<!-- CI has no FM and no save, so say what you checked by hand, and what you couldn't check. -->

- [ ] `swift test` passes
- [ ] Checked in the app (say which screens, and whether with a live save or a snapshot)
- [ ] Checked inside FM with the plugin, if this touches the plugin (say which screens)
- [ ] Ran `tools/run-emutest.sh`, if this touches `Sources/CA64`

## Checklist

- [ ] With Hidden attributes off, nothing hidden shows, and CA and PA are gone, including in exports
- [ ] It adds no game files, saves, snapshots, Sports Interactive assets or code decompiled from FM
- [ ] The docs are updated if behaviour changed
- [ ] An AI tool helped with this, and I've read and tested the result (leave unticked if not)
