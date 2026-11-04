#!/usr/bin/env bash
# devlock smoke tests: fake devices in a temp state dir, no real device or adb needed.
set -u
DL=$(cd "$(dirname "$0")/.." && pwd)/devlock
export DEVLOCK_DIR=$(mktemp -d)
trap 'rm -rf "$DEVLOCK_DIR"' EXIT
unset DEVLOCK_CONF
# stop frees at once unless a test sets the sticky window itself
export DEVLOCK_STICKY_SEC=0
cat > "$DEVLOCK_DIR/devices.conf" <<'EOF'
# serial, then other names
SER1 10.0.0.2:5555 10.0.0.2 tva
SER2 10.0.0.20:5555 tvb
DONGLE 10.0.0.35:5555
script fake-ota/run\.py\s+(push|install)
EOF

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1${2:+ -- $2}"; }

# hook <mode> <session> <command> [extra tool_input json] [tool]
hook() {
	jq -nc --arg s "$2" --arg c "$3" --argjson x "${4:-{\}}" --arg t "${5:-Bash}" \
		'{session_id: $s, tool_name: $t, tool_input: ({command: $c} + $x)}' | "$DL" hook "$1"
}
allow() { local o; o=$(hook pre "$@"); [[ "$o" != *deny* ]] && ok "allow: ${2%%$'\n'*} [$1]" || bad "allow: ${2%%$'\n'*} [$1]" "$o"; }
deny()  { local o; o=$(hook pre "$@"); [[ "$o" == *deny* ]] && ok "deny:  ${2%%$'\n'*} [$1]" || bad "deny:  ${2%%$'\n'*} [$1]" "no deny"; }
stop()  { jq -nc --arg s "$1" '{session_id: $s}' | "$DL" hook stop; }
end()   { jq -nc --arg s "$1" '{session_id: $s}' | "$DL" hook end; }
reset() { end A; end B; end C; }

# --- naming
deny  A 'adb shell getprop'
deny  A 'adb -d shell getprop'
deny  A 'adb -s $TV shell getprop'
deny  A 'for d in SER1 SER2; do adb -s "$d" shell true; done'
allow A 'adb devices -l'
allow A 'adb connect 10.0.0.2:5555'
allow A 'grep -rn "adb shell" docs/'
allow A 'grep SER1 notes.txt'
allow A 'adb devices | grep SER2'
allow A "$(printf 'cat > notes.md <<END\nadb shell getprop\nANDROID_SERIAL=\x60x\x60 adb -s SER1 reboot\nEND\necho done')"
allow A 'git commit -m "docs: use adb shell with ANDROID_SERIAL="'
reset

# --- leases between sessions
allow A 'adb -s SER1 shell getprop'
deny  B 'adb -s SER1 shell getprop'
deny  B 'adb -s 10.0.0.2:5555 shell true'
deny  B 'ANDROID_SERIAL=tva ./run-tests.sh'
deny  B 'export ANDROID_SERIAL=SER1; adb shell true'
deny  B "$(printf 'cat <<END > x\ntext\nEND\nadb -s SER1 shell true')"
deny  B 'fastboot -s SER1 getvar all'
allow B 'adb -s SER2 shell getprop'
allow B 'adb -s 10.0.0.2:5556 shell true'
deny  B 'echo "$(adb -s SER1 shell getprop ro.serialno)"'
deny  B "bash -c 'adb -s SER1 reboot'"
deny  B 'timeout 30 adb -s SER1 wait-for-device'
deny  B 'python3 fake-ota/run.py push x.zip --device=10.0.0.2:5555'
allow A 'adb -s tva shell true'
stop A
allow B 'adb -s SER1 shell getprop'
reset

# --- substring boundaries: 10.0.0.2 must not match 10.0.0.20
allow A 'adb -s 10.0.0.20:5555 shell true'
allow B 'python3 tool.py --device 10.0.0.2:5555'
deny  A 'python3 tool.py 10.0.0.2:5555'
reset

# --- global operations
allow A 'adb kill-server'
allow A 'adb -s SER1 shell true'
deny  B 'adb kill-server'
deny  B 'adb disconnect'
deny  B 'adb disconnect 10.0.0.2:5555'
allow B 'adb disconnect 10.0.0.20:5555'
reset

# --- scripts that pick a device themselves
deny  A 'python3 fake-ota/run.py push build.zip'
allow A 'python3 fake-ota/run.py push build.zip --device SER2'
allow A 'python3 fake-ota/run.py plan https://x'
reset

# --- shell -c with combined flags
deny  A "bash -lc 'adb shell reboot'"
deny  A "sh -ec 'adb shell reboot'"
deny  A "bash -o pipefail -xc 'adb shell reboot'"
deny  A "sudo bash --login -c 'adb shell reboot'"
allow A "bash -lc 'adb -s SER1 shell true'"
hook pre A 'adb -s SER1 shell true' >/dev/null
deny  B "bash -lc 'adb -s tva reboot'"
allow B "bash -lc 'echo hi'"
reset

# --- gradle device tasks
deny  A './gradlew connectedAndroidTest'
deny  A './gradlew :app:connectedDebugAndroidTest --info'
deny  A 'gradle -p app installDebug'
deny  A './gradlew uninstallAll'
allow A './gradlew assembleDebug test lint'
allow A './gradlew -x installDebug assembleDebug'
allow A './gradlew installDist :cli:installShadowDist'
allow A 'ANDROID_SERIAL=SER1 ./gradlew connectedAndroidTest'
allow A 'export ANDROID_SERIAL=SER2; ./gradlew :app:installDebug'
deny  B 'ANDROID_SERIAL=tva ./gradlew connectedAndroidTest'
allow A "$DL run SER1 -- ./gradlew connectedAndroidTest"
deny  A "$DL run SER1,SER2 -- ./gradlew connectedAndroidTest"
reset

# --- ANDROID_SERIAL scope
deny  A 'ANDROID_SERIAL=SER1 true; adb shell reboot'
deny  A 'env ANDROID_SERIAL=SER1 true && adb shell reboot'
deny  A 'adb shell reboot; export ANDROID_SERIAL=SER1'
deny  A 'export ANDROID_SERIAL=SER1; unset ANDROID_SERIAL; adb shell reboot'
allow A 'export ANDROID_SERIAL=SER1; adb shell true; adb shell true'
allow A 'ANDROID_SERIAL=SER1; adb shell true'
allow A 'ANDROID_SERIAL=SER1 adb shell true; ANDROID_SERIAL=SER2 adb shell true'
allow A 'ANDROID_SERIAL= adb devices'
stop A; hook pre B 'adb -s SER2 shell true' >/dev/null
deny  A 'export ANDROID_SERIAL=SER1; ANDROID_SERIAL=SER2 adb shell true'
deny  A 'export ANDROID_SERIAL=SER2; ANDROID_SERIAL=SER1 adb shell true'
deny  A 'export ANDROID_SERIAL=SER1; bash -c "adb -s SER2 shell true"'
reset

# --- scrcpy option values
allow A 'scrcpy -b 8M -s tva'
allow A 'scrcpy --max-size 1024 --serial=SER1 -t'
allow A 'scrcpy -m1024 -sSER2'
allow A 'scrcpy --tcpip=+10.0.0.35:5555'
allow A 'scrcpy --version'
allow A 'ANDROID_SERIAL=SER1 scrcpy -b 8M'
deny  A 'scrcpy -b 8M'
deny  A 'scrcpy -t'
deny  A 'scrcpy -d'
deny  A 'scrcpy --select-tcpip -b 8M'
hook pre A 'scrcpy -b 8M -s tva' >/dev/null
deny  B 'scrcpy -b 8M -s 10.0.0.2:5555'
deny  B 'scrcpy --tcpip=10.0.0.2:5555'
reset

# --- background work must go through devlock run
deny  A 'adb -s SER1 logcat' '{"run_in_background": true}'
deny  A 'adb -s SER1 logcat | grep x' '{}' Monitor
allow A "$DL run SER1 -- adb logcat" '{"run_in_background": true}'
deny  A "$DL run SER1 -- adb -s SER2 shell true"
allow A "$DL run SER1,SER2 -- 'adb -s SER1 shell true; adb -s SER2 shell true'"
deny  A "$DL run SER1 -- adb kill-server"
allow A "$DL run tva -- 'adb shell true'"
deny  A "$DL run SER1,SER2 -- 'adb shell true'"
reset

# --- lease covers a long foreground command
hook pre A 'adb -s SER1 shell sleep 590' '{"timeout": 600000}' >/dev/null
until=$(jq .until "$DEVLOCK_DIR/SER1.lease")
[ "$(echo "$until - $(date +%s) > 600" | bc)" = 1 ] && ok "lease >= tool timeout" || bad "lease >= tool timeout" "$until"
hook post A 'adb -s SER1 shell sleep 590' >/dev/null
[ "$(jq -r .session "$DEVLOCK_DIR/SER1.lease")" = A ] && ok "post keeps own lease" || bad "post keeps own lease"
reset

# --- expired lease frees the device
hook pre A 'adb -s SER1 shell true' >/dev/null
jq -c '.until = 1' "$DEVLOCK_DIR/SER1.lease" > "$DEVLOCK_DIR/x" && mv "$DEVLOCK_DIR/x" "$DEVLOCK_DIR/SER1.lease"
allow B 'adb -s SER1 shell true'
reset

# --- runs
CLAUDE_CODE_SESSION_ID=A "$DL" run SER1 -- sleep 5 2>/dev/null &
runpid=$!
sleep 0.5
deny  B 'adb -s SER1 shell true'
allow A 'adb -s SER1 shell true'
stop A
"$DL" status | grep -q 'SER1  run: session=A' && ok "status shows run" || bad "status shows run"
t0=$(date +%s)
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 1 SER1 -- true 2>/dev/null
[ $? = 75 ] && ok "run --timeout gives up (75)" || bad "run --timeout gives up (75)"
CLAUDE_CODE_SESSION_ID=A "$DL" run SER1 -- true 2>/dev/null && ok "same session runs in parallel" || bad "same session runs in parallel"
CLAUDE_CODE_SESSION_ID=B "$DL" run SER1 -- true 2>/dev/null
[ $(( $(date +%s) - t0 )) -ge 3 ] && ok "other session's run queues until free" || bad "other session's run queues until free"
wait $runpid
allow B 'adb -s SER1 shell true'
reset

# a run waits for another session's lease
hook pre A 'adb -s SER2 shell true' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 2 SER2 -- true 2>/dev/null
[ $? = 75 ] && ok "run waits for other session's lease" || bad "run waits for other session's lease"
(sleep 1; stop A) &
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 10 SER2 -- true 2>/dev/null && ok "run starts once the lease is released" || bad "run starts once the lease is released"
reset

# kill -9 of devlock: its command still holds the device until it exits
CLAUDE_CODE_SESSION_ID=A "$DL" run SER1 -- sleep 41.17 2>/dev/null &
runpid=$!
sleep 0.5
kill -9 $runpid; wait $runpid 2>/dev/null
deny  B 'adb -s SER1 shell true'
pkill -f 'sleep 41.17$'; sleep 0.2
allow B 'adb -s SER1 shell true'
reset

# a daemon that leaves the run's session does not keep the device
CLAUDE_CODE_SESSION_ID=A "$DL" run SER1 -- "setsid sleep 41.23 </dev/null >/dev/null 2>&1 &" 2>/dev/null
allow B 'adb -s SER1 shell true'
pkill -f 'sleep 41.23$'
reset

# exit code and ANDROID_SERIAL pass through
CLAUDE_CODE_SESSION_ID=A "$DL" run 10.0.0.2:5555 -- 'test "$ANDROID_SERIAL" = 10.0.0.2:5555 && exit 3' 2>/dev/null
[ $? = 3 ] && ok "run passes ANDROID_SERIAL and exit code" || bad "run passes ANDROID_SERIAL and exit code"

# a nickname becomes a name adb knows (the serial when the device is not connected)
CLAUDE_CODE_SESSION_ID=A "$DL" run tvb -- 'test "$ANDROID_SERIAL" = SER2' 2>/dev/null && ok "nickname -> adb name" || bad "nickname -> adb name"
CLAUDE_CODE_SESSION_ID=A "$DL" run tva,SER1 -- 'test -n "$ANDROID_SERIAL"' 2>/dev/null && ok "two names, one device: ANDROID_SERIAL set" || bad "two names, one device: ANDROID_SERIAL set"

# SIGTERM to the run reaches the whole command (grandchildren too) and frees the device
CLAUDE_CODE_SESSION_ID=A "$DL" run SER1 -- 'sleep 41.31; echo done' 2>/dev/null &
runpid=$!
sleep 0.5; kill $runpid; wait $runpid; rc=$?
sleep 0.2
[ $rc = 143 ] && ! pgrep -f 'sleep 41.31$' >/dev/null && ok "SIGTERM reaches grandchildren (rc 143)" || bad "SIGTERM reaches grandchildren" "rc=$rc"
allow B 'adb -s SER1 shell true'
reset

# a backgrounded grandchild keeps the device until it exits
CLAUDE_CODE_SESSION_ID=A "$DL" run SER1 -- 'sleep 2.37 &' 2>/dev/null &
runpid=$!
sleep 0.7
deny  B 'adb -s SER1 shell true'
wait $runpid
allow B 'adb -s SER1 shell true'
reset

# --- review findings
# wrappers with options
hook pre A 'adb -s SER1 shell true' >/dev/null
deny  B 'stdbuf -oL adb -s SER1 logcat'
deny  B 'nice -n 10 adb -s SER1 shell true'
deny  B 'sudo -E adb -s SER1 shell true'
deny  B 'echo x | xargs -I{} adb -s SER1 shell echo {}'
deny  B 'find . -name "*.apk" -exec adb -s SER1 install {} \;'
deny  B 'env -u FOO ANDROID_SERIAL=SER1 ./t.sh'
deny  B "python3 -c 'import os; os.system(\"adb -s SER1 reboot\")'"
deny  B 'scrcpy -s SER1'
deny  B "$(printf 'read -r a <<< "x"\nadb -s SER1 reboot')"
reset
# shell backgrounding
deny  A 'nohup adb -s SER1 logcat > /tmp/l 2>&1 &'
allow A 'adb -s SER1 shell true 2>&1 | tee x'
allow A 'adb -s SER1 shell true &> x'
allow A 'adb -s SER1 shell true && echo ok'
reset
# quoted command substitutions
allow A 'echo "result: $(adb devices)"'
deny  A 'echo "result: $(adb shell getprop)"'
allow A "$DL run SER1 -- \"echo \$(adb -s SER1 shell getprop)\"" '{"run_in_background": true}'
deny  A 'echo `adb shell ls`'
# fastboot options with arguments
allow A 'fastboot --slot a -s SER2 reboot'
reset
# post never shortens a longer lease from a parallel call
hook pre A 'adb -s SER1 shell sleep 590' '{"timeout": 600000}' >/dev/null
hook pre A 'adb -s SER1 shell true' >/dev/null
hook post A 'adb -s SER1 shell true' >/dev/null
[ "$(echo "$(jq .until "$DEVLOCK_DIR/SER1.lease") - $(date +%s) > 600" | bc)" = 1 ] && ok "post keeps the longer lease" || bad "post keeps the longer lease"
reset
# stop keeps leases of commands still running (background subagent), drops them once done
jq -nc '{session_id: "A", tool_use_id: "t1", tool_name: "Bash", tool_input: {command: "adb -s SER1 shell sleep 100"}}' | "$DL" hook pre >/dev/null
stop A
deny  B 'adb -s SER1 shell true'
jq -nc '{session_id: "A", tool_use_id: "t1", tool_name: "Bash", tool_input: {command: "adb -s SER1 shell sleep 100"}}' | "$DL" hook post >/dev/null
stop A
allow B 'adb -s SER1 shell true'
reset
# odd tool_input
allow A 'adb -s SER1 shell true' '{"timeout": "600000"}'
allow B 'adb -s SER2 shell true' '{"timeout": "soon"}'
[ "$(jq -r .session "$DEVLOCK_DIR/SER2.lease")" = B ] && ok "non-numeric timeout still takes a lease" || bad "non-numeric timeout still takes a lease"
reset

# --- sticky window: a lease outlives the turn by DEVLOCK_STICKY_SEC
hook pre A 'adb -s SER1 shell true' >/dev/null
DEVLOCK_STICKY_SEC=120 stop A
deny  B 'adb -s SER1 shell true'
left=$(( $(jq '.until | floor' "$DEVLOCK_DIR/SER1.lease") - $(date +%s) ))
[ $left -le 120 ] && [ $left -ge 100 ] && [ "$(jq .idle "$DEVLOCK_DIR/SER1.lease")" = true ] \
	&& ok "stop keeps the lease ~2 min, marked idle" || bad "stop keeps the lease ~2 min, marked idle" "left=$left"
"$DL" status | grep -q 'SER1  lease: session=A .*idle' && ok "status shows idle lease" || bad "status shows idle lease"
allow A 'adb -s SER1 shell true'
[ "$(jq .idle "$DEVLOCK_DIR/SER1.lease")" = null ] && ok "next command of the holder renews it" || bad "next command of the holder renews it"
end A
allow B 'adb -s SER1 shell true'
reset
# ... but not when another session is waiting for the device
hook pre A 'adb -s SER1 shell true' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 20 SER1 -- true 2>/dev/null &
runpid=$!
sleep 1.5
"$DL" status | grep -q 'SER1  waiting #1: session=B' && ok "status shows the waiting run" || bad "status shows the waiting run"
t0=$(date +%s)
DEVLOCK_STICKY_SEC=120 stop A
wait $runpid; rc=$?
[ $rc = 0 ] && [ $(( $(date +%s) - t0 )) -le 3 ] && ok "a waiting run gets the device when the holder's turn ends" || bad "a waiting run gets the device when the holder's turn ends" "rc=$rc"
[ "$(jq length "$DEVLOCK_DIR/SER1.queue")" = 0 ] && ok "the waiting ticket is removed" || bad "the waiting ticket is removed"
reset
# a run that starts waiting after the turn ended does not wait out the window
hook pre A 'adb -s SER1 shell true' >/dev/null
DEVLOCK_STICKY_SEC=120 stop A
t0=$(date +%s)
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 10 SER1 -- true 2>/dev/null
[ $? = 0 ] && [ $(( $(date +%s) - t0 )) -le 2 ] && ok "a later run takes over an idle lease at once" || bad "a later run takes over an idle lease at once"
allow B 'adb -s SER1 shell true'
reset
# but a plain command of another session does not
hook pre A 'adb -s SER1 shell true' >/dev/null
DEVLOCK_STICKY_SEC=120 stop A
deny  B 'adb -s SER1 shell true'
CLAUDE_CODE_SESSION_ID=B "$DL" hold SER1 2>/dev/null; [ $? = 1 ] && ok "hold does not take over an idle lease" || bad "hold does not take over an idle lease"
reset
# a timed-out waiter leaves the queue
hook pre A 'adb -s SER1 shell true' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 1 SER1 -- true 2>/dev/null
[ "$(jq length "$DEVLOCK_DIR/SER1.queue")" = 0 ] && ok "timed-out waiter leaves the queue" || bad "timed-out waiter leaves the queue"
reset
# end of session frees at once, even with a call still in flight
jq -nc '{session_id: "A", tool_use_id: "t9", tool_name: "Bash", tool_input: {command: "adb -s SER1 shell sleep 100"}}' | "$DL" hook pre >/dev/null
DEVLOCK_STICKY_SEC=120 end A
allow B 'adb -s SER1 shell true'
reset

# --- hold
CLAUDE_CODE_SESSION_ID=A "$DL" hold --ttl 10m --note "cec test" tva >/dev/null && ok "hold" || bad "hold"
o=$(hook pre B 'adb -s SER1 shell true')
[[ "$o" == *"held by session A"*"cec test"* ]] && ok "a hold blocks others and names the note" || bad "a hold blocks others and names the note" "$o"
DEVLOCK_STICKY_SEC=120 stop A
deny  B 'adb -s 10.0.0.2:5555 shell true'
allow A 'adb -s SER1 shell true'
"$DL" status | grep -q "SER1  hold: session=A until .* note='cec test'" && ok "status shows the hold" || bad "status shows the hold"
CLAUDE_CODE_SESSION_ID=B "$DL" hold SER1 2>/dev/null; [ $? = 1 ] && ok "hold on a busy device is refused" || bad "hold on a busy device is refused"
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 1 SER1 -- true 2>/dev/null; [ $? = 75 ] && ok "a run waits for a hold" || bad "a run waits for a hold"
end A
allow B 'adb -s SER1 shell true'
reset
# a hold from a terminal survives session ends, ends on release or expiry
env -u CLAUDE_CODE_SESSION_ID "$DL" hold SER2 >/dev/null
end A; end B
deny  B 'adb -s SER2 shell true'
env -u CLAUDE_CODE_SESSION_ID "$DL" release SER2
allow B 'adb -s SER2 shell true'
reset
CLAUDE_CODE_SESSION_ID=A "$DL" hold --ttl 90s DONGLE >/dev/null
jq -c '.until = 1' "$DEVLOCK_DIR/DONGLE.hold" > "$DEVLOCK_DIR/x" && mv "$DEVLOCK_DIR/x" "$DEVLOCK_DIR/DONGLE.hold"
allow B 'adb -s DONGLE shell true'
reset
CLAUDE_CODE_SESSION_ID=A "$DL" hold --ttl 9h SER1 2>/dev/null && bad "hold over the max is refused" || ok "hold over the max is refused"
CLAUDE_CODE_SESSION_ID=A "$DL" hold --ttl 5x SER1 2>/dev/null && bad "bad --ttl is refused" || ok "bad --ttl is refused"
reset

# --- review fixes
# devlock wait takes nothing, so it does not clear another session's idle lease
hook pre A 'adb -s SER1 shell true' >/dev/null
DEVLOCK_STICKY_SEC=120 stop A
CLAUDE_CODE_SESSION_ID=B "$DL" wait --timeout 2 SER1 2>/dev/null; rc=$?
[ $rc = 75 ] && [ "$(jq -r .session "$DEVLOCK_DIR/SER1.lease")" = A ] && ok "wait keeps out of an idle lease" || bad "wait keeps out of an idle lease" "rc=$rc"
reset
# a multi-device waiter blocked on its other device does not cut the window short
CLAUDE_CODE_SESSION_ID=C "$DL" hold SER2 >/dev/null
hook pre A 'adb -s SER1 shell true' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 20 SER1,SER2 -- true 2>/dev/null & runpid=$!
sleep 1.5
DEVLOCK_STICKY_SEC=120 stop A
[ "$(jq .idle "$DEVLOCK_DIR/SER1.lease")" = true ] && ok "waiter blocked elsewhere: window kept" || bad "waiter blocked elsewhere: window kept"
CLAUDE_CODE_SESSION_ID=D "$DL" hold SER1 2>/dev/null; [ $? = 1 ] && ok "hold refused while a job waits for the device" || bad "hold refused while a job waits for the device"
kill $runpid; wait $runpid 2>/dev/null
end C; reset
# SessionEnd sent to an older `hook stop` registration still ends the session
CLAUDE_CODE_SESSION_ID=A "$DL" hold SER1 >/dev/null
hook pre A 'adb -s SER2 shell true' >/dev/null
jq -nc '{session_id: "A", hook_event_name: "SessionEnd"}' | DEVLOCK_STICKY_SEC=120 "$DL" hook stop
allow B 'adb -s SER1 shell true'
allow B 'adb -s SER2 shell true'
reset
# a command still running at the end of the turn: its post hook ends the turn
jq -nc '{session_id: "A", tool_use_id: "t5", tool_name: "Bash", tool_input: {command: "adb -s SER1 shell sleep 9"}}' | "$DL" hook pre >/dev/null
DEVLOCK_STICKY_SEC=120 stop A
jq -nc '{session_id: "A", tool_use_id: "t5", tool_name: "Bash", tool_input: {command: "adb -s SER1 shell sleep 9"}}' | DEVLOCK_STICKY_SEC=120 "$DL" hook post
left=$(( $(jq '.until | floor' "$DEVLOCK_DIR/SER1.lease") - $(date +%s) ))
[ "$(jq .idle "$DEVLOCK_DIR/SER1.lease")" = true ] && [ $left -le 120 ] && ok "late post after the turn leaves an idle lease" || bad "late post after the turn leaves an idle lease" "$(cat "$DEVLOCK_DIR/SER1.lease")"
reset
jq -nc '{session_id: "A", tool_use_id: "t6", tool_name: "Bash", tool_input: {command: "adb -s SER1 shell sleep 9"}}' | "$DL" hook pre >/dev/null
DEVLOCK_STICKY_SEC=120 stop A
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 20 SER1 -- true 2>/dev/null & runpid=$!
sleep 1.5
t0=$(date +%s)
jq -nc '{session_id: "A", tool_use_id: "t6", tool_name: "Bash", tool_input: {command: "adb -s SER1 shell sleep 9"}}' | DEVLOCK_STICKY_SEC=120 "$DL" hook post
wait $runpid; rc=$?
[ $rc = 0 ] && [ $(( $(date +%s) - t0 )) -le 3 ] && ok "late post hands the device to a waiting run" || bad "late post hands the device to a waiting run" "rc=$rc"
reset
# SIGTERM to a waiting run: it leaves the queue at once and never takes the device
hook pre A 'adb -s SER1 shell true' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DL" run --timeout 30 SER1 -- true 2>/dev/null & runpid=$!
sleep 1.5
t0=$(date +%s); kill -TERM $runpid; wait $runpid; rc=$?
[ $rc = 143 ] && [ $(( $(date +%s) - t0 )) -le 2 ] && [ "$(jq length "$DEVLOCK_DIR/SER1.queue")" = 0 ] && [ "$(jq -r .session "$DEVLOCK_DIR/SER1.lease")" = A ] \
	&& ok "SIGTERM while waiting: exits 143, leaves the queue" || bad "SIGTERM while waiting" "rc=$rc"
CLAUDE_CODE_SESSION_ID=B "$DL" wait --timeout 30 SER1 2>/dev/null & runpid=$!
sleep 1.5; kill -INT $runpid; wait $runpid; rc=$?
[ $rc = 130 ] && ok "SIGINT ends a wait (130)" || bad "SIGINT ends a wait" "rc=$rc"
reset
# argument errors
CLAUDE_CODE_SESSION_ID=A "$DL" hold SER1 --note 2>/dev/null && bad "hold with a dangling --note fails" || ok "hold with a dangling --note fails"
[ ! -e "$DEVLOCK_DIR/--note.hold" ] && ok "no phantom device from a dangling option" || bad "no phantom device from a dangling option"
CLAUDE_CODE_SESSION_ID=A "$DL" run --tiemout 5 SER1 -- true 2>/dev/null && bad "unknown option fails" || ok "unknown option fails"
CLAUDE_CODE_SESSION_ID=A "$DL" run --timeout x SER1 -- true 2>/dev/null && bad "bad --timeout fails" || ok "bad --timeout fails"
reset

# --- release
hook pre A 'adb -s SER1 shell true' >/dev/null
hook pre A 'adb -s SER2 shell true' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DL" release
deny  B 'adb -s SER1 shell true'
CLAUDE_CODE_SESSION_ID=A "$DL" release tva
allow B 'adb -s SER1 shell true'
deny  B 'adb -s SER2 shell true'
reset

# --- concurrency: 2 sessions race for one device 20 times, exactly one wins each time
wins=0
for i in $(seq 20); do
	a=$(hook pre A "adb -s DONGLE shell true" & hook pre B "adb -s DONGLE shell true"; wait)
	[ "$(grep -c deny <<<"$a")" = 1 ] && wins=$((wins + 1))
	reset
done
[ $wins = 20 ] && ok "race: one winner in 20/20" || bad "race: one winner" "$wins/20"

# --- robustness
o=$(echo 'not json' | "$DL" hook pre); [ -z "$o" ] && ok "bad hook input is ignored" || bad "bad hook input is ignored"
o=$(DEVLOCK_CONF=/nonexistent hook pre A 'adb -s X1 shell true'); [[ "$o" != *deny* ]] && ok "works without devices.conf" || bad "works without devices.conf"
printf 'script ([bad\nSERX 10.9.9.9:5555\n' > "$DEVLOCK_DIR/bad.conf"
o=$(DEVLOCK_CONF="$DEVLOCK_DIR/bad.conf" hook pre A 'adb -s 10.9.9.9:5555 shell true'; echo "rc=$?")
[[ "$o" == rc=0 ]] && grep -q "bad script pattern" "$DEVLOCK_DIR/hook.log" && ok "bad conf line is skipped and logged" || bad "bad conf line is skipped and logged" "$o"
stop A
[ ! -s "$DEVLOCK_DIR/hook.log" ] || ! grep -q ERROR "$DEVLOCK_DIR/hook.log" && ok "no hook errors logged" || bad "no hook errors logged" "$(grep ERROR "$DEVLOCK_DIR/hook.log")"

echo "---- $pass passed, $fail failed"
[ $fail = 0 ]
