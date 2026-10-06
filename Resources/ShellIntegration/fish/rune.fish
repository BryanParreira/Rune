# Rune shell integration for fish (3.0 and later).
#
# Rune starts fish as a login shell with `--init-command 'source …/rune.fish'`, which runs
# after the user's own config.fish; nothing in the user's config is changed. Prompt and
# command marks go through Rune's private OSC 6973 (`mark=A`…), so they never mix with the
# OSC 133 marks newer fish versions print on their own.

status is-interactive; or exit
set -q __rune_loaded; and exit
set -g __rune_loaded 1
set -g __rune_running 0
set -g __rune_names_sent 0

function __rune_osc --description 'Rune: send key=value (value percent-encoded)'
    printf '\e]6973;%s=%s\a' $argv[1] (string escape --style=url -- "$argv[2]")
end

# Keep the user's prompts to show when Rune is asked to honor them.
functions -q fish_prompt; and functions -c fish_prompt __rune_user_prompt
functions -q fish_right_prompt; and functions -c fish_right_prompt __rune_user_right_prompt
functions -q fish_mode_prompt; and functions -c fish_mode_prompt __rune_user_mode_prompt

function fish_prompt
    set -l rc $status
    if test "$__rune_running" = 1
        printf '\e]6973;mark=D;%s\a' $rc
        set -g __rune_running 0
    else
        printf '\e]6973;mark=D\a'
    end
    __rune_osc cwd $PWD
    # The active Python environment, for Rune's context chips (only when it changes).
    set -l pyenv "$VIRTUAL_ENV|$CONDA_DEFAULT_ENV"
    if not set -q __rune_last_pyenv; or test "$pyenv" != "$__rune_last_pyenv"
        set -g __rune_last_pyenv $pyenv
        __rune_osc pyenv $pyenv
    end
    # Once the config has loaded: functions and abbreviations (colored as commands in Rune's
    # editor) and the PATH.
    if test "$__rune_names_sent" = 0
        set -g __rune_names_sent 1
        __rune_osc names (string join ' ' (functions -n | string match -v -- '_*') (abbr --list 2>/dev/null))
        __rune_osc path (string join : $PATH)
    end
    if test "$RUNE_HONOR_PROMPT" = 1
        printf '\n\e]6973;mark=A\a\n'
        functions -q __rune_user_prompt; and __rune_user_prompt
        printf '\e]6973;mark=B\a\e[?25h'
    else
        # Rune shows the context itself: a blank row between blocks, then the block's header
        # row; the cursor stays hidden while Rune's editor has the keyboard.
        printf '\n\e]6973;mark=A\a\n\e]6973;mark=B\a\e[?25l'
    end
end

function fish_right_prompt
    test "$RUNE_HONOR_PROMPT" = 1; and functions -q __rune_user_right_prompt; and __rune_user_right_prompt
end

function fish_mode_prompt
    test "$RUNE_HONOR_PROMPT" = 1; and functions -q __rune_user_mode_prompt; and __rune_user_mode_prompt
end

function __rune_preexec --on-event fish_preexec
    set -g __rune_running 1
    __rune_osc cmd $argv[1]
    printf '\e[?25h\e]6973;mark=C\a'
end

# Rune keeps a spare shell ready; when it hands one to a tab in another folder it writes the
# folder to $RUNE_CD_FILE and sends SIGUSR1: move there quietly and report it.
function __rune_usr1 --on-signal SIGUSR1
    test -n "$RUNE_CD_FILE"; and test -r "$RUNE_CD_FILE"; or return 0
    set -l dir (cat -- $RUNE_CD_FILE)
    command rm -f -- $RUNE_CD_FILE
    builtin cd -- $dir 2>/dev/null; or return 0
    __rune_osc cwd $PWD
    commandline -f repaint
end

# Keys Rune sends around the commands it writes (never typed by a person):
#   ESC[9972~  clear the line, so keys typed while the last command ran don't join the next
#   ESC[9973~  hand the line to Rune's editor (input=…), then clear it
function __rune_take_line
    __rune_osc input (string join \n -- (commandline))
    commandline -r ''
end
set -l __rune_line_keys 1
for mode in default insert
    bind -M $mode \e\[9972~ 'commandline -r ""' 2>/dev/null; or set __rune_line_keys 0
    bind -M $mode \e\[9973~ __rune_take_line 2>/dev/null; or set __rune_line_keys 0
end

if test "$__rune_line_keys" = 1
    printf '\e]6973;hello=2\a'
else
    printf '\e]6973;hello=1\a'
end
