## Problem

Moving a process into a systemd scope can hang indefinitely if the systemd manager stops responding. Authentication, the `StartTransientUnit` reply, and job completion currently have no timeout.

As investigated in [podman#29709](https://github.com/podman-container-tools/podman/issues/29709), this can block Podman startup during scope placement. A missing manager normally produces a connection error; an unresponsive manager can leave Podman waiting indefinitely. Although uncommon, this is worth handling because a supporting setup operation should not prevent Podman from either proceeding or reporting failure.

## Approach

Let callers bound scope startup with a context covering authentication, D-Bus requests, and job completion:

- Add a context-aware user connection API while retaining the existing API.
- Pass the caller's context through connection authentication, `StartTransientUnit`, and the fallback property query.
- Stop waiting for job completion when the context ends.
- Buffer completion notifications so late delivery cannot block the signal dispatcher.
- Close connections when D-Bus initialization fails.
- Keep the existing API, which uses a background context and has no fixed deadline.

Transport dialing retains godbus's existing behavior; custom TCP D-Bus connection attempts are not bounded by a caller's deadline.

## Testing

Regression tests isolate each blocking stage using a local authentication peer and a private D-Bus daemon with a fake systemd manager. The tests do not require or modify the host's systemd manager.

Cancellation tests cover all three blocking stages, including cancellation after the job reply. A successful-completion test verifies the existing API's normal path. The tests use the system-bus connection path as well.
