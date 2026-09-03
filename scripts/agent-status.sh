#!/usr/bin/env bash
# agent-status.sh — color the tmux window tab by the AGGREGATE agent state of all
# panes (splits) in the window. State is tracked PER PANE (tmux pane option
# @agent_state); the tab shows the highest-priority concern so one split never hides
# another:
#
#   blocked  -> RED    #f38ba8 (filled pill)  a pane needs a decision (permission/question)
#   waiting  -> YELLOW #f9e2af (filled pill)  a pane finished its turn — your move
#   working  -> BLUE   #89b4fa (subtle pill)  a pane is busy, nothing needs you
#   done     -> GREEN  #a6e3a1 (filled pill)  manually acked (prefix+g)
#   none                        -> theme default
#   priority (highest concern wins): blocked > waiting > working > acked > none
#
# Driven by Claude Code + Codex lifecycle hooks (and the Codex `notify` program),
# called as:  agent-status.sh <working|waiting|blocked|done|clear>
#
# Robustness contract:
#   * Drains stdin (hooks pipe JSON; an unread pipe can SIGPIPE the caller).
#   * No-op (exit 0) when not under tmux, or when the tmux server is unreachable
#     (e.g. inside the bwrap sandbox whose /tmp is a fresh tmpfs).
#   * Resolves the owning pane via $TMUX_PANE (or the Codex cwd-fallback), so the
#     correct window colors even while you are looking at a different one.

state="${1:-clear}"

# Capture any hook JSON on stdin (also drains it so the writer never gets SIGPIPE).
payload=""
[ -t 0 ] || payload="$(cat 2>/dev/null)"

# True if a Stop payload still lists a running/pending background task.
# (Claude Code >= 2.1.145 includes a background_tasks[] array on Stop.)
has_running_bg(){
  [ -n "$payload" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    local n
    n="$(printf '%s' "$payload" \
         | jq '[.background_tasks[]? | select(.status=="running" or .status=="pending")] | length' 2>/dev/null)"
    [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null
  else
    printf '%s' "$payload" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"(running|pending)"'
  fi
}

# True if the process subtree rooted at $1 (pane_pid) is running the codex CLI.
# Codex is a node script launched as `node .../bin/codex`, so match the executable
# path 'bin/codex' (NOT a bare "codex" substring that would false-match other commands).
# A process's full command line. Linux exposes it verbatim in /proc; BSD/macOS
# have no /proc, so fall back to ps (truncation there is fine — we only need the
# leading executable path).
_cmdline(){
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
  else
    ps -o command= -p "$1" 2>/dev/null
  fi
}
# Direct children of a pid. GNU ps has --ppid; BSD ps does not.
_children(){
  if [ -d /proc ]; then
    ps -o pid= --ppid "$1" 2>/dev/null
  else
    ps -Ao pid=,ppid= 2>/dev/null | awk -v p="$1" '$2==p {print $1}'
  fi
}
proc_tree_runs_codex(){
  local root="$1" c g
  is_codex(){ _cmdline "$1" | grep -Eq '(^|/)codex( |$)|bin/codex'; }
  is_codex "$root" && return 0
  for c in $(_children "$root"); do
    is_codex "$c" && return 0
    for g in $(_children "$c"); do
      is_codex "$g" && return 0
    done
  done
  return 1
}

# --- resolve the target pane --------------------------------------------------
#  - Claude (and Codex via the in-process codex() wrapper) export $TMUX_PANE.
#  - Codex's app-server daemon runs hooks DETACHED from the pane ($TMUX_PANE empty);
#    recover the pane from the payload "cwd" by finding the unique codex pane there.
pane="${TMUX_PANE:-}"
if [ -z "$pane" ]; then
  cwd=""
  if [ -n "$payload" ]; then
    if command -v jq >/dev/null 2>&1; then
      cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
    fi
    [ -n "$cwd" ] || cwd="$(printf '%s' "$payload" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/^"cwd":"//;s/"$//')"
  fi
  if [ -n "$cwd" ]; then
    # $TMUX is empty here, so tmux uses the default socket (the user's server).
    while IFS="$(printf '\t')" read -r p_pid p_id; do
      [ -n "$p_pid" ] || continue
      if proc_tree_runs_codex "$p_pid"; then
        [ -n "$pane" ] && { pane=""; break; }   # >1 codex pane in cwd -> ambiguous, bail
        pane="$p_id"
      fi
    done <<EOF
$(tmux list-panes -a -F "#{pane_current_path}$(printf '\t')#{pane_pid}$(printf '\t')#{pane_id}" 2>/dev/null \
   | awk -F"$(printf '\t')" -v d="$cwd" '$1==d {print $2"\t"$3}')
EOF
  fi
fi
[ -n "$pane" ] || exit 0

# Server must be reachable (sandbox-safe: silently no-op if not).
tmux display-message -p -t "$pane" '' >/dev/null 2>&1 || exit 0
wid="$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)" || exit 0
[ -n "$wid" ] || exit 0

setw(){ tmux set-window-option -t "$wid" "$@" 2>/dev/null; }
# Force every attached client to redraw the status line now, instead of waiting for
# the (default 15s) status-interval — otherwise a color set on a window you are NOT
# viewing can appear to "not change" until the next refresh.
refresh(){ tmux refresh-client -S 2>/dev/null; }

# Every hook call is an interaction: stamp the pane so agent-review.sh's `t`
# recency filter can rank/hide panes by when their agent last did anything.
tmux set-option -p -t "$pane" @agent_last "$(date +%s)" 2>/dev/null

# --- store THIS pane's state (per-pane option, auto-removed when the pane closes) --
# An end-of-turn state (waiting/done) with bg work still running is not "needs you".
case "$state" in
  waiting|done) has_running_bg && state="working" ;;
esac
case "$state" in
  clear)                        tmux set-option -p -t "$pane" -u @agent_state 2>/dev/null ;;
  working|waiting|blocked|done) tmux set-option -p -t "$pane" @agent_state "$state" 2>/dev/null ;;
  *) exit 0 ;;   # unknown state -> no-op
esac

# --- recompute the window aggregate (highest-priority concern across its panes) ---
prio(){ case "$1" in blocked) echo 4;; waiting) echo 3;; working) echo 2;; done) echo 1;; *) echo 0;; esac; }
best=0
while read -r _st; do
  c="$(prio "$_st")"; [ "$c" -gt "$best" ] && best="$c"
done < <(tmux list-panes -t "$wid" -F '#{@agent_state}' 2>/dev/null)

if [ "$best" -eq 0 ]; then
  for o in window-status-format window-status-current-format \
           pane-active-border-style pane-border-style; do
    setw -u "$o"
  done
  refresh
  exit 0
fi

# Palette: Catppuccin Mocha defaults, overridable via @agent_tmux_* options so
# a non-catppuccin user can retheme without forking. One show-options fork, and
# only on a hook call (not on every status redraw).
crust='#11111b'
surface='#313244'   # surface_0 — muted pill bg for the subtle "working" tab
c_blocked='#f38ba8' # red    — a pane is blocked (permission/question)
c_waiting='#f9e2af' # yellow — a pane finished its turn (your move)
c_working='#89b4fa' # blue   — a pane working, nothing needs you
c_acked='#a6e3a1'   # green  — only manually-acked panes
opts="$(tmux show-options -g 2>/dev/null | grep '^@agent_tmux_' 2>/dev/null)"
if [ -n "$opts" ]; then
  while IFS= read -r line; do
    k="${line%% *}"; v="${line#* }"; v="${v%\"}"; v="${v#\"}"
    [ -n "$v" ] || continue
    case "$k" in
      @agent_tmux_accent_fg)      crust="$v" ;;
      @agent_tmux_pill_bg)        surface="$v" ;;
      @agent_tmux_state_blocked)  c_blocked="$v" ;;
      @agent_tmux_state_waiting)  c_waiting="$v" ;;
      @agent_tmux_state_working)  c_working="$v" ;;
      @agent_tmux_state_acked)    c_acked="$v" ;;
    esac
  done <<EOF
$opts
EOF
fi
case "$best" in
  4) col="$c_blocked"; subtle=0 ;;
  3) col="$c_waiting"; subtle=0 ;;
  2) col="$c_working"; subtle=1 ;;
  1) col="$c_acked";   subtle=0 ;;
esac

# Rounded powerline half-circle caps () keep the Catppuccin "rounded" tab look
# without depending on its internals. "#I #W" keeps the window number visible.
#   pill <cap_fg> <pill_bg> <pill_fg> [bold]
pill(){
  local cap="$1" bg="$2" fg="$3" b="${4:-}"
  printf '#[fg=%s,bg=default]#[bg=%s,fg=%s%s] #I #W #[fg=%s,bg=default]#[default]' \
         "$cap" "$bg" "$fg" "${b:+,bold}" "$cap"
}

if [ "$subtle" -eq 1 ]; then
  fmt="$(pill "$surface" "$surface" "$col")"
  fmt_cur="$(pill "$col" "$surface" "$col" bold)"
else
  fmt="$(pill "$col" "$col" "$crust")"
  fmt_cur="$(pill "$col" "$col" "$crust" bold)"
fi

setw window-status-format "$fmt"
setw window-status-current-format "$fmt_cur"
setw pane-active-border-style "fg=$col"
setw pane-border-style "fg=$col"
refresh
