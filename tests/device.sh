#!/usr/bin/env bash
# devlock on a real device: real adb commands, real `claude -p` sessions and one interactive Claude
# session in tmux, all against a throwaway state dir (your real locks are not touched).
#
#   tests/device.sh SERIAL ADDRESS      e.g. tests/device.sh R58M12345AB 192.168.0.50:5555
#
# Only read-only adb commands are sent (get-state, getprop, sleep). Take the device in your real
# state first (`devlock hold <serial>`), so no other session uses it meanwhile.
# Needs install.sh to have run. Costs a few short Haiku sessions. Skip the Claude parts with
# DEVLOCK_TEST_NO_CLAUDE=1.
set -u
DEV=${1:?serial}
ADDR=${2:?network address of the same device}
DL=$HOME/.claude/skills/devlock/devlock
export DEVLOCK_DIR=$(mktemp -d)
unset DEVLOCK_CONF DEVLOCK_STICKY_SEC ANDROID_SERIAL DEVLOCK_HELD
TMUX_S=devlock-test-$$
trap 'tmux kill-session -t $TMUX_S 2>/dev/null; pkill -P $$ 2>/dev/null; rm -rf "$DEVLOCK_DIR"' EXIT
echo "$DEV $ADDR tvx" > "$DEVLOCK_DIR/devices.conf"

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1${2:+ -- $2}"; }
hook() {
	jq -nc --arg s "$2" --arg c "$3" '{session_id: $s, tool_name: "Bash", tool_input: {command: $c}}' | "$DL" hook "$1"
}
# exec_as SESSION COMMAND: what Claude Code does - pre hook, run if allowed, post hook
exec_as() {
	local o; o=$(hook pre "$1" "$2")
	[[ "$o" == *deny* ]] && { echo "DENIED"; return 1; }
	bash -c "$2"; local rc=$?
	hook post "$1" "$2" >/dev/null
	return $rc
}
turn_end() { jq -nc --arg s "$1" '{session_id: $s}' | "$DL" hook stop; }
sess_end() { jq -nc --arg s "$1" '{session_id: $s}' | "$DL" hook end; }
lease_field() { jq -r ".$2 // empty" "$DEVLOCK_DIR/$1.lease" 2>/dev/null; }
reset() { for s in A B C; do sess_end $s; done; }

[ "$(adb -s "$DEV" get-state 2>/dev/null)" = device ] || { echo "$DEV is not online"; exit 2; }
[ "$(adb -s "$ADDR" get-state 2>/dev/null)" = device ] || { echo "$ADDR is not online"; exit 2; }
serialno=$(adb -s "$DEV" shell getprop ro.serialno | tr -d '\r')

# --- one lock for every name of the device
out=$(exec_as A "adb -s $DEV shell getprop ro.serialno" | tr -d '\r')
[ "$out" = "$serialno" ] && ok "A runs a real command over USB" || bad "A runs a real command over USB" "$out"
[ "$(exec_as B "adb -s $ADDR get-state")" = DENIED ] && ok "B refused over the network address" || bad "B refused over the network address"
[ "$(exec_as B "ANDROID_SERIAL=$ADDR adb shell true")" = DENIED ] && ok "B refused through ANDROID_SERIAL" || bad "B refused through ANDROID_SERIAL"
[ "$(exec_as B "adb kill-server")" = DENIED ] && ok "B's adb kill-server refused (not run)" || bad "B's adb kill-server refused"
reset

# --- devlock run turns a nickname into a name adb knows
out=$(CLAUDE_CODE_SESSION_ID=A "$DL" run tvx -- 'echo "$ANDROID_SERIAL"; adb shell getprop ro.serialno' 2>/dev/null | tr -d '\r')
name=$(sed -n 1p <<<"$out"); got=$(sed -n 2p <<<"$out")
{ [ "$name" = "$DEV" ] || [ "$name" = "$ADDR" ]; } && [ "$got" = "$serialno" ] \
	&& ok "run tvx -> ANDROID_SERIAL=$name, real adb works" || bad "run tvx -> adb name" "$out"

# --- two runs on the device never overlap; the second one is listed as waiting
log=$DEVLOCK_DIR/runs.log
job='echo "start $(date +%s.%N)" >> '"$log"'; adb shell sleep 4; echo "end $(date +%s.%N)" >> '"$log"
CLAUDE_CODE_SESSION_ID=A "$DL" run "$DEV" -- "$job" 2>/dev/null & p1=$!
sleep 1
CLAUDE_CODE_SESSION_ID=B "$DL" run "$ADDR" -- "$job" 2>/dev/null & p2=$!
sleep 1.5
"$DL" status | grep -q "^$DEV  waiting #1: session=B" && ok "status lists B's run as waiting #1" || bad "status lists B's run as waiting" "$("$DL" status)"
wait $p1 $p2
paste -sd' ' "$log" | awk '{exit !($1 == "start" && $3 == "end" && $5 == "start" && $4 <= $6)}' \
	&& ok "the two runs did not overlap" || bad "the two runs did not overlap" "$(cat "$log")"
[ "$(jq length "$DEVLOCK_DIR/$DEV.queue")" = 0 ] && ok "queue empty afterwards" || bad "queue empty afterwards"

# --- a killed waiter leaves the queue
CLAUDE_CODE_SESSION_ID=A "$DL" run "$DEV" -- 'adb shell sleep 6' 2>/dev/null & p1=$!
sleep 1
CLAUDE_CODE_SESSION_ID=B "$DL" run "$DEV" -- true 2>/dev/null & p2=$!
sleep 1.5
kill -9 $p2; wait $p2 2>/dev/null
"$DL" status | grep -q "waiting" && bad "kill -9 waiter disappears from status" || ok "kill -9 waiter disappears from status"
wait $p1

# --- sticky window with real commands
exec_as A "adb -s $DEV shell getprop ro.build.version.sdk" >/dev/null
turn_end A
[ "$(lease_field "$DEV" idle)" = true ] && ok "end of turn keeps an idle lease" || bad "end of turn keeps an idle lease"
[ "$(exec_as B "adb -s $ADDR shell true")" = DENIED ] && ok "B's plain command refused during the window" || bad "B's plain command refused during the window"
exec_as A "adb -s $DEV shell true" >/dev/null && [ -z "$(lease_field "$DEV" idle)" ] \
	&& ok "A's next prompt gets its device back" || bad "A's next prompt gets its device back"
turn_end A
t0=$(date +%s)
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 30 "$ADDR" -- 'adb shell getprop ro.serialno' >/dev/null 2>&1
[ $? = 0 ] && [ $(( $(date +%s) - t0 )) -le 3 ] && ok "B's run takes over the idle lease at once" || bad "B's run takes over the idle lease at once"
[ "$(exec_as A "adb -s $DEV shell true" >/dev/null; echo $?)" = 0 ] && ok "A can use it again after B's run" || bad "A can use it again after B's run"
reset

# --- a waiting run ends the holder's window at the end of its turn
exec_as A "adb -s $DEV shell true" >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 60 "$DEV" -- 'adb shell true' 2>/dev/null & p2=$!
sleep 1.5
t0=$(date +%s); turn_end A; wait $p2; rc=$?
[ $rc = 0 ] && [ $(( $(date +%s) - t0 )) -le 3 ] && ok "A's turn end hands the device to B's waiting run" || bad "A's turn end hands the device to B's waiting run" "rc=$rc"
reset

# --- hold
CLAUDE_CODE_SESSION_ID=A "$DL" hold --ttl 5m --note "device test" tvx >/dev/null && ok "A holds the device" || bad "A holds the device"
turn_end A
o=$(hook pre B "adb -s $ADDR get-state")
[[ "$o" == *"held by session A"*"device test"* ]] && ok "B refused with the hold's note" || bad "B refused with the hold's note" "$o"
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 2 "$DEV" -- true 2>/dev/null; [ $? = 75 ] && ok "B's run waits behind the hold" || bad "B's run waits behind the hold"
exec_as A "adb -s $ADDR get-state" >/dev/null && ok "A still uses it after its turn" || bad "A still uses it after its turn"
CLAUDE_CODE_SESSION_ID=A "$DL" release tvx
[ "$(exec_as B "adb -s $DEV get-state")" = device ] && ok "release frees it for B" || bad "release frees it for B"
reset

if [ "${DEVLOCK_TEST_NO_CLAUDE:-}" != 1 ]; then
	ask() {  # ask PROMPT -> tool results appended to claude.log
		claude -p --model haiku --allowedTools Bash --output-format stream-json --verbose "$1" 2>/dev/null \
			| jq -cR 'fromjson? | select(.type=="user") | .message.content[0].content' >> "$DEVLOCK_DIR/claude.log"
	}
	# --- a hold made by a Claude session ends with that session
	ask "Run exactly these two commands with the Bash tool, one call each, in the foreground, then reply DONE: $DL hold --ttl 10m --note claude-test tvx   and then   adb -s $ADDR get-state"
	grep -q "holding $DEV" "$DEVLOCK_DIR/claude.log" && grep -q "ALLOW .*get-state" "$DEVLOCK_DIR/hook.log" && [ -z "$(jq -r '.session // empty' "$DEVLOCK_DIR/$DEV.hold" 2>/dev/null)" ] \
		&& ok "claude -p: hold taken, then dropped at SessionEnd" || bad "claude -p: hold taken, then dropped at SessionEnd" "$(cat "$DEVLOCK_DIR/$DEV.hold" 2>/dev/null)"

	# --- a terminal hold blocks a Claude session
	env -u CLAUDE_CODE_SESSION_ID "$DL" hold --ttl 5m --note terminal-hold "$DEV" >/dev/null
	ask "Run exactly this command with the Bash tool, once, in the foreground, then reply with one word DONE: adb -s $ADDR get-state"
	grep -q "DENY .*held by session shell-.*terminal-hold" "$DEVLOCK_DIR/hook.log" \
		&& ok "claude -p refused by a terminal hold, with its note" || bad "claude -p refused by a terminal hold"
	env -u CLAUDE_CODE_SESSION_ID "$DL" release "$DEV"

	# --- interactive session: real Stop keeps an idle lease, real SessionEnd drops it
	tmux new-session -d -s $TMUX_S -x 200 -y 50 \
		"cd $(pwd) && DEVLOCK_DIR=$DEVLOCK_DIR claude --model haiku --allowedTools Bash"
	sleep 8
	type_in() { tmux send-keys -t $TMUX_S -l "$1"; sleep 1; tmux send-keys -t $TMUX_S Enter; }
	type_in "Run exactly this command with the Bash tool, once, then reply DONE: adb -s $ADDR get-state"
	for _ in $(seq 60); do [ "$(lease_field "$DEV" idle)" = true ] && break; sleep 2; done
	left=$(( $(lease_field "$DEV" until | cut -d. -f1) - $(date +%s) ))
	[ "$(lease_field "$DEV" idle)" = true ] && [ $left -le 120 ] \
		&& ok "interactive: turn end leaves an idle lease ($left s left)" || bad "interactive: turn end leaves an idle lease" "$(cat "$DEVLOCK_DIR/$DEV.lease" 2>/dev/null)"
	[ "$(exec_as B "adb -s $DEV get-state")" = DENIED ] && ok "interactive: another session refused in the window" || bad "interactive: another session refused in the window"
	type_in "/exit"
	for _ in $(seq 20); do [ -z "$(lease_field "$DEV" session)" ] && break; sleep 1; done
	[ -z "$(lease_field "$DEV" session)" ] && ok "interactive: /exit drops the lease" || bad "interactive: /exit drops the lease" "$(cat "$DEVLOCK_DIR/$DEV.lease")"
fi

grep -q ERROR "$DEVLOCK_DIR/hook.log" 2>/dev/null && bad "no hook errors" "$(grep ERROR "$DEVLOCK_DIR/hook.log")" || ok "no hook errors"
echo "---- $pass passed, $fail failed"
[ $fail = 0 ]
