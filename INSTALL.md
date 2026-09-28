# Installing Rune

Rune is a local-first terminal for macOS 14 or later, on Apple Silicon or Intel. It has no accounts and no telemetry, and it never talks to a server you didn't configure.

## From the DMG

1. Open `Rune.dmg` and drag **Rune** onto **Applications**.
2. Rune is ad-hoc signed, not notarized, so macOS blocks the first launch. Allow it in one of these ways:
   - In Finder, right-click **Rune.app** → **Open**, then click **Open** in the dialog. You only need to do this once.
   - Or, in a terminal:
     ```sh
     xattr -dr com.apple.quarantine /Applications/Rune.app
     ```
3. On first launch Rune creates `~/.config/rune/config.json` with defaults. It works right away with no setup.

## The `rune` command (optional)

From a source checkout:

```sh
make cli                      # installs to ~/.local/bin/rune
make cli PREFIX=/usr/local    # or somewhere else on your PATH
```

`rune` opens a new Rune tab in the current directory. `rune ~/src/project` opens one in that folder.

## Building from source

Requirements:

- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- On Xcode 26 or later, the Metal Toolchain component. SwiftTerm compiles a Metal shader, so run this once:
  ```sh
  xcodebuild -downloadComponent MetalToolchain
  ```

Then:

```sh
make run       # debug build + launch
make test      # unit tests
make install   # universal Release build, ad-hoc signed, copied to /Applications
make dmg       # build/Rune.dmg to copy to other Macs
```

## Configuration

- `~/.config/rune/config.json` holds settings. It's hot-reloaded on save. Comments and trailing commas are allowed.
- `~/.config/rune/themes/<name>.json` holds custom themes. Set `"theme": "<name>"` to use one.
- `"syncPath": "~/path/to/folder"` makes Rune read `config.json` and `themes/` from that folder instead. Point it at iCloud Drive or a dotfiles repo to share settings between Macs.
- `"hosts": { "<machine name>": { "fontSize": 15 } }` holds per-machine overrides. The machine name is the one shown in System Settings → General → Sharing → Local hostname, without `.local`.

A config file with mistakes never stops Rune from starting. Invalid values fall back to defaults, and a small banner explains what was wrong.

## AI features

AI features are optional and come in a later release. They use [Ollama](https://ollama.com/download) running on your own Mac. Rune never installs anything for you. Without Ollama, Rune is a complete terminal.
