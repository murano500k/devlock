#!/usr/bin/env bash
# Wire devlock into this machine (idempotent): the skill link ~/.claude/skills/devlock, `devlock` on
# PATH, your devices.conf, and the Claude Code hooks in ~/.claude/settings.json (replaces any older
# devlock hook entries).
#
#   ./install.sh [--conf PATH]    PATH: your device list, linked into the state dir
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE=${DEVLOCK_DIR:-$HOME/.local/state/devlock}
SETTINGS=$HOME/.claude/settings.json
SKILL=$HOME/.claude/skills/devlock
TOOL=$SKILL/devlock

conf=
while [ $# -gt 0 ]; do
	case $1 in
		--conf) conf=${2:?--conf needs a path}; shift 2 ;;
		--conf=*) conf=${1#--conf=}; shift ;;
		-h|--help) sed -n '2,6p' "$0"; exit 0 ;;
		*) echo "error: unknown argument $1" >&2; exit 2 ;;
	esac
done

mkdir -p "$STATE" "$HOME/.local/bin" "$(dirname "$SKILL")"
if [ "$(readlink -f "$SKILL" 2>/dev/null)" != "$HERE" ]; then
	if [ -e "$SKILL" ] && [ ! -L "$SKILL" ]; then
		echo "error: $SKILL exists and is not a link - move it away first" >&2
		exit 1
	fi
	ln -sfn "$HERE" "$SKILL"
	echo "skill: $SKILL -> $HERE"
fi
ln -sfn "$TOOL" "$HOME/.local/bin/devlock"

if [ -n "$conf" ]; then
	[ -f "$conf" ] || { echo "error: no such file: $conf" >&2; exit 1; }
	ln -sfn "$(readlink -f "$conf")" "$STATE/devices.conf"
	echo "devices.conf -> $(readlink -f "$conf")"
elif [ ! -e "$STATE/devices.conf" ]; then
	echo "warning: no $STATE/devices.conf - devices are only known by the names adb gets (see --conf)" >&2
fi

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
new=$(jq --arg c '$HOME/.claude/skills/devlock/devlock hook' '
	def strip: map(.hooks |= map(select((.command // "") | test("devlock") | not))) | map(select(.hooks | length > 0));
	def add($ev; $m; $arg): .hooks[$ev] = ((.hooks[$ev] // []) | strip) +
		[{hooks: [{type: "command", command: "\($c) \($arg)", timeout: 10}]} + (if $m then {matcher: $m} else {} end)];
	.hooks //= {}
	| add("PreToolUse"; "Bash|Monitor"; "pre")
	| add("PostToolUse"; "Bash"; "post")
	| add("PostToolUseFailure"; "Bash"; "post")
	| add("Stop"; null; "stop")
	| add("SessionEnd"; null; "stop")' "$SETTINGS")
if [ "$new" = "$(jq . "$SETTINGS")" ]; then
	echo "hooks already registered in $SETTINGS"
	exit 0
fi
backup=$SETTINGS.bak-devlock-$(date +%Y%m%d-%H%M%S)
cp "$SETTINGS" "$backup"
# Write in place: settings.json may be a symlink into another repo.
printf '%s\n' "$new" > "$SETTINGS"
echo "hooks registered in $SETTINGS (backup: $backup)"
