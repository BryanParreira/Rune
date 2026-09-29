# Rune shell integration for zsh.
#
# Emits OSC 133 marks (A prompt, B input, C output, D;<exit> finished) plus Rune's private
# OSC 6973 metadata (cwd, command text) so Rune can draw command blocks and drive its
# input editor. Safe to source more than once.

[[ -o interactive ]] || return 0
(( ${+__rune_loaded} )) && return 0
typeset -g __rune_loaded=1
typeset -gi __rune_running=0
typeset -gi __rune_reported_names=0

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

  # Once the user's config has loaded, tell Rune which aliases and functions exist so its
  # editor can highlight them as valid commands.
  if (( ! __rune_reported_names )); then
    __rune_reported_names=1
    __rune_encode "${(kj: :)aliases} ${(kj: :)functions[(I)[^_]*]}"
    builtin printf '\e]6973;names=%s\a' "$REPLY"
    __rune_encode "$PATH"
    builtin printf '\e]6973;path=%s\a' "$REPLY"
  fi

  if [[ "$RUNE_HONOR_PROMPT" == 1 ]]; then
    if [[ "$PS1" != *'133;B'* ]]; then
      # Show the cursor: Rune hides it while the shell starts.
      PS1=$'\n%{\e]133;A\a%}\n'"$PS1"$'%{\e]133;B\a\e[?25h%}'
    fi
  else
    # Rune shows the context (cwd, git branch) itself, so the shell prompt is empty.
    # The first newline leaves a blank row between blocks, the second is the block's
    # header row; the cursor stays hidden while the input editor owns the keyboard.
    PS1=$'\n%{\e]133;A\a%}\n%{\e]133;B\a\e[?25l%}'
    RPS1=''
    RPROMPT=''
  fi
}

__rune_preexec() {
  __rune_encode "$1"
  builtin printf '\e]6973;cmd=%s\a\e[?25h\e]133;C\a' "$REPLY"
  __rune_running=1
}

# Rune keeps a spare shell started in the background so new tabs open instantly. When it
# hands one to a tab in another folder, it writes the folder to $RUNE_CD_FILE and sends
# SIGUSR1: move there quietly (no chpwd hooks, no history, no block) and report it.
TRAPUSR1() {
  [[ -n "$RUNE_CD_FILE" && -r "$RUNE_CD_FILE" ]] || return 0
  local dir
  dir=$(<"$RUNE_CD_FILE")
  command rm -f -- "$RUNE_CD_FILE"
  builtin cd -q -- "$dir" 2>/dev/null || return 0
  __rune_encode "$PWD"
  builtin printf '\e]6973;cwd=%s\a' "$REPLY"
  zle && zle reset-prompt 2>/dev/null
  return 0
}

add-zsh-hook precmd __rune_precmd_first
add-zsh-hook precmd __rune_precmd_last
add-zsh-hook preexec __rune_preexec

# Show pictures inline (Rune understands iTerm2's image protocol), unless an imgcat is
# already installed: imgcat photo.png [chart.svg…]
if (( ! $+commands[imgcat] )); then
  imgcat() {
    local file
    if (( $# == 0 )); then
      print -u2 "usage: imgcat <image>…"
      return 1
    fi
    local -i pixels cells
    for file in "$@"; do
      if [[ ! -r "$file" || -d "$file" ]]; then
        print -u2 "imgcat: can't read $file"
        continue
      fi
      # Size in text columns: the image's width at Retina scale (~8pt per column),
      # between 4 columns and the window's width.
      pixels=$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
      (( pixels > 0 )) || pixels=640
      cells=$(( pixels / 16 ))
      (( cells < 4 )) && cells=4
      (( cells > COLUMNS - 2 )) && cells=$(( COLUMNS - 2 ))
      builtin printf '\e]1337;File=inline=1;width=%d;preserveAspectRatio=1:%s\a\n' "$cells" \
        "$(base64 < "$file" | tr -d '\n')"
    done
  }
fi

# Commands arrive as bracketed pastes; don't render them highlighted.
typeset -ga zle_highlight
zle_highlight=(${zle_highlight:#paste:*} paste:none)

builtin printf '\e]6973;hello=1\a'
