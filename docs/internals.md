# devlock internals

How devlock works and why it is built this way. For behaviour see [reference.md](reference.md).

## Design goals

- **Real devices first.** Devices are not created or destroyed. A lock follows a device's names
  (USB serial, network address, nickname), not its adb state, so it holds through reboots,
  fastboot and short network drops.
- **Enforced at the point of use.** Agents do not have to remember to ask. A command that would
  touch a device another session uses never starts.
- **No daemon, no dependencies.** One Python file using only the standard library, plus small JSON
  files under one lock. Nothing to keep running, nothing to restart after a crash.
- **Never block all work.** A bug in devlock must not stop every Bash call, so the hook fails open
  on its own errors.
- **Short holds by default.** A session holds a device while it works on it, plus a 2-minute
  window after its turn for the user's next prompt. Idle sessions do not keep devices from others,
  and a waiting job ends the window at once. Longer holds are explicit (`devlock hold`).

## Components

```
Claude Code ── PreToolUse ──> devlock hook pre ──> parse command ──> allow / deny + take lease
            ── PostToolUse ─> devlock hook post ─> extend lease, clear in-flight call
            ── Stop ─────────> devlock hook stop ─> shorten leases to 2 min (drop if someone waits)
            ── SessionEnd ───> devlock hook end ──> drop leases and Claude holds
agent Bash ─── devlock run ──> queue ──> register run ──> command in its own process group
```

All of them read and write the same state directory under one `flock`.

## The command parser

The hook gets the command as one string. `split_commands` walks it character by character and cuts
it into simple commands. It:

- splits on unquoted `;`, `&`, `|`, `&&`, `||`, newlines and parentheses;
- opens a nested chunk for every `$( )` and backtick, also inside double quotes, and records which
  command it sits in;
- skips single-quoted text and backslash escapes;
- marks a command ended by a single `&` as background.

Here-document bodies are removed first (`strip_heredocs`). Each chunk is then tokenized with
`shlex`, and `command_start` skips assignments, keywords and wrapper programs with their options to
find the program word. `visit` then handles the program:

- **adb, fastboot, scrcpy** - reads the global options to find the device, the subcommand and
  global operations;
- **bash/sh/zsh with `-c`** - analyzes the inner string recursively;
- **gradle/gradlew** - looks for device tasks;
- **`find -exec`** - analyzes the executed command;
- **scripts and interpreters** - looks for device names in the text.

`ANDROID_SERIAL` is tracked per command: a prefix applies to its own command, an `export` or bare
assignment to the commands after it, and `unset` clears it.

The result (`Use`) holds the devices used, those used in the background, any problems and any
global operation. The hook denies on the first problem. Then it checks for background use and
global operations, and finally whether the devices are busy.

A parser over shell syntax is a heuristic. It is tuned to refuse when unsure about a device
command, and to find device names in commands it cannot look into. `tests/smoke.sh` holds the
cases it must get right.

## Leases

A lease is taken in `pre`, before the command runs, so two sessions cannot both pass the check and
then collide. It is written with:

- `until`: the latest moment it is valid;
- `inflight`: one deadline per running tool call, keyed by `tool_use_id`.

`post` removes the call from `inflight` and extends `until`. `stop` leaves a lease alone while a
deadline in `inflight` is still in the future, which covers a background subagent whose command is
still running when the main turn ends. Otherwise it shortens the lease to the sticky window and
marks it `idle`, or drops it when another session's ticket is in `<device>.queue`. `end` drops the
session's leases outright. A lease that nobody refreshes simply expires, so a crashed session frees
its devices within one lease period.

## Holds

A hold is a lease with an explicit end time and no renewal: `devlock hold` writes `<device>.hold`
after checking, under the lock, that no other session has the device. The hook and the CLI treat it
like any other holder. Its `kind` records whether it was taken inside Claude Code; `end` drops only
those, so a hold taken by hand in a terminal is not lost when some Claude session closes.

## Waiting tickets

`devlock run` and `devlock wait` add a ticket to `<device>.queue` when they first find a device
busy, and remove it when they get the devices, give up or exit. A ticket is alive by the same pid
and start time check as a run, so a killed waiter disappears without cleanup. Tickets only tell a
holder that someone is waiting; who gets the device next is still decided by polling.

## Runs

`devlock run` registers an entry in `<device>.runs` for every device. The entry records:

- the pid and start time of the `devlock run` process (from `/proc/<pid>/stat`), so a reused pid
  does not look alive;
- the process group of the command (the command is started with `start_new_session`).

The entry is alive while either of them is. So `kill -9` on `devlock run` keeps the devices held
until the command's processes are gone, and a background helper the command left behind keeps
them too. Dead entries are filtered out on every read. Nothing has to clean them up.

Waiting is polling: once a second, `acquire` takes the state lock, checks for other holders, and
registers the run as soon as there are none.

## Locking and atomicity

- Every read-check-write of state happens under `flock` on `.mutex`. The hook waits up to 5 s for
  it and then denies with "retry". The CLI waits up to 30 s.
- Files are written to a temp file and renamed into place, so a reader never sees half a file.
- State is per user. Sessions of different users on one machine do not see each other.

## Failure modes

| What fails | What happens |
|---|---|
| exception in the hook | logged as `ERROR`, the call is allowed |
| hook input not JSON, or no session id | allowed |
| state lock not obtained within 5 s | the call is denied with "retry" |
| `devices.conf` missing or a broken link | warning in the log; every name is its own device |
| invalid `script` regex | that line is skipped, with a warning |
| session crashes | its leases expire; its runs end when their processes are gone |
| machine reboots | leases expire; runs are dead because their pids are gone |

## Known limits

- **Linux only.** Process start times come from `/proc`. On macOS a run would be seen as alive only
  through its process group.
- **Claude Code only.** The hook speaks Claude Code's hook protocol, and session identity comes
  from `CLAUDE_CODE_SESSION_ID`.
- **One machine.** State is local files.
- **Advisory.** Commands outside Claude Code, and scripts that call adb without naming the device
  in the command text, are not seen.
- **Waiting is not fair.** Waiting jobs poll; whoever checks first after the device frees up gets
  it. A session making back-to-back foreground calls keeps renewing its lease, and a queued
  `devlock run` can wait until its timeout.

## Tests

- `tests/smoke.sh` - drives `devlock hook pre|post|stop` with synthetic hook JSON from two fake
  sessions, plus `devlock run` with real processes. Needs no adb or devices. Covers the parser
  cases, leases, in-flight calls, runs surviving `kill -9`, process-group holding, signal
  forwarding, queue timeouts and a 20-way race. About a minute.
- `tests/integration.sh` - two real `claude -p` sessions against the installed hooks and a fake
  device, to check the hook wiring end to end.

Every change to the parser should come with `allow` or `deny` lines in `smoke.sh`.
