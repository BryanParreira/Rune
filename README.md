<div align="center">

<img src="docs/assets/rune-icon.png" width="140" height="140" alt="Rune">

# Rune

### The terminal, refined.

A native macOS terminal with command blocks, a modern input editor,
a private AI that runs entirely on your Mac, and a warm paper look that's easy on the eyes.

**[Download for macOS →](https://github.com/BryanParreira/Rune/releases/latest)**

<sub>Free · macOS 14 or later · Apple Silicon and Intel · Signed and notarized by Apple</sub>

<br><br>

<img src="docs/assets/screenshot-paper.png" width="820" alt="Rune in the Paper theme: git history, a file listing and a failed command, each in its own block">

</div>

<br>

## Built around how you actually work

**Every command is a block.**
Output is grouped with the command that produced it, its folder and how long it took. Failed commands stand out in red with their exit code. Hover to copy the command or its output, or run it again. Click a block to select it, ⇧-click to select several, and jump between blocks with ⌘↑ and ⌘↓.

**Copy exactly what you need.**
Copy a block's command, its output, both, Markdown for an issue, or a picture of it in your theme (⌥⌘C) to drop into a chat, made on your Mac, not shared through a link. ⇧⌘C copies the last output; ⌘C copies a block you selected with ⌘↑. Copies match what you see on screen: hidden secrets stay hidden and padding spaces are trimmed.

**See what changed between two runs.**
Ran the tests before and after a fix? Compare with Previous Run (⌥⌘D) opens a diff of the two outputs, with a switch to ignore lines that only differ in numbers like timings. Or select any two blocks and compare them.

**Watch a command.**
Watch… on any block re-runs it in the background every few seconds, or whenever files in its folder change, and marks the lines that changed with a highlighter. Pause it, run it now, or get a notification when the output changes while you're in another app. Your scrollback stays clean.

**Find the error in a wall of output.**
⌘' jumps to the last line that looks like an error and marks it; press it again for the one before. Bookmark blocks you want to come back to with ⌥⌘B and jump between them with ⌃⌘↑ ⌃⌘↓. Failed blocks and bookmarks show as ticks on the scroll bar.

**An input that feels like an editor.**
Type at the bottom, like a chat. Edit multi-line commands, accept suggestions from your history with →, and see typos in red before you press Enter. The shell keys you know work there too: ⌃U, ⌃W, ⌃K and ⌃Y, ⌥B and ⌥F, and ⌥. for the last argument. Mistype `gti status` or `cd Documetns` anyway, and Rune suggests the fix: press Tab to use it. Tab opens a menu of subcommands and flags for git, docker, npm, brew, kubectl and more, with a short note on what each does, plus your npm scripts, Makefile targets and git branches.

**Your input box, even over SSH.**
When `ssh` (or `docker exec`, `kubectl exec`, `su`…) lands you in a shell on another machine, Rune offers to keep its input box there: blocks, history suggestions and ⌘↵ AI work like they do locally. Passwords and logins always go straight to the session, and nothing is saved on the server.

**Output you can click.**
⌘-click a URL or a file path in any output, like `src/app.ts:42:7` in a compiler error, and it opens right at that line in VS Code, Cursor or Zed. Point at a path and press ⌘Y to Quick Look it. Filter a long output down to the lines you care about from the block's menu.

**Recall: everything you've run, searchable.**
Press ⌃R to search every command *and its output* across all your sessions: "that docker command from last week", "the error that mentioned port 3000". It's stored only on your Mac, with secrets removed. Start a command with a space and it's never recorded.

<div align="center">
<img src="docs/assets/screenshot-recall.png" width="760" alt="Recall searching past commands and their output">
</div>

**Docs you can run.**
Open a README or any Markdown file and every shell snippet gets a Run button that puts the command in your terminal, ready for you to press Enter.

**A private AI, on your Mac.**
Press ⌘↵ to ask a question instead of running it. Rune answers with the context of where you are and what just happened, and suggested commands come back as cards you run with one click. Nothing runs until you say so. It works with any model you've installed in [Ollama](https://ollama.com). Your prompts never leave your machine.

**Your shell, untouched.**
Rune loads your own setup exactly as it is, in zsh, bash or fish: oh-my-zsh, Starship, plugins, aliases. Blocks and the input box work in all three, and Rune never edits your dotfiles.

**Everything is one keystroke away.**
Press ⌘P for the command palette: every action, your open tabs, recent folders, themes and your whole command history, found with a few letters.

**Split your workspace.**
⌘D splits a tab side by side and ⇧⌘D stacks it. Each pane is its own shell with its own input, and ⌥⌘ plus an arrow key moves between them.

**Layouts for your projects.**
Set up a window the way you like it (a tab for the server with its dev command running, another split between the app and the logs), then save it with Shell › Save Window as Layout. Open it again from the palette and everything comes back, commands included. Layouts are small JSON files in `~/.config/rune/layouts` you can edit or share. Name and color tabs with a double-click or a right-click.

**Workflows for the commands you repeat.**
Save a command once, with blanks like `git push {{remote}} {{branch}}`, then run it from the palette. Rune selects each blank for you to fill in and Tab moves to the next. Workflows live in your config file, so they travel with your sync folder. Commit a `.rune/workflows.json` to a repository and everyone on the team gets the same workflows there, no cloud account involved.

**Fast, and right where you left off.**
New tabs and splits open instantly, even with a heavy zsh setup, and huge outputs stream by: a million lines in about two seconds. Quit or update, and your windows, tabs, splits and folders come back just as they were. Closed a tab by accident? ⇧⌘T brings it back. Press ⌘F to search any output.

**Part of your Mac.**
The Shortcuts app gets Rune actions: open a folder, type a command, get the last output, search Recall. Use them in your own shortcuts, from Spotlight, or from Raycast. Launchers can also open `rune://open?dir=~/project&command=npm%20test`, which types the command for you and never runs it on its own.

**Tabs that go where you want.**
Drag tabs to reorder them, onto another Rune window, or out into a new one with Move Tab to New Window. Every menu shortcut can be changed in Settings.

**Find anything in the output.**
⌘F shows how many matches there are and marks them all; Return walks back through them, and a switch keeps the search inside the block you selected.

**Know when it's done.**
Start a long build, switch to something else, and Rune sends a notification when it finishes. Click it to jump straight back to that pane.

**Private by design.**
API keys and tokens in your output are masked on screen and never sent to AI. With one switch, `sudo` accepts Touch ID instead of your password.

**Easy on the eyes.**
Rune's Paper theme is a soft, warm beige with ink-colored text and a highlighter for selections, with handwritten touches here and there. Prefer the dark? Paper Night keeps the same warmth after sunset.

<div align="center">
<img src="docs/assets/screenshot-night.png" width="760" alt="Rune in the Paper Night theme">
</div>

**Files at a glance.**
Press ⌘B for a sidebar of the folder you're in, with git status colors and a project-wide filter. Click a file to read it right inside Rune, with syntax colors and line numbers. In a git repository, switch to Changes to see every edited file with its added and removed lines, and click one for a colored diff. In Finder, right-click a folder and choose Services › New Rune Tab Here.

**Thoughtful everywhere.**
Press ⌃\` in any app to bring Rune forward, and again to tuck it away. `imgcat photo.png` shows pictures right in the output. Full-screen apps like vim and htop take over cleanly. Closing a tab that's still running something asks first. Settings are searchable, and Rune updates itself quietly with verified releases.

<br>

<div align="center">
<img src="docs/assets/install-window.png" width="660" alt="Drag Rune into Applications to install">
</div>

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask bryanparreira/tap/rune
```

Or download it:

1. Download **Rune.dmg** from the [latest release](https://github.com/BryanParreira/Rune/releases/latest).
2. Open it and drag **Rune** into **Applications**.
3. Launch Rune. That's it: no account, no setup.

For AI features, install [Ollama](https://ollama.com/download) and pull a model, for example:

```sh
ollama pull qwen2.5-coder:3b
```

Rune finds your installed models automatically. You can choose one in Settings → AI.

## Keyboard

| Action | Shortcut |
|---|---|
| Run command | ↵ |
| New line | ⇧↵ |
| Ask AI · follow up | ⌘↵ |
| Open a link or file path from the output | ⌘-click |
| Accept suggestion | → |
| Command history | ↑ ↓ |
| Complete commands, flags, files (menu: ↑↓, ⇥ or ↵) | ⇥ |
| Delete to line start · previous word · to line end · paste back | ⌃U · ⌃W · ⌃K · ⌃Y |
| Word back · forward · insert last argument | ⌥B · ⌥F · ⌥. |
| Recall: search past commands and output | ⌃R |
| Jump between blocks · select several | ⌘↑ ⌘↓ · ⇧⌘↑ ⇧⌘↓ |
| Copy last output · last block as image | ⇧⌘C · ⌥⌘C |
| Compare with previous run | ⌥⌘D |
| Jump to error · next error | ⌘' · ⇧⌘' |
| Bookmark block · jump between bookmarks | ⌥⌘B · ⌃⌘↑ ⌃⌘↓ |
| Quick Look the path under the pointer | ⌘Y |
| Find in output · older · newer match | ⌘F · ⌘G · ⇧⌘G |
| Clear screen | ⌘K |
| Show or hide Rune from any app | ⌃\` |
| Command palette | ⌘P |
| Files sidebar | ⌘B |
| Split right · split down | ⌘D · ⇧⌘D |
| Next pane · move between panes | ⌘] · ⌥⌘ arrows |
| New tab · close pane or tab | ⌘T · ⌘W |
| Reopen closed tab | ⇧⌘T |
| Rename tab | double-click the tab |
| Settings (change any menu shortcut under Keyboard shortcuts) | ⌘, |

## Privacy

Rune has no accounts, analytics, crash reporting or telemetry. Recall history, restored sessions and settings stay on your Mac, and secrets are removed before anything is stored or sent to AI. AI requests go only to the Ollama server on your Mac, or to one you explicitly configure, in which case Rune shows a warning. The only other network request is a daily update check that downloads a public feed and sends nothing about you. You can turn it off in Settings → About.

## Updates

Installed copies check for updates once a day and ask before installing. Every update is signed, and Rune verifies that signature before installing anything. You can also choose **Rune → Check for Updates…** at any time.

## For developers

Rune is a native Swift app (AppKit + SwiftUI) built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), with [Sparkle](https://sparkle-project.org) for updates. The source is published for transparency; it is proprietary and may not be copied or redistributed (see [LICENSE](LICENSE)). Build notes are in [INSTALL.md](INSTALL.md) and design notes in [docs/DESIGN.md](docs/DESIGN.md).

<br>

<div align="center">
<sub>Rune is free to use. © 2026 Bryan Bernardo Parreira. All rights reserved.<br>
Built with <a href="https://github.com/migueldeicaza/SwiftTerm">SwiftTerm</a> and <a href="https://sparkle-project.org">Sparkle</a>.</sub>
</div>
