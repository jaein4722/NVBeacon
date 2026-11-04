#!/bin/bash
# Exercise the mobile transport against a real, loopback-only OpenSSH server.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    rm -rf "$fixture"
}
trap cleanup EXIT
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
for variant in ed25519 rsa 256 384 521; do
    case "$variant" in
        ed25519) options=(-t ed25519) ;;
        rsa) options=(-t rsa -b 3072) ;;
        *) options=(-t ecdsa -b "$variant") ;;
    esac
    ssh-keygen -q "${options[@]}" -a 4 -N fixture-only -f "$fixture/$variant"
    cat "$fixture/$variant.pub" >> "$fixture/authorized_keys"
    cp "$fixture/$variant" "$fixture/$variant-plain"
    ssh-keygen -q -p -P fixture-only -N '' -f "$fixture/$variant-plain" >/dev/null
done
cat > "$fixture/config" <<CONFIG
ListenAddress 127.0.0.1
Port $port
HostKey "$fixture/host"
PidFile "$fixture/sshd.pid"
AuthorizedKeysFile "$fixture/authorized_keys"
PubkeyAcceptedAlgorithms ssh-ed25519,rsa-sha2-256,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers $(id -un)
DisableForwarding yes
ForceCommand printf keys-ok
StrictModes no
CONFIG
/usr/sbin/sshd -D -e -f "$fixture/config" 2>"$fixture/sshd.log" &
server_pid=$!
python3 - "$port" <<'PY'
import socket,sys,time
for _ in range(100):
    try:
        with socket.create_connection(('127.0.0.1',int(sys.argv[1])), timeout=.1): break
    except OSError: time.sleep(.05)
else: sys.exit('Local sshd did not start')
PY
NVBEACON_KEY_FIXTURE="$fixture" NVBEACON_KEY_PORT="$port" \
    swift test --package-path "$repo_dir/Mobile/NVBeaconMobile" --build-system native --jobs 2 \
    --filter importedKeyAuthenticatesToOpenSSH
