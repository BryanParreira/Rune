# Rune

A native, local-first macOS terminal. It's built with Swift and AppKit/SwiftUI, and uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal emulation.

- No accounts, no telemetry, no cloud services
- Plain-file config in `~/.config/rune`, hot-reloaded, with an optional sync folder and per-machine overrides
- Universal binary (Apple Silicon + Intel), macOS 14 or later

See [INSTALL.md](INSTALL.md) for installing and building.

## Layout

```
project.yml          XcodeGen project (make gen)
Makefile             build / run / test / install / dmg / cli
RuneKit/             UI-free logic (unit tested): config + writer, themes, shell resolution,
                     OSC 133 parser, block tracker, input routing, history, path completion, git
Resources/ShellIntegration/zsh/   ZDOTDIR bootstrap + hooks (never touches your dotfiles)
Sources/App/         app lifecycle, menus, config store
Sources/Session/     PTY session, shell-integration handling, buffer geometry, history store
Sources/UI/          window + tabs, block overlay, input area, welcome panel, Settings tab
docs/DESIGN.md       layout/color/behavior spec
Tests/RuneKitTests/  XCTest suite
scripts/             `rune` CLI launcher, icon generator
```

## Status

- Phase 1 (terminal, tabs, config, packaging): done
- Phase 2 (zsh integration, OSC 133 blocks, block actions): done
- Phase 3 (bottom input editor, history, completion, keystroke routing): done
- Settings tab, Nerd Font icon fallback, new app icon: done
- Phase 4: palette, splits, workflows, SSH
- Phase 5: local AI via Ollama

## License

MIT. Dependencies: SwiftTerm (MIT).
