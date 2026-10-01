# Rune shell integration for bash (3.2 and later).
#
# Rune starts bash with --init-file pointing here. This file first loads the user's own
# startup files the way a login shell would (/etc/profile, then the first of ~/.bash_profile,
# ~/.bash_login, ~/.profile), so everything works as in any other terminal; nothing in the
# user's dotfiles is changed. Then it adds the same marks as the zsh integration: OSC 133
# (A prompt, B input, C output, D;<exit> finished) and Rune's OSC 6973 metadata.

if [ -z "$__rune_loaded" ]; then
__rune_loaded=1

[ -r /etc/profile ] && . /etc/profile
if [ -r "$HOME/.bash_profile" ]; then
  . "$HOME/.bash_profile"
elif [ -r "$HOME/.bash_login" ]; then
  . "$HOME/.bash_login"
elif [ -r "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi

__rune_running=0
__rune_ready=0
__rune_names_sent=

# Percent-encode what would break an OSC string. Result in $__rune_reply.
__rune_encode() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//$'\n'/%0A}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\a'/%07}"
  s="${s//$'\e'/%1B}"
  __rune_reply="$s"
}

# First in PROMPT_COMMAND: keep the last command's exit status.
__rune_status() {
  __rune_rc=$?
}

# Last in PROMPT_COMMAND: report how the command ended, the cwd, and set the prompt.
__rune_precmd() {
  if [ "$__rune_running" = 1 ]; then
    builtin printf '\033]133;D;%s\007' "$__rune_rc"
    __rune_running=0
  else
    builtin printf '\033]133;D\007'
  fi
  __rune_encode "$PWD"
  builtin printf '\033]6973;cwd=%s\007' "$__rune_reply"

  # Once the user's config has loaded: aliases and functions (so Rune's editor colors them
  # as commands) and the PATH (for its command list).
  if [ -z "$__rune_names_sent" ]; then
    __rune_names_sent=1
    __rune_encode "$(builtin compgen -a | tr '\n' ' ') $(builtin compgen -A function | grep -v '^_' | tr '\n' ' ')"
    builtin printf '\033]6973;names=%s\007' "$__rune_reply"
    __rune_encode "$PATH"
    builtin printf '\033]6973;path=%s\007' "$__rune_reply"
  fi

  if [ "$RUNE_HONOR_PROMPT" = 1 ]; then
    case "$PS1" in
      *'133;B'*) ;;
      *) PS1='\n\[\033]133;A\007\]\n'"$PS1"'\[\033]133;B\007\033[?25h\]' ;;
    esac
  else
    # Rune shows the context itself: an empty prompt, with a blank row between blocks and
    # the block's header row; the cursor stays hidden while Rune's editor has the keyboard.
    PS1='\n\[\033]133;A\007\]\n\[\033]133;B\007\033[?25l\]'
    PS2=''
  fi
  __rune_ready=1
}

# Just before a command line runs.
__rune_preexec() {
  [ "$__rune_ready" = 1 ] || return 0
  # Not for completion functions running while you type.
  [ -n "$COMP_LINE" ] && return 0
  # The prompt hook itself (Return on an empty line) isn't a command.
  [ "$BASH_COMMAND" = "__rune_status" ] && return 0
  __rune_ready=0
  __rune_running=1
  # No command text: bash only knows it from history, which skips commands starting with a
  # space (they'd be reported as the previous one). Rune reads it from the screen instead.
  builtin printf '\033[?25h\033]133;C\007'
}

if [ -n "$bash_preexec_imported" ] || [ -n "$__bp_imported" ]; then
  # bash-preexec (used by Starship, Atuin…) owns the DEBUG trap; join its hook lists.
  precmd_functions=(__rune_status "${precmd_functions[@]}" __rune_precmd)
  preexec_functions+=(__rune_preexec)
else
  PROMPT_COMMAND="__rune_status;${PROMPT_COMMAND:+$PROMPT_COMMAND;}__rune_precmd"
  trap '__rune_preexec' DEBUG
fi

# Rune keeps a spare shell ready; when it hands one to a tab in another folder it writes the
# folder to $RUNE_CD_FILE and sends SIGUSR1. (bash runs the trap at the next prompt.)
__rune_usr1() {
  [ -n "$RUNE_CD_FILE" ] && [ -r "$RUNE_CD_FILE" ] || return 0
  local dir
  dir=$(< "$RUNE_CD_FILE")
  command rm -f -- "$RUNE_CD_FILE"
  builtin cd -- "$dir" 2>/dev/null || return 0
  __rune_encode "$PWD"
  builtin printf '\033]6973;cwd=%s\007' "$__rune_reply"
}
trap '__rune_usr1' USR1

# Commands from Rune arrive as bracketed pastes (bash 5.1+); don't render them highlighted.
builtin bind 'set enable-active-region off' 2>/dev/null

builtin printf '\033]6973;hello=1\007'
fi
