# Rune UI/UX design spec

Rune's layout follows the "input at the bottom, output as blocks" model popularized by Warp.
The values below are design measurements and behaviors (layout facts), re-implemented from
scratch in Rune's own Swift code. No source code, strings, icons, or assets were copied from
Warp; its app code is AGPL-3.0 and Rune stays MIT.

## Layout (top → bottom)

1. **Tab bar** (38pt) sharing the titlebar with the traffic lights: flat full-height tabs,
   hairline dividers, centered title, `+` and a menu chevron. 1px outline under the bar.
2. **Block area**: one terminal grid; each command is a block drawn with overlays.
3. **Welcome panel** (new sessions only, dismissible, "Don't show again"): 1px top outline,
   16pt vertical padding, title = mono size + 6, rows 8pt apart, keycaps = mono size + 2 square,
   2pt corner radius, mono size − 4 for the dismiss link.
4. **Input area**: 1px top outline; context chips row; multi-line editor; hint line.

## Metrics

| Token | Value |
|---|---|
| Left content padding | 16pt |
| Default mono font | 13pt |
| Chip | 1px border, radius 4, padding 2×4, icon gap 4, margin 8 |
| Block hover button | 28pt tall |
| Bottom margin under block list | 10pt |

## Color system (derived from theme background/foreground/accent)

| Role | Formula |
|---|---|
| Main text | foreground @ 90% |
| Secondary text | foreground @ 60% |
| Hint/placeholder text | foreground @ 40% |
| Disabled | foreground @ 20% |
| Surface 1 / 2 / 3 | background blended with foreground @ 5 / 10 / 15% |
| Outline | foreground @ 10% |
| Split pane border | foreground @ 15% |
| Button hover | + foreground @ 10% |
| Text selection | rgb(118,167,250) @ 40% |
| Failed block | ANSI red @ 10% fill + solid red flag pole on the left edge |
| Error / warning / green UI | rgb(188,54,42) / rgb(194,128,0) / rgb(28,160,90) |

## Behavior

- A block counts as failed for non-zero exit, **except 130 (Ctrl-C) and 141 (SIGPIPE)**.
- Running commands show a live duration, repainted every 1s.
- Alternate-screen apps (vim, htop, less) take the whole pane; the input area hides.
- Between command start and finish, keystrokes go to the program (passwords, REPLs, Ctrl-C).
- Empty Enter in the editor does nothing (no empty blocks).

## Features adopted now

Bottom input editor, directory + git chips, welcome panel, blocks with separators, failed-block
tint + flag pole, duration, hover actions (copy command / copy output / re-run), Cmd-↑/↓ block
navigation, history cycling, Tab path completion, Settings tab, Nerd Font icon fallback.

## Settings (a tab, not a separate window)

Centered "Settings" caption above the page; left sidebar (~200pt) with a search field, page list
(14pt, 8pt padding, selected = solid accent fill with white text, 4pt radius) and an
"Open settings file" bordered button pinned to the bottom; 1px divider; content column
(max ≈ 680pt) with 23pt bold page title, 16pt section headers, rows of label-left /
control-right with 12pt secondary descriptions, accent-colored links, 1px separators.
Search filters pages and rows. Every control writes config.json; "This Mac only" writes
`hosts.<machine>` overrides.

## Candidate features for later phases

Command palette, split panes, workflows, sticky block header while scrolling long output,
"jump to bottom of block" button, block filtering/search, completions menu (≈330pt wide),
history search menu, rich history (exit code + duration per entry), secret redaction in output,
tab rename/colors, drag-to-reorder tabs, SSH machine badges, local AI (Ollama).
