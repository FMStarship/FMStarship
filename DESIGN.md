---
name: FM Starship
description: A clean, dark analytics dashboard for a running Football Manager save, native to the Mac.
colors:
  ground: "#0F1115"
  rail: "#14171D"
  panel: "#171A20"
  line: "#262B35"
  hover: "#1E222A"
  selection: "#223258"
  text: "#E8EBF1"
  muted: "#9AA3B2"
  accent: "#3D6CF0"
  on-accent: "#FFFFFF"
  growth: "#8BABFF"
  good: "#3ECF8E"
  warning: "#F2C14E"
  bad: "#F2828A"
  hidden: "#F2A65A"
  star: "#E8B830"
  level-natural: "#2ECC71"
  level-accomplished: "#F4D03F"
  level-competent: "#E67E22"
  level-unconvincing: "#E74C3C"
typography:
  display:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "22px"
    fontWeight: 600
  lead:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 400
  figure:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    fontFeature: "tnum"
  headline:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 700
  body:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
  callout:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
  table:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    fontFeature: "tnum"
  table-strong:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 700
    fontFeature: "tnum"
  label:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 500
rounded:
  skeleton: "4px"
  card: "6px"
  notice: "8px"
  panel: "10px"
  pill: "999px"
spacing:
  hairline: "1px"
  cell-gap: "6px"
  row: "8px"
  gap: "12px"
  inset: "14px"
  gutter: "16px"
  fact-gap: "24px"
components:
  panel:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    rounded: "{rounded.panel}"
    padding: "12px 14px 8px"
  pill-good:
    backgroundColor: "#3ECF8E24"
    textColor: "{colors.good}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  pill-warning:
    backgroundColor: "#F2C14E24"
    textColor: "{colors.warning}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  pill-bad:
    backgroundColor: "#F2828A24"
    textColor: "{colors.bad}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  pill-growth:
    backgroundColor: "#8BABFF24"
    textColor: "{colors.growth}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  pill-quiet:
    backgroundColor: "#9AA3B224"
    textColor: "{colors.muted}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  grid-pill:
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "0 8px"
    height: "18px"
  grid-header:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.muted}"
    typography: "{typography.label}"
    height: "28px"
  grid-row-people:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    typography: "{typography.table}"
    height: "24px"
  grid-row-report:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    typography: "{typography.table}"
    height: "26px"
  grid-row-hover:
    backgroundColor: "{colors.hover}"
  grid-row-selected:
    backgroundColor: "{colors.selection}"
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    typography: "{typography.body}"
  sidebar-item:
    backgroundColor: "{colors.rail}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
  sidebar-item-active:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    typography: "{typography.headline}"
  range-bar-track:
    backgroundColor: "{colors.line}"
    rounded: "{rounded.pill}"
    height: "6px"
  range-bar-now:
    backgroundColor: "{colors.growth}"
    rounded: "{rounded.pill}"
    height: "6px"
  range-bar-tick:
    backgroundColor: "{colors.text}"
    width: "2px"
    height: "12px"
  pitch-card:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    typography: "{typography.callout}"
    rounded: "{rounded.card}"
    padding: "4px 5px"
  position-dot:
    textColor: "#000000CC"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    size: "30px"
  progress-card:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.panel}"
    padding: "8px 14px"
---

# Design System: FM Starship

## Overview

**Creative North Star: "The Category Standard, Played Straight"**

FM Starship looks like the best dark analytics dashboards, applied to a football club. Its users swipe across from full-screen FM to answer one question and swipe back, so nothing in the system performs. Three stepped neutral surfaces carry everything, status sits in small tinted pills, and the answer comes first in a plain sentence, with the reasons in rows below it.

It is dense on purpose. Tables hold 32,000 players at 12pt, yet every grouped thing sits in the same panel, every row is split by the same hairline, and every number lines up on tabular digits. Colour is rationed by job, so an amber value, a red pill and a blue bar each mean one thing wherever they appear.

This system is for the app's own windows, which Control-Option-S also opens over FM. Inside FM, the plugin's screens don't use it: they're made of FM's own interface elements, style classes and tables, and copy the look of FM's tiles, so they read as part of the game around them.

Everything is a job, not a hue. The colour tokens below are the default Starship palette. Nineteen other palettes and a System option fill the same jobs, including light ones, and macOS semantic colours stand in under System. New UI asks for a job and works in all of them. The app is native: system type, Mac controls, a real sidebar and toolbar. It is independent of Football Manager and does not borrow that game's identity.

**Key Characteristics:**
- Neutral near-black ground, with the sidebar one step lighter and panels one step lighter again.
- One accent for primary action and selection, and one lighter blue for development.
- Five native type sizes, tabular numerals, sentence case throughout.
- Hairlines instead of stripes, borders and tone instead of shadow.
- Football appears as information only: a line-drawn pitch, drawn stars, FM's own terms.

## Colors

Cool neutrals with a restrained set of saturated tones, each assigned to one job and sourced from the active palette through `AppColors`.

### Primary
- **Signal Blue** (#3D6CF0): Fills only. The sidebar's current screen, the selected segment, the default button and the prominent Load Save on the welcome screen. White on it measures 4.56:1. It is too dark to read as text on a panel (3.82:1), which is why Development Blue exists.
- **Selection Navy** (#223258): The selected table row. Text stays readable on it (10.56:1).

### Secondary
- **Development Blue** (#8BABFF): Someone on their way up. Range bars, the Developing pill, and outlook and advice lines. Lighter than the accent because it has to work as text (7.77:1 on a panel). Each named palette takes its accent here; only Starship separates the two.

### Tertiary
- **Good Green** (#3ECF8E): Among the best, gains, strong attributes of 16 and up, a likely-to-get-there verdict.
- **Watch Amber** (#F2C14E): Something to keep an eye on: below the league, no real cover, an expiring contract. Palettes whose `fair` is not warm take their `hidden` colour for this job.
- **Soft Red** (#F2828A): Nobody there, not good enough, long-term injury.
- **Hidden Orange** (#F2A65A): Marks anything hidden in the game: attribute values, the headings of hidden columns, Pro/Det/Amb lines. When Hidden attributes is off, neither the data nor this colour appears.
- **Star Gold** (#E8B830): Stars and nothing else. #B08000 on light palettes.
- **FM Level Colours** (#2ECC71, #F4D03F, #E67E22, #E74C3C): Natural, Accomplished, Competent and Unconvincing on the position pitch, always with their legend. These four are fixed across every palette and carry dark text.

### Neutral
- **Ground** (#0F1115): Behind everything: window, toolbar and screen background.
- **Rail** (#14171D): The sidebar.
- **Panel** (#171A20): Panels, tables, table headers and pitch cards.
- **Hover** (#1E222A): A row under the mouse. The palette field is still called `altRow`, but it is never used for stripes.
- **Hairline** (#262B35): Row separators, panel borders, pitch line work, range bar tracks and skeleton bars.
- **Text** (#E8EBF1): Primary text.
- **Muted** (#9AA3B2): Everything secondary: detail lines, table headings, notes, the quiet pill (6.85:1 on a panel).

### Named Rules
**The Colour By Job Rule.** Ask `AppColors` for a job, never a hex. A palette or the System option can replace any value, so a literal colour in a view is a bug in 20 themes.

**The One Accent Rule.** The accent marks primary action and selection, as a fill. It never carries status and is never set as text.

**The One Meaning Rule.** Star Gold is stars. Hidden Orange is hidden data. Watch Amber is a warning. They sit close in hue, so they must never swap jobs.

## Typography

**Display Font:** System sans (SF Pro) through native text styles
**Body Font:** System sans (SF Pro)
**Label/Mono Font:** System sans with tabular digits. There is no second family.

**Character:** The Mac's own voice at its smaller sizes. Hierarchy comes from size, weight and muted colour rather than from a typeface with a personality. Sizes are native points, written as px in the tokens. Line height is left to each text style.

### Hierarchy
- **Display** (semibold 600, 22pt, `.title`): The one name that heads a screen: a club or a person. Regular weight on the welcome screen.
- **Lead** (regular 400, 15pt, `.title3`): The answer in a sentence at the top of a screen.
- **Figure** (semibold 600, 15pt, tabular): Headline numbers on a profile.
- **Headline** (bold 700, 13pt, `.headline`): Panel titles, fact values, the club in the sidebar footer. Fact values are tabular.
- **Body** (regular 400, 13pt, `.body`): Default text, names, navigation. Medium 500 for the first cell of a place row.
- **Callout** (regular 400, 12pt, `.callout`): Detail lines, notes, fact labels, footnotes, panel links. Semibold on pitch card names.
- **Table** (regular 400, 12pt): Every grid cell, tabular in number columns, bold 700 for an emphasised row.
- **Label** (medium 500, 11pt, `.subheadline`): Table headings, pills and sidebar section headings. Sentence case. Pitch cards and position dots use this size at semibold, bold or regular, as they need.

### Named Rules
**The Five Sizes Rule.** 22, 15, 13, 12 and 11. Anything new takes one of these. A size between them is a hierarchy problem to solve with weight or colour.

**The Tabular Rule.** Any number that can be compared with another number uses tabular digits, and number columns align right.

**The Sentence Case Rule.** Headings and labels are written as sentences. Small type is never uppercased or tracked out, and FM's terms (CA, PA, Det, Pro, Amb, position codes) stay as FM writes them.

## Layout

A native split view: sidebar 200 to 280pt wide (216 ideal) on the left, detail on the right. The main window opens at 1380 by 860 and goes no smaller than 1120 by 620, and every screen has to hold at that small size.

Spacing comes from a short scale. A screen has a 16pt gutter, panels sit 12pt apart, panel content is inset 14pt left and right, and rows have 8pt of vertical padding. A table's first column is inset so its text lands on the same 14pt line as the panel title above it.

A typical screen stacks a control bar, a lead sentence, panels, then a footnote. Controls that shape the list sit on the left and wrap to a new line instead of squeezing; what you do with the list sits on the right. Wide and narrow columns stand side by side while both fit, with the narrow one at 300 to 404pt, and stack when the room runs out. Short facts share a wrapping row with 24pt between them.

Long jobs report at the foot of the screen, not over the rows they are working on, and results fill in while the rest of the screen stays readable.

### Named Rules
**The Nothing Cut Off Rule.** A column gets the width of its longest text, a sentence wraps, and a table that still cannot fit scrolls sideways. Layouts wrap or stack rather than clip. If text would be hidden, change the layout.

**The Same Line Rule.** Panel titles, table first columns and row content share one inset. If a new element starts anywhere else, it is wrong.

## Elevation & Depth

Depth comes from tone and hairlines. The three neutrals step up from ground to rail to panel, and a 1pt border defines each panel. Nothing resting on a screen has a shadow.

### Shadow Vocabulary
- **Floating** (`0 4px 20px rgba(0,0,0,0.25)`, SwiftUI radius 10, y 4): The progress card, the one element that floats over content.

### Named Rules
**The Flat Panel Rule.** Panels never take a shadow. Only something truly above the page, such as the progress card, gets one, and sheets and menus stay native.

## Shapes

Gently rounded, with one main radius. Panels and the progress card use 10pt, inline notices 8pt, pitch cards and the pitch outline 6pt, and skeleton bars 4pt. Status pills, range bars and position dots are fully round. Hairlines are always 1pt and sit on the inside of the shape.

## Components

Native first. Buttons, segmented pickers, toggles, menus, sheets, the search field and the sidebar are the real Mac controls, so custom components exist only where the Mac has nothing to offer.

### Buttons
- **Shape:** Native bezels, sized by the control.
- **Primary:** The default button in Signal Blue with white text, either through the default action or `.borderedProminent` on the welcome screen. A screen has one.
- **Hover / Focus:** Native. A row's look-further action is a borderless muted magnifying glass.
- **Text links:** The native link style at 12pt, top right in a panel, leading to the rest of what the panel previews. They render in macOS link blue.

### Chips
- **Style:** A capsule at 14% of its own tone with text in the full tone, label type, 8pt horizontal and 3pt vertical padding (18pt tall inside grids).
- **State:** A row with nothing to flag still gets a quiet muted pill in a pill column, so the column reads as one. Standing maps to tone: Nobody there and Not good enough are red, Below the league amber, Developing blue, Among the best green, the rest muted.

### Cards / Containers
- **Corner Style:** 10pt.
- **Background:** Panel.
- **Shadow Strategy:** None. See Elevation & Depth.
- **Border:** 1pt Hairline, inside the edge.
- **Internal Padding:** Title block 12pt top, 8pt bottom, 14pt sides, with an optional muted note under the title and an accessory on its right. Content then runs edge to edge, so rows and tables reach the border.

### Inputs / Fields
- **Style:** Native. The toolbar search field is an AppKit `NSSearchField`, 150pt wide, and it takes Cmd-F.
- **Focus:** The system focus ring.

### Navigation
- **Sidebar:** Native source list on Rail with 17 by 15pt symbols, so labels align despite differing symbol widths. Section headings use label type in Muted. The footer names the club and where the numbers came from.
- **Toolbar:** Native, on Ground. Holds the screen title, the Ability segmented control, the Hidden attributes toggle and Load Save, which is the one way in.

### Data Grid
The core of the app, an AppKit table themed to sit inside a panel.
- **Rows:** 24pt in people lists, 26pt in reports, growing to fit wrapped text. A 1pt hairline under each, no alternating fill.
- **Headings:** 28pt, label type in Muted on Panel. The sorted column turns Text and gains a small chevron. Headings over hidden columns take Hidden Orange.
- **Numbers:** Tabular and right-aligned. A column of short statuses becomes a column of pills.
- **Behaviour:** Hover tints, Return or double-click opens, Cmd-C copies, a right-click gives the person menu. Once you drag a column the grid leaves your widths alone.

### Place Row
One place in a list: the place, who is there and why, the best who'd join, a standing pill and a look-further action. A name is a link to the profile, underlined on hover. Its score sits beside it with any gain in green, and detail lines run below in callout type, tinted by job.

### Range Bar
The signature component: a young player's whole story in one row. A 6pt capsule on a Hairline track, solid Development Blue to ability now, 40% to likely peak, and a 2 by 12pt Text tick at potential. It is fed the same displayed values as the numbers beside it, so it never gives away more than they do, and it disappears when ability is off.

### Pitch
A pitch is a drawing, in 1pt Hairline strokes on the panel, because colour here has jobs to do. Pitch Cards (position, stars, surname) sit on it, placed by `PitchPlan`: cards on a line push apart 3pt and a line too wide for the pitch steps into two, so a long surname never overlaps its neighbour. Squad views add a small standing dot to the card. On a profile, 30pt position dots in FM Level Colours are the buttons that pick a position, with a 2.5pt ring on the current one.

### Stars
Drawn from symbols at 10pt with a 1pt gap, as one unbreakable image, and kept on a line with the name before them. Half stars are real half symbols.

### Loading
Skeleton Rows, 10pt bars of varying width in Hairline, stand in for rows on their way. The progress card sits at the foot of the screen, always with Cancel when a job can be stopped. Scrolling to freshly found picks eases out over 0.2s; otherwise state changes are immediate.

## Do's and Don'ts

### Do:
- **Do** lead a screen with a Lead sentence that gives the answer, then show the rows that prove it.
- **Do** use `Panel` for anything grouped, with its 10pt radius, 1pt Hairline and 14pt inset.
- **Do** put short statuses in tinted pills at 14% and let reasons run as callout text in the matching tone.
- **Do** check new UI in Starship, a light palette, System, Exact, Stars and Off, and with Hidden attributes off.
- **Do** say where a number comes from in a footnote when it is this app's judgement and not FM's.
- **Do** draw football as information: a line-work pitch, position dots, drawn stars.
- **Do** use native Mac controls wherever one exists.

### Don't:
- **Don't** fill a drawn pitch with green or use grass, kit or crest textures as decoration. The user-chosen Pitch palette is a theme and stays.
- **Don't** imitate Football Manager's or Sports Interactive's identity.
- **Don't** set Signal Blue as text or use it for status.
- **Don't** add alternating row stripes.
- **Don't** shorten a value to make it fit: resize, wrap, stack or scroll instead.
- **Don't** type star characters into a view; pass them through `Text(starred:)` or `GridStyle.show`.
- **Don't** add a sixth type size or a second typeface.
- **Don't** put a shadow on a panel.
- **Don't** write a colour literal in a view, or reach past `AppColors` for a system colour.
- **Don't** uppercase small labels or put a small category label above a heading.
- **Don't** show a hidden value, or a bar or colour that implies one, when Hidden attributes is off or ability is hidden.
