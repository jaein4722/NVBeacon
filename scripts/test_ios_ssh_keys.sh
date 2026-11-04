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
    if [[ "$variant" != ed25519 ]]; then
        cp "$fixture/$variant-plain" "$fixture/$variant-pem"
        ssh-keygen -q -p -m PEM -P '' -N '' -f "$fixture/$variant-pem" >/dev/null
        openssl pkcs8 -topk8 -nocrypt -in "$fixture/$variant-pem" -out "$fixture/$variant-pkcs8"
    fi
done
# RFC 8410 encodes an Ed25519 private seed inside a nested OCTET STRING.
python3 - "$fixture" <<'ED25519'
import base64, pathlib, struct, sys
root = pathlib.Path(sys.argv[1])
def field(data):
    size = struct.unpack(">I", data[:4])[0]
    return data[4:4+size], data[4+size:]
blob = base64.b64decode("".join((root/"ed25519-plain").read_text().splitlines()[1:-1]))[15:]
for _ in range(3): _, blob = field(blob)
_, blob = field(blob[4:])
record, _ = field(blob)
_, record = field(record[8:])
_, record = field(record)
secret, _ = field(record)
assert len(secret) == 64
der = bytes.fromhex("302e020100300506032b657004220420") + secret[:32]
(root/"ed25519-pkcs8").write_text("-----BEGIN PRIVATE KEY-----\n"+base64.b64encode(der).decode()+"\n-----END PRIVATE KEY-----\n")
ED25519
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
