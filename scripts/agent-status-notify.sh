#!/usr/bin/env bash
# Codex `notify` program. Wire it up in ~/.codex/config.toml:
#
#   notify = ["/absolute/path/to/agent-tmux/scripts/agent-status-notify.sh"]
#
# Codex's interactive TUI does NOT fire per-turn lifecycle hooks the way Claude
# Code does — it emits SessionStart and UserPromptSubmit only. The per-turn
# "agent finished" signal is the notify/agent-turn-complete event, which (with
# the in-process TUI; see the codex() shell wrapper in the README) runs with
# $TMUX_PANE set. Codex appends the event JSON as the last argv; we ignore it
# and just mark the pane "waiting" (yellow = your move).
#
# stdin is redirected from /dev/null so agent-status.sh never blocks on a read.
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
exec "$here/agent-status.sh" waiting </dev/null
