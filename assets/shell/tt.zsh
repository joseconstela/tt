# tt shell integration for zsh.
#
# Emits semantic marks so the app can split the PTY stream into blocks:
#   OSC 133;C            command output starts   (preexec)
#   OSC 133;D;<status>   command finished        (precmd)
#   OSC 133;A            prompt starts           (precmd)
#   OSC 7777;cwd;<path>  / OSC 7777;branch;<name>
#   OSC 7777;cnf;<name>  a command the shell does not know (command_not_found_handler)
# Everything the shell prints between D and the next C (prompt, line editor
# echo, completion menus) is ignored by the app, which has its own input box.

[[ -n "$__tt_loaded" ]] && return
__tt_loaded=1

__tt_precmd() {
  local __tt_status=$?
  builtin printf '\e]133;D;%s\a' "$__tt_status"
  builtin printf '\e]7777;cwd;%s\a' "$PWD"
  local __tt_branch
  __tt_branch=$(command git symbolic-ref --short -q HEAD 2>/dev/null || command git rev-parse --short HEAD 2>/dev/null)
  builtin printf '\e]7777;branch;%s\a' "$__tt_branch"
  builtin printf '\e]133;A\a'
}

__tt_preexec() {
  builtin printf '\e]133;C\a'
}

# The shell does not know a command: tell the app (which may hand the line
# to an agent), then do what zsh would — or what the user's own handler does.
if (( $+functions[command_not_found_handler] )); then
  functions[__tt_user_cnf_handler]=$functions[command_not_found_handler]
fi
command_not_found_handler() {
  builtin printf '\e]7777;cnf;%s\a' "$1"
  if (( $+functions[__tt_user_cnf_handler] )); then
    __tt_user_cnf_handler "$@"
    return $?
  fi
  builtin print -u2 -- "zsh: command not found: $1"
  return 127
}

# Our precmd runs first (so the block closes before slow prompt plugins run)
# and our preexec runs last (so nothing else prints into the block header).
typeset -ga precmd_functions preexec_functions
precmd_functions=(__tt_precmd ${precmd_functions:#__tt_precmd})
preexec_functions=(${preexec_functions:#__tt_preexec} __tt_preexec)

# zsh prints an inverse "%" plus a line of spaces before each prompt to protect
# partial lines (PROMPT_SP). Blocks make that unnecessary, and it would land
# inside the captured output, so switch it off.
unsetopt PROMPT_SP

# The app renders output itself; pagers would just hang waiting for keys.
export PAGER=cat GIT_PAGER=cat MANPAGER=cat SYSTEMD_PAGER=cat
