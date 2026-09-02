#!/usr/bin/env zsh

setopt no_unset pipe_fail

typeset event=${1:-}
typeset script_dir=${0:A:h}
typeset tmux_path=''
[[ $event == (began|attention|completed|failed) ]] || exit 0

# Resolve the optional command while the hook still has Claude's inherited PATH. The paired
# normalizer receives only an absolute external executable path and never searches PATH itself.
if [[ $event == (attention|completed|failed) && -n ${TMUX-} && ${TMUX_PANE-} =~ '^%[0-9]{1,255}$' ]]; then
  typeset candidate
  candidate=$(whence -p tmux 2>/dev/null) || true
  if [[ -n $candidate && -x $candidate ]]; then
    tmux_path=${candidate:A}
  fi
fi

# The normalizer reads the hook payload once and writes only the normalized event.
AGENT_NOTIFY_TMUX_PATH="$tmux_path" /usr/bin/osascript -l JavaScript "$script_dir/agent-notify-claude-hook.jxa" "$event" |
  "$script_dir/agent-notify" event >/dev/null 2>&1 || true
