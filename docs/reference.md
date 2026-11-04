# devlock reference

Exact behaviour of the current version. For setup and workflow see [guide.md](guide.md).

## Commands

### `devlock run [--timeout SEC] DEVICE[,DEVICE...] -- COMMAND...`

Waits until no other session holds any of the devices, then runs `COMMAND` while holding all of
them.

- `DEVICE` is any name from `devices.conf`, or any adb or fastboot serial. Names can be given as
  one comma-separated argument or as several arguments before `--`.
- A single `COMMAND` argument runs through `bash -c`. Several arguments run as an argv, without a
  shell.
- `--timeout SEC`: how long to wait in line. Default 1800. `0` waits forever.
- While waiting, polls once a second and prints `[devlock] busy: ...; queued` once to stderr.
- When it gets the devices, prints `[devlock] holding ...` to stderr.
- Environment of `COMMAND`:
  - `DEVLOCK_HELD` - the held devices, comma-separated, by canonical name.
  - `ANDROID_SERIAL` - only when one device is named: the first of its names that `adb devices`
    lists now. If none is listed (offline, or in fastboot), the name you gave or the canonical name.
- The command runs in its own process group. SIGINT, SIGTERM and SIGHUP sent to `devlock run` are
  forwarded to that group.
- The devices stay held until the whole process group has exited, even after the main process ends.

Exit status:

| Status | Meaning |
|---|---|
| status of `COMMAND` | the command ran |
| 128 + N | the command was killed by signal N, or `devlock run` got signal N while still waiting |
| 75 | gave up waiting (`--timeout`) |
| 127 | the command could not be started |

### `devlock wait [--timeout SEC] DEVICE[,DEVICE...]`

Blocks until no other session holds any of the devices, then exits 0. It does not take the
devices. Default timeout is 0 (forever). Exit 75 on timeout.

While it waits, `run` and `wait` leave a ticket in `<device>.queue`. A ticket tells the holder's
end of turn to drop its lease at once instead of keeping the sticky window.

### `devlock hold [--ttl DURATION] [--note TEXT] DEVICE[,DEVICE...]`

Keeps the devices for the calling session until the TTL ends.

- `--ttl`: a number with an optional unit `s`, `m` or `h`. Default 30m, maximum
  `DEVLOCK_HOLD_MAX` (8h).
- `--note`: shown to other sessions in refusals and in `status`.
- Running it again on a held device replaces the hold, so it extends it.
- Exits 1, without waiting, when another session has any of the devices.
- A hold taken with `CLAUDE_CODE_SESSION_ID` set ends at that session's SessionEnd. A hold taken
  without it (a terminal) ends only at its TTL or on `release` from the same shell.

### `devlock status`

Lists every live run, hold, lease and waiting job, one line each, and marks those of the calling
session. A lease kept after its session's turn ended is marked `(idle after its turn)`. Prints
`all devices free` when there is nothing, then the calling session's id.

### `devlock release [DEVICE]`

Drops the calling session's leases and holds: on one device, or on all of them without `DEVICE`.
Runs are not affected; they end when their command does.

### `devlock hook pre|post|stop|end`

Entry points for Claude Code. They read the hook's JSON from stdin. Not meant to be run by hand.

## Session identity

A session is identified by `CLAUDE_CODE_SESSION_ID`. Outside Claude Code (a plain terminal) it is
`shell-<parent pid>`, so commands from one shell count as one session.

The hooks get the session id from the hook input. `devlock run`, `wait`, `status` and `release`
read it from the environment, which Claude Code sets for the commands it runs.

## Holders

A device is busy for session S when another session has either of these:

- **Lease** - taken by the `pre` hook on the first command that uses the device.
  - Lasts `DEVLOCK_LEASE_SEC` (default 300) or the Bash call's timeout plus 60 s, whichever is
    longer (Bash default timeout 120 s).
  - `post` extends it to at least `now + DEVLOCK_LEASE_SEC` after each command.
  - `stop` (end of turn) shortens it to at most `DEVLOCK_STICKY_SEC` (120 s) from now and marks
    it idle. It drops it at once when another session has a `run` or `wait` waiting for the device.
    A lease with a command still running (for example in a background subagent) is left as it is.
  - `end` (end of session) drops it at once.
- **Hold** - taken by `devlock hold`. Lasts until its TTL.
- **Run** - registered by `devlock run`. Alive while the `devlock run` process (matched by pid and
  start time) or any process in its command's process group is alive.

A session never blocks itself: its own leases and runs do not make a device busy for it.

## Hook rules

The `pre` hook is registered for the `Bash` and `Monitor` tools. It parses the command and decides
on the first problem found. An allowed command takes or extends the session's lease on every
device it uses.

### Device commands

| Tool | Needs a device | Free (no device needed) |
|---|---|---|
| `adb` | every subcommand not in the free list | `devices`, `version`, `help`, `start-server`, `connect`, `keygen`, `mdns`, `pair`, `host-features`, `--version`, `--help`; `adb` with no subcommand |
| `fastboot` | every subcommand not in the free list | `devices`, `help`, `--version`, `--help` |
| `scrcpy` | always | `-v`, `--version`, `-h`, `--help` |
| `gradle`, `gradlew` | tasks matching `connected*`, `install*`, `uninstall*`, `deviceCheck` (any project path; not `*Dist`) | every other task; `-x <task>` is skipped |

### How a device is named

| Form | Applies to |
|---|---|
| `adb -s X`, `adb -sX`, `adb --serial X`, `adb --serial=X` | that command |
| `fastboot -s X`, `fastboot --serial X` | that command |
| `scrcpy -s X`, `scrcpy -sX`, `scrcpy --serial[=]X`, `scrcpy --tcpip=[+]host:port` | that command |
| `ANDROID_SERIAL=X cmd`, `env ANDROID_SERIAL=X cmd` | that command only |
| `export ANDROID_SERIAL=X`, `declare`/`readonly ... ANDROID_SERIAL=X`, bare `ANDROID_SERIAL=X;` | the commands after it on the same line |
| `unset ANDROID_SERIAL` | clears it for the commands after it |
| inside `devlock run DEV -- ...` with one device | `ANDROID_SERIAL` is set by the run |

Gradle device tasks take the device only from `ANDROID_SERIAL`. A comma-separated value names
several devices.

### Refusals

| Refused | Message starts with | Fix |
|---|---|---|
| device command without a device | `Name the device` | add `-s <serial>` or `ANDROID_SERIAL=` |
| `adb -d`, `-e`, `-t`, `--transport-id`, `--select-usb`, `--select-tcpip`; `scrcpy -d`, `-e`, `--select-usb`, `--select-tcpip` | `... picks a device that devlock cannot see` | use `-s <serial>` |
| `-s $VAR`, any value with `$`, backtick, `*` or `?` | `devlock needs the device spelled out` | write the name out, or use `devlock run` |
| `ANDROID_SERIAL=$X` (any non-literal value) | `ANDROID_SERIAL must be a literal serial` | same |
| Gradle device task without `ANDROID_SERIAL` | `... runs on every connected device` | `ANDROID_SERIAL=<serial> ./gradlew ...` |
| a `script` pattern from `devices.conf` with no device named in the command | `This script picks a test device on its own` | pass `--device <name>` (any device name in the command counts) |
| device held by another session | `Device busy - ...` with the holder | `devlock run` in the background, another device, or ask the user |
| `adb kill-server`, `adb disconnect` with no address, `adb reconnect` with no device, while another session holds any device | ``... would cut off other sessions' devices`` | wait until the others are done |
| device command in background Bash (`run_in_background`), in `Monitor`, or ended by a single `&` | `Background work on a shared device` | wrap it: `devlock run <devs> -- <command>` |
| `devlock run A -- ...` whose command uses device B | `The run also uses B` | list every device: `devlock run A,B -- ...` |
| a multi-device run with a command that does not name its device | `A run over several devices sets no ANDROID_SERIAL` | name the device in every call inside it |
| `adb kill-server` and the like inside `devlock run` | `... affects every device; do not run it inside a run` | run it outside, when no one else uses a device |
| state lock not obtained within 5 s | `devlock: devlock state is locked by a stuck process` | retry |

`adb disconnect <address>` is treated as a command on that device, not as a global one.

### What the parser looks into

- Command separators `;`, `&&`, `||`, `|`, `&`, newlines, `( )` subshells.
- `$( )` and backtick substitutions, also inside double quotes. Single-quoted text is data.
- Here-document bodies are skipped as data; here-strings (`<<<`) are not mistaken for them.
- `bash`, `sh`, `zsh` with `-c` alone or in a flag cluster (`-lc`, `-ec`, `-o pipefail -xc`), up
  to 4 levels deep.
- Wrappers and their options: `sudo`, `env`, `nice`, `ionice`, `stdbuf`, `nohup`, `setsid`,
  `command`, `builtin`, `exec`, `timeout`, `watch`, `xargs`, `chrt`, `taskset`, `unbuffer`, `script`.
- Shell keywords (`if`, `then`, `do`, `while`, `{`, `time`, `!` ...) and `find -exec/-execdir/-ok`.
- The inner command of `devlock run ... -- <command>`.

Scripts and interpreters (`*.sh`, `*.py`, any path with `/`, `python`, `python3`, `node`, `uv`,
`perl`, `ruby`, `bash script.sh`, `gradlew`, `make`, `pytest`) cannot be looked into. For those,
devlock locks every device from `devices.conf` whose name appears in the command, plus the device
in `ANDROID_SERIAL`. Names count only as whole words.

Not covered: `eval`, `source`/`.`, shell functions and aliases, devices named through variables
that are set elsewhere, and scripts that call adb without the device appearing in the command.

## devices.conf

Location: `$DEVLOCK_CONF`, default `$DEVLOCK_DIR/devices.conf` (`install.sh --conf` links it there).

- `#` starts a comment, on its own line or after the names.
- **Device line:** whitespace-separated names. The first is the canonical name: it names the lock,
  the state files and the entries in `status`. Every name on the line refers to the same lock.
  Names are matched exactly (case-sensitive).
- **Script line:** `script <python regex>`. A command that matches the regex and names no device is
  refused.
- A name that is on no line is its own device.
- A broken line or an invalid regex is skipped and logged. A missing file means no aliases.

## Environment

| Variable | Default | Used for |
|---|---|---|
| `DEVLOCK_DIR` | `~/.local/state/devlock` | state, log, default config location |
| `DEVLOCK_CONF` | `$DEVLOCK_DIR/devices.conf` | device list |
| `DEVLOCK_LEASE_SEC` | `300` | lease length after each command |
| `DEVLOCK_STICKY_SEC` | `120` | how long a lease outlives its turn; `0` drops it at the end of the turn |
| `DEVLOCK_HOLD_MAX` | `28800` | longest `devlock hold --ttl`, in seconds |
| `CLAUDE_CODE_SESSION_ID` | set by Claude Code | session identity |
| `DEVLOCK_HELD` | set by `devlock run` | devices the run holds |
| `ANDROID_SERIAL` | set by `devlock run` (one device) | device for adb, Gradle and scrcpy |

## Hooks registered by install.sh

| Event | Matcher | Command |
|---|---|---|
| `PreToolUse` | `Bash\|Monitor` | `devlock hook pre` |
| `PostToolUse` | `Bash` | `devlock hook post` |
| `PostToolUseFailure` | `Bash` | `devlock hook post` |
| `Stop` | all | `devlock hook stop` |
| `SessionEnd` | all | `devlock hook end` |

Each has a 10 s timeout. Re-running `install.sh` replaces older devlock entries and leaves other
hooks alone.

## Files

All in `$DEVLOCK_DIR`:

| File | Contents |
|---|---|
| `<device>.lease` | the current lease: `{"session", "until", "inflight": {tool_use_id: deadline}}`, or `null` |
| `<device>.runs` | list of runs: session, pid, process start time, process group, start time, command |
| `<device>.hold` | the current hold: `{"session", "kind": "claude"\|"shell", "until", "note", "since"}`, or `null` |
| `<device>.queue` | waiting `run`/`wait` processes, same fields as a run without the process group |
| `.mutex` | lock file for every state change |
| `hook.log`, `hook.log.1` | every allow, deny and error, with the command; rotated at 1 MB |
| `devices.conf` | link to your device list |

`<device>` is the canonical name, with characters other than letters, digits, `.`, `_`, `:` and `-`
replaced by `_`.
