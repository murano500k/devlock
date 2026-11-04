# devlock guide

devlock keeps parallel Claude Code sessions on one machine off the same Android test device. It is
built for real hardware that sessions cannot create or throw away: TVs, set-top boxes, phones and
network-adb dongles, including devices that reboot into fastboot during a flash.

This guide covers setup and day-to-day use. Exact rules, commands and file formats are in
[reference.md](reference.md); how it works inside is in [internals.md](internals.md).

## The problem

Two sessions testing on the same TV do not see each other. One installs its build while the other
is halfway through a test, reboots the device under it, or runs `adb kill-server` and cuts every
session's connection. The failures look like flaky tests, not like a collision.

## How devlock stops it

devlock is a set of Claude Code hooks plus a small CLI.

1. **Every Bash command is checked before it runs.** The `PreToolUse` hook parses the command line
   and finds every adb, fastboot, scrcpy and Gradle device task in it, including those inside
   pipes, `&&` chains, `$( )`, backticks, `bash -c` and `find -exec`.
2. **Device commands must name their device.** `adb -s <serial>`, `ANDROID_SERIAL=<serial>`,
   `fastboot -s <serial>`, `scrcpy -s <serial>`. A command that leaves adb to pick a device is
   refused, because devlock cannot tell which device it would reach.
3. **The first command on a device gives the session a lease.** While the lease is held, other
   sessions' commands on that device are refused with the holder's details.
4. **The lease ends with the turn.** When Claude finishes answering, the session's leases are
   dropped, so the next session can start at once.
5. **Long work goes through `devlock run`.** It waits in line for the devices, then holds them
   until the command and everything it started have exited.

devlock is advisory. It stops honest mistakes by agents that read its refusals. It does not stop a
person, Android Studio, or a script that calls adb without naming the device in the command text.

## Install

Requirements: Linux, Python 3.8 or newer, bash, jq, and Claude Code.

```bash
git clone https://github.com/murano500k/devlock ~/projects/devlock
~/projects/devlock/install.sh --conf ~/my-lab/devices.conf
```

`install.sh` is safe to run again. It does four things:

- links the repo as the `devlock` skill at `~/.claude/skills/devlock`, so agents can read `SKILL.md`;
- links `devlock` into `~/.local/bin`;
- links your device list to `~/.local/state/devlock/devices.conf`;
- registers the hooks in `~/.claude/settings.json`, after saving a backup next to it.

Restart running Claude Code sessions afterwards. Hooks are read when a session starts.

## Describe your devices

A device that is reachable under more than one name needs a line in `devices.conf`. Otherwise
`adb -s 192.168.0.50:5555` and `adb -s R58M12345AB` count as two devices, even when they are
the same TV over ethernet and USB.

```
# serial first, then every other name: adb address, bare IP, nickname
R58M12345AB  192.168.0.50:5555  192.168.0.50  tv1
192.168.0.60:5555  192.168.0.60  dongle1
```

Each line is one lock. Use the USB serial first where the device has one. A network-only device
uses its address. Nicknames work in every devlock command and in the hook, but adb does not know
them, so use them with `devlock run` (which turns them into a real adb name) rather than with
`adb -s`.

Some scripts pick a default device when none is given. List them as `script` lines and devlock
refuses to run them unless the command names a device:

```
script install-local-ota/scripts/run\.py\s+(push|install|reboot-verify)
```

See [reference.md](reference.md#devicesconf) for the full format.

## Day-to-day use

### Short commands

Name the device and run the command. Nothing else is needed.

```bash
adb -s R58M12345AB shell getprop ro.build.fingerprint
adb -s 192.168.0.50:5555 shell dumpsys power | grep mWakefulness
ANDROID_SERIAL=R58M12345AB ./gradlew connectedDebugAndroidTest
```

The first command gives the session a lease for 5 minutes, or for the Bash timeout plus one
minute when that is longer. Every later command renews it. The lease is dropped when the turn ends.

### Long or background work

Anything that runs in the background, takes long, or must not be split between turns goes through
`devlock run`:

```bash
devlock run tv1 -- ./run-ota-test.sh
devlock run tv1,dongle1 -- 'adb -s 192.168.0.60:5555 shell input keyevent HOME && sleep 5 && adb -s R58M12345AB shell screencap -p /sdcard/a.png'
devlock run --timeout 0 tv2 -- python3 flash_and_verify.py --device R58N67890CD
```

`devlock run`:

- waits while another session holds any of the devices, printing `[devlock] busy: ...; queued`
  once. It gives up after 30 minutes by default (`--timeout SEC`, `0` waits forever) with exit
  code 75;
- sets `ANDROID_SERIAL` when exactly one device is named, choosing the name adb currently lists
  for it;
- holds the devices until the command's whole process group has exited, so a background helper the
  command left behind still counts;
- forwards Ctrl-C and `kill` to the command.

In Claude Code, start it with the Bash tool's `run_in_background`. The session is woken when it
exits. A background Bash call, a `Monitor` call or a trailing `&` that touches a device without
`devlock run` is refused.

Flashing works the same way. A lease belongs to the device's names, not to its adb state, so the
run keeps the device while it sits in fastboot or reboots:

```bash
devlock run R58M12345AB -- 'adb -s R58M12345AB reboot bootloader && fastboot -s R58M12345AB flash boot boot.img && fastboot -s R58M12345AB reboot'
```

### Seeing who has what

```
$ devlock status
R58M12345AB  run: session=4f1c... pid=81234 since=14:02:11 cmd=./run-ota-test.sh
192.168.0.60:5555  lease: session=9a7e... until 14:09:40  (this session)
(this session: 9a7e...)
```

`devlock release [DEVICE]` drops your session's leases early. Runs end when their command does.

## What a refusal looks like

A refused command never runs. Claude sees the reason and is expected to follow it:

```
Device busy - R58M12345AB: another session's run holds it (session=4f1c... pid=81234
since=14:02:11 cmd=./run-ota-test.sh). Do not work around this (other spellings, deleting lock
files). Queue with `devlock run <device> -- <command>` in the background, or use another device.
```

The usual responses are: wait in line with `devlock run`, pick another device, or ask the user.
[reference.md](reference.md#hook-rules) lists every refusal and its fix.

## Telling agents about it

`SKILL.md` is written for the agent and is installed as the `devlock` skill. Claude loads it when a
command is refused or the user asks about devices. To make agents follow the rules from the first
command, add a line to your global `CLAUDE.md`:

```markdown
Test devices are shared between sessions through devlock (see the devlock skill). Always name the
device (`adb -s`, `ANDROID_SERIAL`, `fastboot -s`); run long or background device work through
`devlock run <device> -- <command>`; never work around a "Device busy" refusal.
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Every device command is refused with "Name the device" | The command lets adb choose. Add `-s <serial>` or `ANDROID_SERIAL=<serial>`. |
| "devlock needs the device spelled out, not a variable" | `adb -s $DEV` cannot be checked before it runs. Write the serial out, or wrap the work in `devlock run <dev> -- ...` and use `$ANDROID_SERIAL` inside it. |
| The same TV is locked twice under two names | Its names are not on one line in `devices.conf`. Add the missing address. |
| A device stays busy after a session crashed | A lease ends on its own within 5 minutes (or the Bash timeout plus one minute). A run ends when its processes are gone. `devlock status` shows the holder. Do not delete state files while a session may still be using the device. |
| "devlock state is locked by a stuck process" | Another devlock process held the state lock for over 5 seconds. Retry. If it repeats, look for a hung `devlock` process. |
| Hooks seem to do nothing | Restart the session. Check that `~/.claude/settings.json` has `devlock hook pre` under `PreToolUse`, and read `~/.local/state/devlock/hook.log`. |
| A command was wrongly refused or wrongly allowed | `hook.log` records every decision with the full command. Please open an issue with the line. |
