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
RuneKit/             UI-free logic: config, themes, shell resolution (unit tested)
Sources/App/         app lifecycle, menus, config store
Sources/Session/     PTY session wrapping SwiftTerm's LocalProcessTerminalView
Sources/UI/          window, tab bar, terminal container, banners
Tests/RuneKitTests/  XCTest suite
scripts/             `rune` CLI launcher, icon generator
```

## Status

- Phase 1 (terminal, tabs, config, packaging): done
- Phase 2: shell integration + blocks
- Phase 3: input editor
- Phase 4: palette, splits, workflows, SSH
- Phase 5: local AI via Ollama

## License

MIT. Dependencies: SwiftTerm (MIT).
