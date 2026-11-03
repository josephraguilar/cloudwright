# GUI design: Genesis tokens in WPF

Source of truth for look and feel: `docs/gui/design-reference.md` (the Genesis design file). This page
says how it maps onto the PowerShell/WPF front end in `scripts/powershell/gui/`.

## Files

| File | Role |
| ---- | ---- |
| `gui/Theme.xaml` | ResourceDictionary: every color, brush, font family, type size, spacing, radius and control style from design-reference.md |
| `gui/Start-M365Gui.ps1` | Shell window (nav, module list, content host), background worker, GDAP view wiring |
| `gui/Views/GdapView.xaml` | Layout of the GDAP module; no code |
| `gui/fonts/` | Optional font files (not committed); theme falls back to Segoe UI / Cascadia |

Run: `pwsh -STA ./scripts/powershell/gui/Start-M365Gui.ps1` on Windows.

## Token mapping

| design-reference.md | Theme.xaml key |
| --------- | -------------- |
| Primary #6366F1 / hover #4F46E5 | `PrimaryBrush`, `PrimaryHoverBrush` |
| Neutral #9C9C9C | `NeutralBrush` (captions, disabled nav) |
| Background #FAFAFA / Surface #FFFFFF | `BackgroundBrush` (window), `SurfaceBrush` (cards, nav, sidebar) |
| Text primary #0A0A0A / secondary #6B6B6B | `TextPrimaryBrush`, `TextSecondaryBrush` |
| Border #E8E8EC | `BorderBrush` |
| Success / Warning / Error | `SuccessBrush`, `WarningBrush`, `ErrorBrush`, used only by status chips and warning text |
| Secondary green #20970B | not used (reserved for the brand highlight in the source design) |
| General Sans / DM Sans / JetBrains Mono | `DisplayFontFamily`, `BodyFontFamily`, `CodeFontFamily` with Segoe/Cascadia fallbacks |
| Type scale 72/60/32/24/15/13/12/11 | `FontSizeDisplay` .. `FontSizeOverline`; styles `SectionHeading`, `Subhead`, `BodyText`, `SecondaryText`, `CaptionText`, `OverlineText`, `CodeText` |
| 4px grid; container 24; card 20; row 16×12; input 14×10 | `ContainerPadding`, `CardPadding`, `RowPadding`, `InputPadding` |
| Radii 4 / 6 / 8 / 12 / pill | `RadiusChip`, `RadiusControl`, `RadiusPanel`, `RadiusCard`, `RadiusPill` |
| Cards flat, hover shadow 0 8px 30px 8% + 2px lift | `Card` style: `DropShadowEffect` and `TranslateTransform` only in the `IsMouseOver` trigger |
| Buttons 6px, medium weight, 32/38/44, lift 1px | `PrimaryButton`, `SecondaryButton`, `GhostButton`, `DestructiveButton`, `SmallButton` |
| Primary hover glow 0 4px 12px indigo 35% | `PrimaryButton` hover trigger |
| Inputs 1px, 6px, focus indigo + ring | `Input` style |
| Chips pill, gray-100 bg, 12px; semantic status chips | `Chip`, `ChipSuccess`, `ChipWarning`, `ChipError`, `ChipActive`, `ChipText`, `ChipTextOnColor` |
| Lists: 1px dividers, 16×12, hover bg | `ListRow` |
| Nav 56px, 1px bottom border, 14px medium links | shell window; `NavItem` for the module list (WPF has no backdrop blur; plain surface) |

## Rules kept

- Indigo appears only on interactive elements: primary buttons, selected nav item, focus borders, the "approved, activating" chip.
- One filled primary button per card: Inspect (Customer), Prepare approval request (Compliance), Run reviewed command (Review and run). Everything else is secondary or ghost.
- Two font weights per screen: Regular and Medium for UI, Bold only on display headings.
- No shadows on static elements. Shadows exist only in hover and focus triggers.
- No gradients, no illustrations. Status is carried by chips and text.
- Spacing stays on the 4px grid: 4, 8, 12, 16, 20, 24, 32.

## Shell and dock

The shell is a 56px nav, a 240px module list, a content host, and a bottom dock that every
view shares: Review and run (the exact command in the code font, the list of changes the dry
run found, then "1. Dry run: show the changes", "2. Make these changes", Copy, Clear, and a chip
saying "Changes something" or "Read-only") beside the Activity log. The dock is the one place
where anything executes.

## Generic task view

For every module except GDAP: a task list on the left (name, read/write chip, synopsis) and,
on the right, a client picker that prefills tenant fields, the task's synopsis, description,
status and requirements, and a form built from the script's parameters: text inputs,
checkboxes for switches, dropdowns for ValidateSet, mandatory marked with an asterisk,
help text as captions. Prepare composes the command into the dock. The view is generated
from the catalog, so a new script needs no GUI work.

## GDAP view structure

Five cards in workflow order, each with an overline step number: Partner sign-in, Customer,
Existing relationships, Compliance against template (state chip, proposed actions, warnings,
Prepare buttons) and Customer approval (link, copy, open, watch/stop, status chip). Prepared
commands land in the shared dock.

Plan, then run, is a product rule, not a style: the GUI never executes a change on its own.
Prepare writes the task-script command line into the Review card. Dry run executes it with
-WhatIf and lists every change it would make (tenant, plain-English action, exact
Exchange/Graph command). "Make these changes" stays disabled until that dry run has happened
for the exact text shown; it confirms with the list and runs the command with the list as its
approved plan, so any other change is refused before it runs. Read-only tasks run with an empty
approved plan. Copy lets the operator run it in a terminal instead. Sign-in, inspect and status
polling run directly. Status chips: Awaiting customer approval (warning), Approved
/ Active (success), Rejected or expired (error), Error / requires attention (error).

The approval window is a second WPF window owned by the shell: a one-line surface banner over
a WebView2 control with an isolated user-data folder. Same theme dictionary, no extra styling.

## Not yet

Dark mode (design-reference.md asks for both; the dictionary is structured so a second color block can
be swapped in), the ⌘K search bar, and the remaining eight module views, which the sidebar
lists as "(soon)".
