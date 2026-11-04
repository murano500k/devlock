---
name: devlock
description: Share adb/fastboot test devices (TVs, tablets, dongles) between Claude Code sessions on this machine. Use before testing on a local device, when a Bash call is refused with "Device busy" / "Name the device", or when the user asks who is using a device, to queue a test, or to release one ("/devlock status", "release the TV").
---

# devlock

A user-level hook (`devlock hook pre|post|stop`, registered by `install.sh`) keeps two sessions off
the same device. Rules for every session:

- **Always name the device**: `adb -s <serial|address>` or `ANDROID_SERIAL=<...>`, `fastboot -s <serial>`,
  `scrcpy -s <...>`.
  adb/fastboot without one, `adb -d/-e/-t`, and `-s $VAR` are refused. Skill scripts that fall back
  to a default device (listed as `script` lines in devices.conf) need `--device <name>`.
- Your first device command gives your session a **lease** (5 min, or the Bash timeout + 1 min if
  longer, refreshed after each command). It is dropped when your turn ends, unless one of your
  commands is still running (e.g. in a background subagent). Drop it earlier when done:
  `devlock release [<device>]`.
- **Long tests, background work and steps that must not be split** (install then test, reboot then
  wait): one job through `devlock run <device>[,<device2>] -- <command>`. It queues while another
  session holds a device (default limit 30 min, `--timeout SEC`, `0` = forever; exit 75 on timeout),
  sets `ANDROID_SERIAL` when one device is named, and holds the devices until the command exits.
  Background Bash, Monitor and trailing-`&` commands that touch a device are refused unless wrapped
  like this. The run holds the devices until its whole process group exits.
  A single quoted command runs through `bash -c`; list every device the job touches.
- `devlock status` shows who holds what. `adb kill-server` / `adb disconnect` (no address) are refused
  while another session uses any device.
- **Never work around a refusal** (other spellings, deleting state files, `adb -d`). Queue with
  `devlock run`, use another device, or ask the user.

`devlock` is `~/.claude/skills/devlock/devlock` (also linked into `~/.local/bin`).

## Setup

1. `./install.sh --conf <your devices.conf>`: links this repo as the skill, puts `devlock` on PATH,
   links the device list into `~/.local/state/devlock/` and registers the hooks.
2. New device or address: add it to that devices.conf - one line per device, serial first, then
   every other name (IP:port, bare IP, nickname). Each line is one lock. `script <regex>` lines name
   scripts that fall back to a default device; they are refused unless one is named.

## Tests

- `tests/smoke.sh` - hook and run semantics on fake devices (no adb, ~1 min).
- `tests/integration.sh` - two real `claude -p` sessions against the installed hooks (fake device).

Decisions are logged to `~/.local/state/devlock/hook.log`. The hook fails open on its own bugs
(logged as ERROR) so a devlock fault never blocks every Bash call.
