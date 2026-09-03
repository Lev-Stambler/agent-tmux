#!/usr/bin/env bash
# Clean-room install test: a fresh container, a fresh user, an empty $HOME, and
# nothing installed but tmux/git/fzf. Proves the plugin works for someone who
# has never had any of this — the case local testing structurally cannot cover,
# because a developer's machine always has their own dotfiles in it.
#
# Runs the matrix that matters: the oldest tmux we claim to support (3.2a on
# Ubuntu 22.04), the current one (3.4), Debian's (3.3a), a no-fzf box, and one
# BELOW the floor (3.0a) which must refuse cleanly instead of half-installing.
#
#   Usage: tests/cleanroom.sh [docker-cmd]     (default: sudo docker)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DOCKER="${1:-sudo docker}"

SRC="$(mktemp -d)"; trap 'rm -rf "$SRC"' EXIT
cp -r "$ROOT" "$SRC/agent-tmux"
rm -rf "$SRC/agent-tmux/.git" "$SRC/agent-tmux/tests/vhs/out"

PASS=0; FAIL=0
probe(){ # <image> <label> <pkgs>
  printf '\n======== %s — %s ========\n' "$1" "$2"
  if $DOCKER run --rm \
      -v "$SRC/agent-tmux:/srv/agent-tmux:ro" \
      -v "$HERE/cleanroom-probe.sh:/probe.sh:ro" "$1" bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq tmux git ca-certificates $3 >/dev/null 2>&1
        useradd -m -s /bin/bash tester; cp /probe.sh /home/tester/probe.sh
        su - tester -c 'bash /home/tester/probe.sh'"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
}

probe ubuntu:22.04 "oldest supported tmux (3.2a)" fzf
probe debian:12    "tmux 3.3a"                    fzf
probe ubuntu:24.04 "current tmux (3.4)"           fzf
probe ubuntu:24.04 "no fzf: rail works, picker must fail loudly" ""

# Below the floor: display-popup is 3.2+, so without the version gate the status
# row installs while every key binding silently fails. Must refuse instead.
printf '\n======== ubuntu:20.04 — tmux 3.0a, BELOW the floor ========\n'
out="$($DOCKER run --rm \
  -v "$SRC/agent-tmux:/srv/agent-tmux:ro" \
  -v "$HERE/cleanroom-oldtmux.sh:/old.sh:ro" ubuntu:20.04 bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq tmux >/dev/null 2>&1
    useradd -m -s /bin/bash t; cp /old.sh /home/t/old.sh
    su - t -c "bash /home/t/old.sh"' 2>&1 | tail -4)"
echo "$out"
if grep -q 'rows=on' <<<"$out" && grep -q 'bound=no' <<<"$out" && grep -q 'needs tmux 3.2' <<<"$out"; then
  echo "  PASS  refused cleanly, with a queryable reason"; PASS=$((PASS+1))
else
  echo "  FAIL  did not refuse cleanly"; FAIL=$((FAIL+1))
fi

printf '\n======================================\nCLEAN ROOM MATRIX: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
