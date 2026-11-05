# devlock

Run several coding agents against the same lab of Android devices without them stepping on each
other.

When two agent sessions (Claude Code, Codex, Cursor) test on the same phones, TVs, set-top boxes or
network-adb dongles, one of them reboots, flashes or reinstalls a device in the middle of the
other's test. devlock gives each session the devices it is using and makes the others wait:

- **Every shell command an agent runs is checked before it runs.** A command that touches a device
  must name it (`adb -s <serial>`, `ANDROID_SERIAL=<serial>`, `fastboot -s`, `scrcpy -s`). Calls that
  let adb pick a device (`adb shell` with several attached, `adb -d`, `-e`, `-t`) are refused, with
  the fix in the message the agent reads.
- **The first command on a device leases it to that session.** Other sessions are refused while the
  lease lasts, and told who has the device and how to queue for it. The lease follows the session's
  turns, so it is gone a couple of minutes after the agent stops.
- **Long or background work queues** with `devlock run <device> -- <command>`, which waits for the
  device and holds it until the whole process tree exits, through reboots, `adb reboot bootloader`
  and fastboot flashing.
- **One device, one lock, whatever its name.** A device reached over USB as `R58M12345AB` and over
  the network as `192.168.0.50:5555` is the same lock. `devlock doctor` finds the names that belong
  together by asking each connected device for its `ro.serialno`.
- **Commands that hit every device** (`adb kill-server`, `adb disconnect`) are refused while another
  session is using any device.

It works on real hardware and emulators alike, on Linux and macOS. It is advisory: it stops honest
mistakes by agents that follow its refusals, not a determined user, and it fails open on its own
errors so a devlock bug never blocks your shell.

## Install

```bash
uv tool install devlock      # or: pipx install devlock
devlock install              # register the hooks for every agent set up on this machine
```

`devlock install` adds devlock's hooks to Claude Code (`~/.claude/settings.json`), Codex
(`~/.codex/hooks.json`) and Cursor (`~/.cursor/hooks.json`), whichever you use, keeping your other
hooks and saving a backup of each file. Pick agents with `--claude`, `--codex`, `--cursor`. Restart
running agent sessions afterwards; in Codex, approve the new hooks once with `/hooks`.

Requires Python 3.9 or newer. From a checkout instead: `git clone
https://github.com/murano500k/devlock && devlock/install.sh`.

## Describe your devices

`~/.local/state/devlock/devices.toml`: each device's serial, then every other name it goes by.

```toml
# scripts that pick a device on their own: refused unless a device is named on the command line
scripts = ['ota-tool/run\.py\s+(push|install)']

[devices]
R58M12345AB = ["192.168.0.50:5555", "192.168.0.50", "pixel"]
"emulator-5554" = ["emu"]
"192.168.0.60:5555" = ["living-room-tv"]
```

Or let devlock write it: connect the devices (USB and network), then `devlock doctor --fix`.
`devlock install --conf PATH` links a file you keep elsewhere, e.g. in a repo shared by several
machines.

## Day to day

Agents mostly see devlock when it refuses something, and the refusal says what to do. You and they
can also use:

```
devlock run [--timeout 30m] DEVICE[,DEVICE...] -- COMMAND   wait for the devices, run, release
devlock hold [--ttl 30m] [--note TEXT] DEVICE               keep a device between turns
devlock release [DEVICE]                                    give your devices back now
devlock status [--watch | --json]                           who holds what, who is waiting
devlock whoami                                              this session and what it holds
devlock check COMMAND                                       would this command be allowed now?
devlock log [--denied] [--since 1h]                         recent decisions
devlock doctor [--fix]                                      check the setup and the device names
```

A refusal looks like this:

```
Device busy - R58M12345AB: another session's run holds it (session=4f1c... since=14:02:11
cmd=./run-ota-test.sh). Do not work around this (other spellings, deleting lock files). Queue with
`devlock run <device> -- <command>` in the background, or use another device.
```

For Claude Code, `devlock install` also adds a `devlock` skill that teaches the agent these rules.
For the others, a line in your agent instructions helps:

```markdown
Test devices are shared between agent sessions through devlock. Always name the device (`adb -s`,
`ANDROID_SERIAL`, `fastboot -s`); run long or background device work through
`devlock run <device> -- <command>`; never work around a "Device busy" refusal.
```

## Documentation

- [Guide](docs/guide.md): setup, workflows, flashing, troubleshooting.
- [Reference](docs/reference.md): every command, option, rule and file.
- [Internals](docs/internals.md): how the parser, leases, runs and queues work, and known limits.

## Development

`tests/smoke.sh` runs the hook and CLI against fake devices (no adb needed); CI runs it on Linux and
macOS. `tests/integration.sh` drives two real Claude Code sessions, and `tests/device.sh` uses a
real device with read-only commands.

## License

MIT
