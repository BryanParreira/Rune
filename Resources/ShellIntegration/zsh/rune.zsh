# Rune shell integration for zsh.
#
# Emits OSC 133 marks (A prompt, B input, C output, D;<exit> finished) plus Rune's private
# OSC 6973 metadata (cwd, command text) so Rune can draw command blocks and drive its
# input editor. Safe to source more than once.

[[ -o interactive ]] || return 0
(( ${+__rune_loaded} )) && return 0
typeset -g __rune_loaded=1
typeset -gi __rune_running=0

autoload -Uz add-zsh-hook

# Percent-encode the characters that would break an OSC string. Result in $REPLY.
__rune_encode() {
  local s=$1
  s=${s//\%/%25}
  s=${s//$'\n'/%0A}
  s=${s//$'\r'/%0D}
  s=${s//$'\a'/%07}
  s=${s//$'\e'/%1B}
  REPLY=$s
}

# First precmd hook: report how the last command ended while $? is still intact.
__rune_precmd_first() {
  local ret=$?
  # Keep our hooks at both ends of the list: first to see $?, last to have the final word
  # on PS1 (some themes rebuild PROMPT in their own precmd). zsh iterates over a copy, so
  # reordering here takes effect from the next prompt on.
  precmd_functions=(__rune_precmd_first ${precmd_functions:#__rune_precmd_*} __rune_precmd_last)
  if (( __rune_running )); then
    builtin printf '\e]133;D;%s\a' "$ret"
    __rune_running=0
  else
    builtin printf '\e]133;D\a'
  fi
}

# Last precmd hook: report the cwd and (re)install the prompt marks.
__rune_precmd_last() {
  __rune_encode "$PWD"
  builtin printf '\e]6973;cwd=%s\a' "$REPLY"

  if [[ "$RUNE_HONOR_PROMPT" == 1 ]]; then
    if [[ "$PS1" != *'133;B'* ]]; then
      PS1=$'%{\e]133;A\a%}\n'"$PS1"$'%{\e]133;B\a%}'
    fi
  else
    # Rune shows the context (cwd, git branch) itself, so the shell prompt is empty.
    # The leading newline is the block's spacer row; the cursor stays hidden while the
    # input editor owns the keyboard.
    PS1=$'%{\e]133;A\a%}\n%{\e]133;B\a\e[?25l%}'
    RPS1=''
    RPROMPT=''
  fi
}

__rune_preexec() {
  __rune_encode "$1"
  builtin printf '\e]6973;cmd=%s\a\e[?25h\e]133;C\a' "$REPLY"
  __rune_running=1
}

add-zsh-hook precmd __rune_precmd_first
add-zsh-hook precmd __rune_precmd_last
add-zsh-hook preexec __rune_preexec

# Commands arrive as bracketed pastes; don't render them highlighted.
typeset -ga zle_highlight
zle_highlight=(${zle_highlight:#paste:*} paste:none)

builtin printf '\e]6973;hello=1\a'
