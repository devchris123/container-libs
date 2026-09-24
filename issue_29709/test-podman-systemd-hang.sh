#!/usr/bin/env bash
set -euo pipefail

if (( EUID == 0 )); then
    echo "Run this as your normal user, not root." >&2
    exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
podman_binary="$script_dir/bin/podman"
if [[ ! -x "$podman_binary" ]]; then
    echo "Repository build not found or not executable: $podman_binary" >&2
    exit 1
fi

for cmd in systemctl timeout; do
    command -v "$cmd" >/dev/null || {
        echo "Missing command: $cmd" >&2
        exit 1
    }
done

manager_pid=$(systemctl show "user@$(id -u).service" \
    --property=MainPID --value)

if [[ ! "$manager_pid" =~ ^[0-9]+$ ]] || (( manager_pid <= 1 )); then
    echo "No running systemd user manager found." >&2
    exit 1
fi

output_dir=$(mktemp -d /tmp/podman-systemd-hang.XXXXXX)
helper_pid=""

cleanup() {
    # Immediate recovery; the helper also resumes it independently.
    kill -CONT "$manager_pid" 2>/dev/null || true
    if [[ -n "$helper_pid" ]]; then
        wait "$helper_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Logs: $output_dir"
echo "Podman binary: $podman_binary"
echo "Pausing user manager PID $manager_pid for 20 seconds."

# This helper owns both the pause and the timed recovery.
bash -e -c '
    manager_pid=$1
    ready_file=$2
    trap '\''kill -CONT "$manager_pid" 2>/dev/null || true'\'' EXIT
    trap "exit 0" HUP INT TERM

    kill -STOP "$manager_pid"
    touch "$ready_file"
    sleep 20 &
    wait "$!"
' bash "$manager_pid" "$output_dir/ready" &
helper_pid=$!

# Wait until the manager has actually been paused.
while [[ ! -e "$output_dir/ready" ]]; do
    if ! kill -0 "$helper_pid" 2>/dev/null; then
        echo "Failed to pause the manager." >&2
        exit 1
    fi
    sleep 0.1
done

status=0
timeout --signal=QUIT --kill-after=3s 10s \
    env GOTRACEBACK=all "$podman_binary" --log-level=debug info \
    >"$output_dir/podman.log" 2>&1 || status=$?

echo "Podman/timeout exit status: $status"
echo "Waiting for the helper to resume the manager..."
wait "$helper_pid"
helper_pid=""

echo "User manager resumed."
echo "Inspect: $output_dir/podman.log"