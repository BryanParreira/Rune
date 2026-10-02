# Release checklist

`scripts/release.sh` runs the automated part (`scripts/smoke.sh`) before it builds anything.
The rest needs a person, a real trackpad and a few minutes. Do it on the release build
(`make release`, then open `build/DerivedData/Build/Products/Release/Rune.app`).

## Automated (scripts/smoke.sh)

zsh, bash and fish blocks and exit codes · vim full screen at a stable size · 300,000 lines
of output · long lines, wide characters and emoji · window resize · completion menu · shell
editing keys · find in output · copy output.

## By hand

**Startup**
- [ ] First launch with a heavy `.zshrc` (Powerlevel10k or oh-my-zsh): prompt appears, blocks work.
- [ ] Quit and reopen: windows, tabs, splits and folders come back.

**Typing and output**
- [ ] Type fast in the input; no lag, colors follow. Tab menu, ⌃R Recall, ⌘↵ AI (if set up).
- [ ] `cat` a big log, `npm install` or a build: output streams smoothly, ⌃C stops it.
- [ ] Trackpad scroll through long output: smooth, block headers stay aligned. Mouse wheel too.
- [ ] Select text with the mouse and ⌘C; click a block, ⇧-click another, ⌘C.

**Programs**
- [ ] vim, htop, less, `git log`: full screen, quit cleanly, output resumes below.
- [ ] tmux: attach, split, detach.
- [ ] ssh to a machine: the input-box offer appears; blocks work on the remote shell.
- [ ] `sudo -v` with Touch ID (if enabled).

**Windows**
- [ ] Resize from tiny to full screen; nothing jumps or overlaps.
- [ ] Drag a tab to reorder, onto another window, and Move Tab to New Window.
- [ ] Open a big image and a README from the file tree: window size doesn't change.
- [ ] Sleep the Mac with a command running, wake it: the tab still works.

**Mac**
- [ ] Shortcuts app shows Rune's actions; Get Last Output works.
- [ ] `open "rune://open?dir=/tmp&command=ls"` opens a tab with `ls` typed, not run.
- [ ] ⌘Y Quick Looks a path in the output.
- [ ] Help › Report a Problem makes a report folder and nothing else.

**Release build**
- [ ] `spctl -a -vv` on the app says "Notarized Developer ID".
- [ ] Check for Updates offers the new version on a Mac running the previous one.
