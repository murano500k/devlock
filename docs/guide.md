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
4. **The lease ends soon after the turn.** When Claude finishes answering, the session's leases
   shrink to 2 minutes, so your next prompt still finds the device. If another session is already
   waiting for the device, they are dropped at once.
5. **Long work goes through `devlock run`.** It waits in line for the devices, then holds them
   until the command and everything it started have exited.

devlock is advisory. It stops honest mistakes by agents that read its refusals. It does not stop a
person, Android Studio, or a script that calls adb without naming the device in the command text.

## Install

Requirements: Linux or macOS, Python 3.9 or newer, bash, and Claude Code, Codex or Cursor.

```bash
git clone https://github.com/murano500k/devlock ~/projects/devlock
~/projects/devlock/install.sh --conf ~/my-lab/devices.conf
```

`install.sh` is safe to run again. It does four things:

- links the repo as the `devlock` skill at `~/.claude/skills/devlock`, so agents can read `SKILL.md`;
- links `devlock` into `~/.local/bin`;
- links your device list to `~/.local/state/devlock/devices.conf`;
- runs `devlock install`, which registers the hooks for every agent set up on the machine, after
  saving a backup of each file it changes:
  - Claude Code: `~/.claude/settings.json` (`$CLAUDE_CONFIG_DIR` if set);
  - Codex: `~/.codex/hooks.json` (`$CODEX_HOME` if set), and the state dir is added to
    `writable_roots` in `config.toml` so `devlock run` works inside Codex's sandbox;
  - Cursor: `~/.cursor/hooks.json`.

  `--claude`, `--codex`, `--cursor` limit it to those agents.

Restart running sessions afterwards; hooks are read when a session starts. Codex runs a new hook
only after you approve it once with `/hooks`.

### Codex and Cursor

The rules are the same for every agent: name the device, run long work through `devlock run`,
never work around a refusal. Differences:

- **Codex** has no background tool, so the only background form refused is a trailing `&`.
  Commands Codex runs see `CODEX_SESSION_ID`, so `devlock run`, `hold`, `release` and `whoami`
  inside Codex belong to the same session as its hooks.
- **Cursor** does not tell the commands it runs which conversation they belong to, so a `devlock
  run` or `hold` from Cursor is a session of its own (`shell-<pid>`). When the conversation starts
  `devlock run` on a device, its own lease on that device is dropped so the run does not wait for
  it; while the run holds the device, the conversation's direct commands on it are refused. Cursor
  does not tell the hook a command's timeout either: a lease lasts at least 11 minutes per command.

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
minute when that is longer. Every later command renews it. When the turn ends, the lease shrinks to
2 minutes (`DEVLOCK_STICKY_SEC`), or is dropped at once if a `devlock run` or `devlock wait` of
another session is waiting for the device. Closing the session drops it at once.

### Keeping a device between turns

To keep a device while you read results, debug by hand, or think about the next step, hold it:

```bash
devlock hold --ttl 1h --note "HDMI-CEC debugging" tv1
devlock release tv1
```

- Default TTL is 30 minutes, the maximum 8 hours. Running `hold` again extends it.
- Other sessions are refused and their runs wait, with your note in the message.
- A hold taken by Claude ends when that Claude session ends. A hold taken in a terminal ends only at
  its TTL or on `devlock release`, run from the same shell.
- `hold` does not wait. If the device is busy it is refused; `devlock wait <device>` first.
- Agents are told to take a hold only when you ask for one.

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
R58M12345AB  waiting #1: session=b210... pid=81502 since=14:05:40 cmd=./perf.sh
192.168.0.60:5555  lease: session=9a7e... until 14:09:40  (this session)
R58N67890CD  hold: session=shell-4410 until 15:30:00 note='HDMI-CEC debugging'
(this session: 9a7e...)
```

`devlock release [DEVICE]` drops your session's leases and holds early. Runs end when their command
does. `devlock status --watch` keeps the list on screen, `devlock whoami` shows only your session.

To see whether a command would be let through right now, without running it or taking anything:

```
$ devlock check 'adb -s 192.168.0.50:5555 reboot'
devices: R58M12345AB
deny: Device busy - R58M12345AB: another session's run holds it (...)
```

`devlock log --denied --since 1h` lists recent refusals with their reasons.

### Keeping devices.conf complete

A name missing from `devices.conf` is a separate lock, so two sessions can reach one device under
two names. `devlock doctor` reads `ro.serialno` from every connected device, groups the names that
belong to the same one and reports gaps; `devlock doctor --fix` writes them into the file. Run it
after you plug in a new device or a device gets a new address.

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
| The same TV is locked twice under two names | Its names are not on one line in `devices.conf`. Run `devlock doctor --fix` while it is connected under both. |
| A device stays busy after a session crashed | A lease ends on its own within 5 minutes (or the Bash timeout plus one minute). A run ends when its processes are gone. A hold ends at its TTL. `devlock status` shows the holder. Do not delete state files while a session may still be using the device. |
| A device stays busy for 2 minutes after the other session finished | That is the sticky window, kept for the other session's next prompt. Queue with `devlock run`: a waiting run ends the window at once. |
| "devlock state is locked by a stuck process" | Another devlock process held the state lock for over 5 seconds. Retry. If it repeats, look for a hung `devlock` process. |
| Hooks seem to do nothing | Restart the session. Check that `~/.claude/settings.json` has `devlock hook pre` under `PreToolUse`, and read `~/.local/state/devlock/hook.log`. |
| A command was wrongly refused or wrongly allowed | `devlock check '<command>'` shows the decision and `devlock log` the recent ones. Please open an issue with the command. |
| Something else looks off | `devlock doctor` checks the state dir, `devices.conf`, the hooks and the connected devices. |
