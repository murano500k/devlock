# devlock

Keeps parallel [Claude Code](https://claude.com/claude-code) sessions on one machine off the same
adb / fastboot / scrcpy test device.

When several sessions test on the same TVs, phones or dongles, one reboots a device in the middle of
another's test. devlock is a set of Claude Code hooks plus a small queueing CLI:

- Every Bash command is parsed before it runs. A command that touches a device must name it
  (`adb -s <serial>`, `ANDROID_SERIAL=<serial>`, `fastboot -s`, `scrcpy -s`); unnamed calls and
  `adb -d/-e/-t` are refused, because devlock cannot tell which device they reach.
- The first command on a device gives the session a short **lease** (5 min, or the Bash timeout + 1
  min). Other sessions are refused while it is held. The lease drops when the session's turn ends.
- Long or background work goes through `devlock run <device>[,<device>] -- <command>`, which queues
  until the devices are free and holds them until the command's whole process group exits.
- `adb kill-server` / `adb disconnect` (all devices) are refused while another session uses any
  device.

It is advisory: it stops honest mistakes by agents that follow its refusals, not a determined user.
The parser is a heuristic over shell syntax; it fails open on its own errors (logged) so a devlock
bug never blocks every Bash call.

## Install

Needs Python 3, bash and jq.

```bash
git clone https://github.com/murano500k/devlock ~/projects/devlock
~/projects/devlock/install.sh --conf ~/path/to/devices.conf
```

`install.sh` links the repo as the `devlock` skill (`~/.claude/skills/devlock`), puts `devlock` on
`~/.local/bin`, links your device list into `~/.local/state/devlock/` and registers the hooks in
`~/.claude/settings.json` (with a backup). Restart Claude Code afterwards.

## devices.conf

One line per device: the serial first, then every other name it goes by. Each line is one lock, so
`adb -s 192.168.0.50:5555` and `adb -s tv1` hold the same device.

```
R58M12345AB 192.168.0.50:5555 192.168.0.50 tv1
emulator-5554 emu
# scripts that pick a default device on their own: refused unless a device is named
script my-ota-tool/run\.py\s+(push|install)
```

## CLI

```
devlock run [--timeout SEC] DEVICE[,DEVICE...] -- COMMAND...
devlock wait [--timeout SEC] DEVICE[,DEVICE...]
devlock status
devlock release [DEVICE]
```

`run` sets `ANDROID_SERIAL` when one device is named, queues for up to 30 min by default (`0` =
forever, exit 75 on timeout). `SKILL.md` is what the agent reads.

State and the decision log live in `$DEVLOCK_DIR` (default `~/.local/state/devlock`, log in
`hook.log`).

## Documentation

- [docs/guide.md](docs/guide.md) - setup, devices.conf, daily use, troubleshooting
- [docs/reference.md](docs/reference.md) - every command, hook rule, setting and file
- [docs/internals.md](docs/internals.md) - how it works, failure modes, known limits

## Tests

- `tests/smoke.sh` - hook and run semantics on fake devices, no adb needed.
- `tests/integration.sh` - two real `claude -p` sessions against the installed hooks.

## License

MIT
