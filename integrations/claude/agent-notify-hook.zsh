#!/usr/bin/env zsh

setopt no_unset pipe_fail

typeset event=${1:-}
typeset script_dir=${0:A:h}
[[ $event == (began|attention|completed|failed) ]] || exit 0

# The normalizer reads the hook payload once and writes only the normalized event.
/usr/bin/osascript -l JavaScript "$script_dir/agent-notify-claude-hook.jxa" "$event" |
  "$script_dir/agent-notify" event >/dev/null 2>&1 || true
