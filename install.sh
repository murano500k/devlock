#!/usr/bin/env bash
# Wire a devlock checkout into this machine (idempotent): the Claude skill link, `devlock` on PATH,
# your devices.conf, and the agent hooks (through `devlock install`).
#
#   ./install.sh [--conf PATH] [--claude] [--codex] [--cursor]
#     --conf PATH   your device list, linked into the state dir
#     agents        whose hooks to register (default: every agent set up on this machine)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SKILL=$CLAUDE_DIR/skills/devlock

args=()
while [ $# -gt 0 ]; do
	case $1 in
		--conf) args+=(--conf "${2:?--conf needs a path}"); shift 2 ;;
		--conf=*) args+=(--conf "${1#--conf=}"); shift ;;
		--claude|--codex|--cursor) args+=("$1"); shift ;;
		-h|--help) sed -n '2,7p' "$0"; exit 0 ;;
		*) echo "error: unknown argument $1" >&2; exit 2 ;;
	esac
done

claude=false
case " ${args[*]-} " in *" --claude "*) claude=true ;; esac
[ -d "$CLAUDE_DIR" ] && claude=true
mkdir -p "$HOME/.local/bin"
if $claude && [ "$(cd "$SKILL" 2>/dev/null && pwd -P)" != "$(cd "$HERE" && pwd -P)" ]; then
	if [ -e "$SKILL" ] && [ ! -L "$SKILL" ]; then
		echo "error: $SKILL exists and is not a link - move it away first" >&2
		exit 1
	fi
	mkdir -p "$(dirname "$SKILL")"
	ln -sfn "$HERE" "$SKILL"
	echo "skill: $SKILL -> $HERE"
fi
ln -sfn "$HERE/devlock" "$HOME/.local/bin/devlock"

exec "$HERE/devlock" install ${args[@]+"${args[@]}"}
