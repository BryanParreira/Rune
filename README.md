<div align="center">

<img src="docs/assets/rune-icon.png" width="140" height="140" alt="Rune">

# Rune

### The terminal, refined.

A native macOS terminal with command blocks, a modern input editor,
and a private AI that runs entirely on your Mac.

**[Download for macOS →](https://github.com/BryanParreira/Rune/releases/latest)**

<sub>Free · macOS 14 or later · Apple Silicon and Intel · Signed and notarized by Apple</sub>

</div>

<br>

## Built around how you actually work

**Every command is a block.**
Output is grouped with the command that produced it, its folder and how long it took. Failed commands stand out in red with their exit code. Hover to copy the command or its output, or run it again. Jump between blocks with ⌘↑ and ⌘↓.

**An input that feels like an editor.**
Type at the bottom, like a chat. Edit multi-line commands, accept suggestions from your history with →, and see typos in red before you press Enter. Your current folder and git branch sit right above the cursor.

**A private AI, on your Mac.**
Press ⌘↵ to ask a question instead of running it. Rune answers with the context of where you are and what just happened, and suggested commands come back as cards you run with one click. Nothing runs until you say so. It works with any model you've installed in [Ollama](https://ollama.com). Your prompts never leave your machine.

**Your shell, untouched.**
Rune loads your own zsh setup exactly as it is: oh-my-zsh, Starship, plugins, aliases. It never edits your dotfiles.

**Files at a glance.**
Press ⌘B for a sidebar of the folder you're in, with git status colors and a project-wide filter. Click a file to read it right inside Rune, with syntax colors and line numbers.

**Thoughtful everywhere.**
Full-screen apps like vim and htop take over cleanly. Closing a tab that's still running something asks first. Settings are searchable, and Rune updates itself quietly with verified releases.

<br>

<div align="center">
<img src="docs/assets/install-window.png" width="660" alt="Drag Rune into Applications to install">
</div>

## Install

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
| Accept suggestion | → |
| Command history | ↑ ↓ |
| Complete file or folder | ⇥ |
| Jump between blocks | ⌘↑ ⌘↓ |
| Clear screen | ⌘K |
| Files sidebar | ⌘B |
| New tab · close tab | ⌘T · ⌘W |
| Settings | ⌘, |

## Privacy

Rune has no accounts, analytics, crash reporting or telemetry. AI requests go only to the Ollama server on your Mac, or to one you explicitly configure, in which case Rune shows a warning. The only other network request is a daily update check that downloads a public feed and sends nothing about you. You can turn it off in Settings → About.

## Updates

Installed copies check for updates once a day and ask before installing. Every update is signed, and Rune verifies that signature before installing anything. You can also choose **Rune → Check for Updates…** at any time.

## For developers

Rune is a native Swift app (AppKit + SwiftUI) built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), with [Sparkle](https://sparkle-project.org) for updates. The source is published for transparency; it is proprietary and may not be copied or redistributed (see [LICENSE](LICENSE)). Build notes are in [INSTALL.md](INSTALL.md) and design notes in [docs/DESIGN.md](docs/DESIGN.md).

<br>

<div align="center">
<sub>Rune is free to use. © 2026 Bryan Bernardo Parreira. All rights reserved.<br>
Built with <a href="https://github.com/migueldeicaza/SwiftTerm">SwiftTerm</a> and <a href="https://sparkle-project.org">Sparkle</a>.</sub>
</div>
