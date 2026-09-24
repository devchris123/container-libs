# Handoff: Podman #29709 — systemd scope startup hangs

## Current task

Issue: https://github.com/podman-container-tools/podman/issues/29709

Continue in a checkout of https://github.com/podman-container-tools/container-libs.
The fix belongs in `common/pkg/systemd` and `common/pkg/cgroups`, not Podman vendor.

The user wants automated tests for three blocking stages before implementing the fix:

1. Connection/authentication in `cgroups.UserConnection`.
2. D-Bus reply in `StartTransientUnitContext`.
3. Completion notification at the subsequent `<-ch>`.

**Immediate scope: inspect existing tests, fixtures, tools, and CI; recommend focused unit tests versus broader integration tests.** No test design has been approved, and no production fix or automated regression tests have been written. Do not jump straight to implementation.

Read the destination repository instructions and policies. Podman's LLM policy links to https://github.com/podman-container-tools/community/blob/main/LLM_POLICY.md: code assistance is allowed with contributor review and testing; upstream communication must be in the contributor's own words.

## Existing checkout and artifacts

Podman checkout: `/home/testchris/issue_29750/podman`.
Vendored common version: `v0.69.2-0.20260908235901-274c303c4db8`.
Built binary: `bin/podman`, version 6.2.0-dev, commit `6b8f0d7b731cc38a1748458e5e2159b0c8879dd8`, Go 1.26.0.

Artifacts:

- `test-podman-systemd-hang.sh`: manual reproducer. Uses this repo's bin/podman, located relative to script. Pauses current user's manager with SIGSTOP, runs Podman info with debug output and GOTRACEBACK=all, sends SIGQUIT after 10 seconds through timeout (kill-after=3s). A separate helper resumes the manager after 20 seconds; EXIT cleanup also resumes it. No sudo required because the user owns the manager. Do not automatically run it during inspection: it disrupts user services.
- `/tmp/podman-systemd-hang.DVWRDm/podman.log`: first experiment.
- `/tmp/podman-systemd-hang.CaajaU/podman.log`: second experiment.
- `findings/info-debug.log`: successful normal info command between experiments.

Host: Ubuntu 24.04, rootless UID 1000, cgroup v2, systemd cgroup manager. Full baseline info is in findings/info-debug.log. Tools confirmed: /usr/bin/dbus-daemon and /usr/local/go/bin/go.

## Issue interpretation

Reporter initially associated a CI hang with this helper but later also discovered a separate Podman shared-memory lock problem involving another installed version. Their wording says the stall was compounded; exact original cause is not established.

A non-login account can have a systemd user manager: reporter enabled lingering. Missing manager causing a prompt connection error differs from an unresponsive manager causing blocked I/O.

A systemd job is an operation such as starting a scope. JobRemoved is a D-Bus notification that the operation left the job list, with result done/failed/canceled/etc. Removing the job does not remove the active scope or kill its processes.

Pausing systemd before starting Podman reproduces a hang but does not prove the final completion receive was reached. Our experiments specifically show earlier blocking stages.

## Confirmed experiments

### First run: connection authentication

Main goroutine stack:

```text
libpod.makeRuntime (libpod/runtime.go:631)
  -> MovePauseProcessToScope
  -> RunUnderSystemdScope (common/pkg/systemd/systemd_linux.go:107)
  -> cgroups.UserConnection (cgroups_linux.go:489)
  -> go-systemd.NewConnection
  -> dbusAuthConnection (cgroups_linux.go:253)
  -> godbus.Conn.Auth (auth.go:68)
  -> authReadLine (auth.go:229)
  -> buffered socket read [IO wait]
```

Blocked at `conn, err = cgroups.UserConnection(unshare.GetRootlessUID())`. Socket established; authentication response missing. StartTransientUnitContext not reached.

This run additionally printed `failed to reexec: Permission denied`. C code prints this after execvp("/proc/self/exe", argv) fails (pkg/rootless/rootless_linux.c has this message at lines 1261 and 1451). Child exits failure. Parent waits for child and receives became=true, nonzero ret, err=nil from waitAndProxySignalsToChild. In libpod/runtime.go:624-637 it attempts MovePauseProcessToScope BEFORE os.Exit(ret), and hangs there. The child failure was therefore not ignored; propagating its exit status was delayed by housekeeping.

The cause of the permission denial is UNKNOWN. Do not infer paused systemd caused it. Baseline info succeeded, and second experiment did not show this error. Existing namespace/runtime state changed between runs.

### Second run: StartTransientUnit reply

```text
persistentPreRunE (cmd/podman/root.go:434)
  -> SetupRootless (pkg/domain/infra/abi/system_linux.go:58)
  -> RunUnderSystemdScope (systemd_linux.go:125)
  -> StartTransientUnitContext / StartTransientUnitAux
  -> startJob (go-systemd/dbus/methods.go:61)
  -> godbus.Object.CallWithContext (object.go:39)
  -> [chan receive]
```

Blocked inside:

```go
_, err = conn.StartTransientUnitContext(context.Background(), unitName, "replace", properties, ch)
```

This is the INTERNAL D-Bus method-reply channel, not the final `<-ch>` in RunUnderSystemdScope. No reexec permission error this time. Confirms hang independent of that error.

### Third stage: not reproduced yet

After a successful method return, RunUnderSystemdScope waits unconditionally on `<-ch>`. Missing matching completion delivery hangs indefinitely. go-systemd handles JobRemoved by synchronously sending result to this channel. Current helper discards result and returns nil even if job failed.

All line numbers above refer to the existing Podman build/vendor snapshot; verify against the new checkout.

## Cancellation approach discussed, not implemented

- Propagate caller cancellation and bound helper with a deadline. Context propagation alone is insufficient if supplied context is Background. Timeout duration and API compatibility remain open.
- Add context-aware UserConnection/dbusAuthConnection path, retaining old API compatibility as appropriate.
- Pass context into connection creation, StartTransientUnitContext, and fallback property queries.
- Replace final receive with select on completion and ctx.Done(). Consider result validation as a separate behavior decision.
- Use a buffered completion channel of capacity 1 so a late result cannot block the synchronous dispatcher after caller returns.
- Audit cleanup on errors (including Hello failure), connection lifetime, and retries. MovePauseProcessToScope currently retries up to ten times, potentially multiplying a per-call timeout.

### Existing library support verified

common's dbusAuthConnection accepts a bus factory with variadic dbus.ConnOption, but calls createBus() without options. It could accept ctx and do:

```go
conn, err := createBus(dbus.WithContext(ctx))
```

The option flows through SessionBusPrivateNoAutoStartup -> Dial -> newConn. godbus newConn applies options, derives a cancellable context, and starts:

```go
go func() {
    <-conn.ctx.Done()
    conn.Close()
}()
```

Connection close interrupts blocked authentication read. No extra goroutine around Auth needed. Keep context alive for entire scope operation; canceling it upon successful UserConnection return would close the returned connection.

IMPORTANT: Dial calls getTransport(address) BEFORE newConn(tr, opts...). WithContext does not by itself make initial transport dialing cancellable. Audit separately before claiming entire connection setup is bounded.

go-systemd's own dbusAuthConnection already takes ctx and uses createBus(dbus.WithContext(ctx)). common's UID-specific helper lacks this. go-systemd.NewConnection invokes factory twice (method and signal connections), then installs AddMatch. Both connections need context.

## Test design candidates to evaluate

Prefer deterministic control over each blocking stage. SIGSTOP before a full Podman invocation cannot isolate stages and depends on namespace, storage, and session state.

Candidate focused integration fixtures:

1. Authentication: local Unix socket server accepts connection but withholds authentication response. Exercise actual cgroups helper and godbus I/O; cancel after server confirms request arrived.
2. Method reply: private dbus-daemon with fake org.freedesktop.systemd1 manager. Receive StartTransientUnit but hold response; cancel after request receipt.
3. Job completion: fake manager returns valid job object path but omits JobRemoved; verify cancellation returns after method reply.
4. Control: fake manager emits successful JobRemoved; helper returns successfully. Account for signal subscription/registration ordering.
5. Optional late completion case to check dispatcher does not become stranded.

Alternative: small injected connection interface/mock for helper logic. Simpler fixture, but mocking UserConnection or StartTransientUnit themselves does not establish real context propagation through D-Bus. Evaluate costs based on actual existing tests before choosing.

Avoid arbitrary sleeps to decide if target stage was reached; use explicit synchronization. Include outer timeout and cleanup so regression fails instead of hanging test suite. Cancellation of connection may return a closed-socket error rather than ctx.Err(); choose normalization/contract before writing assertions.

## Infrastructure inspection completed so far

Podman:
- test/system/550-pause-process.bats: real rootless lifecycle tests manipulating pause processes/namespaces; uses system migrate and includes shared-registry cleanup considerations.
- test/system/helpers.systemd.bash: wrappers around REAL systemctl/systemd-run/journalctl with timeouts, not a fake manager fixture.
- Searches of relevant Podman test paths did not reveal a suitable fake D-Bus manager fixture.

Upstream listings fetched from GitHub main (not pinned dependency revision):
- container-libs common/pkg/systemd: no *_test.go files.
- container-libs common/pkg/cgroups: cgroups_linux_test.go and utils_linux_test.go. Contents NOT inspected yet.
- coreos/go-systemd dbus: dbus_test.go, methods_test.go, and subscription tests. Contents NOT inspected yet.
- godbus/dbus: numerous conn, transport, export, protocol tests. Contents NOT inspected yet.

Dependency tests are normally omitted by Go vendoring, so do not infer upstream test absence from vendor tree alone.

Next step: inspect these actual upstream tests and container-libs Makefiles/CI to recommend focused unit tests, package-level D-Bus integration tests, or a combination. No destination checkout had been created or inspected in this session.

## User preferences and environment

User wants explanations and inspection before implementation, and strongly dislikes approval prompts for reads. Batch permitted reads and proceed autonomously. Previous sandbox could not initialize: bwrap loopback Failed RTM_NEWADDR Operation not permitted. This forced require_escalated even for reads/writes; it is an environment restriction, not repository policy. Do not bypass restrictions.

Do not spawn subagents unless user or applicable instructions explicitly authorize them.

## Temporary artifact verification (2026-09-12)
- Original `/tmp/podman-systemd-hang.DVWRDm/podman.log` exists (37295 bytes). Preserved copy: `/home/testchris/issue_29750/podman/findings/podman-systemd-hang.DVWRDm.log`.
- Original `/tmp/podman-systemd-hang.CaajaU/podman.log` exists (40990 bytes). Preserved copy: `/home/testchris/issue_29750/podman/findings/podman-systemd-hang.CaajaU.log`.

Use the preserved findings copies if /tmp is cleaned. The reusable reproducer is `test-podman-systemd-hang.sh` in the Podman checkout; the temporary directories contain run output and readiness markers, not automated regression tests.
