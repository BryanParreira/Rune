<div align="center">

<img src="docs/assets/rune-icon.png" width="128" height="128" alt="Rune icon">

# Rune

**A native macOS terminal with blocks, a modern input editor, and a private AI that runs on your Mac.**

No account. No telemetry. No cloud. Just a fast terminal that's yours.

[**Download for macOS**](https://github.com/BryanParreira/rune-releases/releases/latest) · [Install guide](INSTALL.md) · [Design notes](docs/DESIGN.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white)
![Apple Silicon and Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-111)
![Swift](https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white)
![No telemetry](https://img.shields.io/badge/telemetry-none-2ea44f)
![Free to use](https://img.shields.io/badge/price-free-111)

</div>

---

## Why Rune

Most modern terminals ask you to sign in, sync to their servers, or send your prompts to someone else's model. Rune doesn't. It's a native AppKit app built on a proven terminal engine, it keeps everything in plain files you own, and its AI talks only to [Ollama](https://ollama.com) on your own machine.

Enter always runs your command. Nothing you type goes anywhere else unless you ask.

## Highlights

**Blocks, not a wall of text**
Every command and its output becomes a block with its folder and run time. Failed commands are marked in red with their exit code. Hover a block to copy the command, copy the output, or run it again. Jump between blocks with ⌘↑ / ⌘↓.

**An input editor that feels like an editor**
Type at the bottom like a chat, with multi-line editing (⇧↵), history suggestions as you type (→ to accept), live syntax highlighting, Tab completion for files, and a chip showing the current folder and git branch. Output starts at the bottom and grows upward.

**Private AI, on your Mac**
Press ⌘↵ to ask a question instead of running it. Rune sends it, with your folder, git branch, and the last command's output as context, to a model running in Ollama on your Mac. Answers stream in, commands come back as cards with **Run** and **Edit**, and nothing ever runs until you press Run. Ask follow-ups, or click ✦ on a failed block to explain the error. Pick any installed model in Settings, or turn AI off entirely.

**Your zsh, untouched**
Rune loads your own `.zshrc`, oh-my-zsh, Starship, and plugins exactly as they are, without editing a single dotfile. Prefer typing at your real prompt so every zle plugin works? Switch *Type commands in* to **zsh prompt**.

**A file tree when you want it**
⌘B opens a sidebar for the folder you're in, with a project-wide filter, git status colors, and actions to `cd`, open a new tab, or drop a path into your command.

**Details that matter**
Full-screen apps like vim and htop take over the window cleanly. Closing a tab that's still running something asks first. If a Nerd Font is installed, icons from tools like eza and Starship render automatically. Settings live in a searchable tab and write to a plain JSON file. Updates install themselves, signed and verified.

## Install

1. Download **Rune.dmg** from [Releases](https://github.com/BryanParreira/rune-releases/releases/latest).
2. Drag **Rune** to **Applications** and open it.

Rune is signed with a Developer ID and notarized by Apple, so it opens like any other app. It checks for updates once a day (you can turn that off), and updates are only installed when they carry Rune's signature.

**Optional:** from a source checkout, install the `rune` command to open a new tab in any folder:

```sh
make cli          # installs to ~/.local/bin/rune
rune ~/projects/app
```

**For AI features:** install [Ollama](https://ollama.com/download) and pull a model, for example `ollama pull qwen2.5-coder:3b`. Rune finds your installed models automatically.

## Keyboard

| | |
|---|---|
| Run command | ↵ |
| New line | ⇧↵ |
| Ask AI · follow up | ⌘↵ |
| Accept suggestion | → |
| Command history | ↑ ↓ |
| Complete file or folder | ⇥ |
| Select previous / next block | ⌘↑ / ⌘↓ |
| Clear screen | ⌘K |
| File tree | ⌘B |
| New tab · close tab | ⌘T · ⌘W |
| Switch tab | ⌘1 … ⌘9 |
| Settings | ⌘, |

## Configuration

Settings are available in the app (⌘, or the gear in the top-right corner) and are stored in `~/.config/rune/config.json`. Edit either one; changes apply instantly.

```jsonc
{
  "fontFamily": "JetBrainsMono Nerd Font Mono",
  "fontSize": 13,
  "theme": "rune-dark",
  "inputMode": "editor",          // or "shell" to type at your own zsh prompt
  "aiEnabled": true,
  "aiModel": "qwen2.5-coder:3b",

  // Share settings between Macs through iCloud Drive or a dotfiles repo.
  "syncPath": "~/Library/Mobile Documents/com~apple~CloudDocs/rune",

  // Per-machine overrides, keyed by the Mac's local hostname.
  "hosts": {
    "Studio": { "fontSize": 15 },
    "MacBook-Air": { "fontSize": 12 }
  }
}
```

Custom themes go in `~/.config/rune/themes/<name>.json`. A config file with mistakes never stops Rune from starting: bad values fall back to defaults, and a banner tells you what to fix.

## Privacy

- No accounts, analytics, crash reporting, or telemetry of any kind.
- AI requests go only to the Ollama server you configure, which defaults to `localhost`. If you point it at another machine, Rune shows a warning chip.
- The only other network request is the daily update check, which downloads a public feed and sends nothing about you. You can disable it in Settings → About.

## Build from source

Requirements: Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), and on Xcode 26+ the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```sh
make run        # debug build and launch
make install    # universal release build → /Applications
make dmg        # signed disk image
make notarize   # notarized, stapled DMG (Developer ID required)
```

Releases are published with `scripts/release.sh <version>`, which builds, notarizes, signs the update feed, and publishes to the releases repository.

## Under the hood

```
RuneKit/        UI-free core, unit tested: config, shell integration marks, blocks,
                input routing, history, completion, git, local AI client
Resources/      zsh integration (loaded through ZDOTDIR; your dotfiles stay untouched)
Sources/        AppKit + SwiftUI app: sessions, block overlay, input editor, AI card,
                file tree, settings, updates
```

Built with [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal emulation and [Sparkle](https://sparkle-project.org) for updates (both MIT-licensed; see Acknowledgements). The interface draws inspiration from Warp's layout; every line of Rune's code is its own.

## License

Proprietary. © 2026 Bryan Bernardo Parreira. All rights reserved. Free to use; see [LICENSE](LICENSE).
Third-party notices are in [Resources/Acknowledgements.txt](Resources/Acknowledgements.txt).
