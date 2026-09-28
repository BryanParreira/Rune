# Rune shell integration bootstrap.
#
# Rune starts zsh with ZDOTDIR pointing at this directory so that this file runs first.
# It immediately restores the user's own ZDOTDIR, so zsh goes on to read the user's
# normal .zprofile / .zshrc / .zlogin exactly as it would in any other terminal.
# Nothing in the user's dotfiles is modified.

if [[ -n "${RUNE_USER_ZDOTDIR+x}" ]]; then
  export ZDOTDIR="$RUNE_USER_ZDOTDIR"
else
  unset ZDOTDIR
fi
unset RUNE_USER_ZDOTDIR

# The user's own .zshenv.
if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
  builtin source "${ZDOTDIR:-$HOME}/.zshenv"
fi

# Hooks for interactive shells only; scripts are never affected.
if [[ -o interactive && -n "$RUNE_INTEGRATION_DIR" ]]; then
  builtin source "$RUNE_INTEGRATION_DIR/rune.zsh"
fi
