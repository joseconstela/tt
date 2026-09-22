# conch shell integration for zsh.
#
# Emits semantic marks so the app can split the PTY stream into blocks:
#   OSC 133;C            command output starts   (preexec)
#   OSC 133;D;<status>   command finished        (precmd)
#   OSC 133;A            prompt starts           (precmd)
#   OSC 7777;cwd;<path>  / OSC 7777;branch;<name>
#   OSC 7777;cnf;<name>  a command the shell does not know (command_not_found_handler)
# Everything the shell prints between D and the next C (prompt, line editor
# echo, completion menus) is ignored by the app, which has its own input box.

[[ -n "$__conch_loaded" ]] && return
__conch_loaded=1

__conch_precmd() {
  local __conch_status=$?
  builtin printf '\e]133;D;%s\a' "$__conch_status"
  builtin printf '\e]7777;cwd;%s\a' "$PWD"
  local __conch_branch
  __conch_branch=$(command git symbolic-ref --short -q HEAD 2>/dev/null || command git rev-parse --short HEAD 2>/dev/null)
  builtin printf '\e]7777;branch;%s\a' "$__conch_branch"
  builtin printf '\e]133;A\a'
}

__conch_preexec() {
  builtin printf '\e]133;C\a'
}

# The shell does not know a command: tell the app (which may hand the line
# to an agent), then do what zsh would — or what the user's own handler does.
if (( $+functions[command_not_found_handler] )); then
  functions[__conch_user_cnf_handler]=$functions[command_not_found_handler]
fi
command_not_found_handler() {
  builtin printf '\e]7777;cnf;%s\a' "$1"
  if (( $+functions[__conch_user_cnf_handler] )); then
    __conch_user_cnf_handler "$@"
    return $?
  fi
  builtin print -u2 -- "zsh: command not found: $1"
  return 127
}

# Our precmd runs first (so the block closes before slow prompt plugins run)
# and our preexec runs last (so nothing else prints into the block header).
typeset -ga precmd_functions preexec_functions
precmd_functions=(__conch_precmd ${precmd_functions:#__conch_precmd})
preexec_functions=(${preexec_functions:#__conch_preexec} __conch_preexec)

# zsh prints an inverse "%" plus a line of spaces before each prompt to protect
# partial lines (PROMPT_SP). Blocks make that unnecessary, and it would land
# inside the captured output, so switch it off.
unsetopt PROMPT_SP

# The app renders output itself; pagers would just hang waiting for keys.
export PAGER=cat GIT_PAGER=cat MANPAGER=cat SYSTEMD_PAGER=cat
