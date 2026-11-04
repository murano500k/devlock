#!/usr/bin/env bash
# devlock end to end: real `claude -p` sessions against the installed hooks, on a fake device.
# Needs install.sh to have run. Costs two short Haiku sessions.
set -u
DL=$HOME/.claude/skills/devlock/devlock
export DEVLOCK_DIR=$(mktemp -d)
trap 'kill ${runpid:-} 2>/dev/null; rm -rf "$DEVLOCK_DIR"' EXIT
echo 'FAKEDEV1 10.255.0.1:5555' > "$DEVLOCK_DIR/devices.conf"
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

ask() {
	claude -p --model haiku --allowedTools Bash --output-format stream-json --verbose \
		"Run exactly this command with the Bash tool, once, in the foreground, then reply with one word DONE: adb -s 10.255.0.1:5555 get-state" \
		2>/dev/null | jq -cR "fromjson? | select(.type==\"user\") | .message.content[0].content" >> "$DEVLOCK_DIR/claude.log"
}

CLAUDE_CODE_SESSION_ID=other-session "$DL" run FAKEDEV1 -- sleep 300 2>/dev/null &
runpid=$!
sleep 1
ask
grep -q "DENY .*10.255.0.1:5555" "$DEVLOCK_DIR/hook.log" 2>/dev/null \
	&& ok "session refused while another session's run holds the device" || bad "session refused while held"

kill $runpid; wait $runpid 2>/dev/null
ask
grep -q "ALLOW .*FAKEDEV1" "$DEVLOCK_DIR/hook.log" 2>/dev/null \
	&& ok "session allowed once the device is free" || bad "session allowed once free"
[ ! -s "$DEVLOCK_DIR/FAKEDEV1.lease" ] \
	&& ok "lease released when the session ended" || bad "lease released at session end: $(cat "$DEVLOCK_DIR/FAKEDEV1.lease")"

[ $fail = 0 ] || { echo "--- hook.log"; cat "$DEVLOCK_DIR/hook.log" 2>/dev/null; echo "--- tool results"; cat "$DEVLOCK_DIR/claude.log"; }
exit $fail
