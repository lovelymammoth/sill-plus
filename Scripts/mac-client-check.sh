#!/bin/bash
# The Mac client end to end, headless, against synthetic hosts on this Mac (docs/mac-client.md,
# "Testing"). Every host listens on 127.0.0.1 alone (SILL_TEST_LOOPBACK), streams the test pattern on
# the software encoder (SILL_TEST_SOFTWARE_ENCODER: the hardware encoder is never touched, so a Sill.app
# streaming to a device meanwhile is not disturbed), never asks the router, and keeps its identity in a
# throwaway folder; the client keeps its key and saved Macs in another (SILL_CLIENT_IDENTITY_DIR), never
# the keychain. Input goes only to these hosts, which post nothing (`in.dry`).
#
#   Scripts/mac-client-check.sh          build, then run every case; exits with the number that failed
#
# Cases:
#   remote      pair with the code at the remote door (loopback counting as a VPN: the Tailscale path),
#               then a pinned session: admitted, the Desktop decoded, input counted by the host
#   saved       the saved Mac again, no pairing: its addresses from the Mac's signed kind 18
#   wrongcode   a well-formed wrong code: refused with the tries left, nothing saved
#   home        pair at the home door (TLS, pairing required) and stream there
#   homesaved   the saved Mac at its home door again
#   otherkey    the saved Mac's address answered by another Mac's key: refused by the pin at once
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product SillHost >/dev/null && swift build -c release --product SillMacClient >/dev/null || { echo "build failed" >&2; exit 1; }
bin="$(swift build -c release --show-bin-path)"
T="$(mktemp -d "${TMPDIR:-/tmp}/sill-mac-client.XXXXXX")"
failed=0
hosts=()
cleanup() { for p in "${hosts[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

host() {   # host NAME [SillHost flags…]: starts a synthetic host, sets HOST_PID, HOME_PORT, REMOTE_PORT, CODE
    local name="$1"; shift
    mkdir -p "$T/$name"; chmod 700 "$T/$name"
    env SILL_TEST_LOOPBACK=1 SILL_TEST_SOFTWARE_ENCODER=1 SILL_TEST_NO_ROUTER=1 SILL_TEST_REMOTE_DIR="$T/$name" \
        ${HOST_ENV:-} "$bin/SillHost" --synthetic --pairing "$@" >"$T/$name.log" 2>&1 &
    HOST_PID=$!; hosts+=("$HOST_PID")
    for _ in $(seq 50); do grep -q "Pair with" "$T/$name.log" && break; sleep 0.1; done
    REMOTE_PORT="$(sed -n 's/^Remote access: listening on port \([0-9]*\).*/\1/p' "$T/$name.log" | head -1)"
    HOME_PORT="$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$HOST_PID" | awk 'NR>1 { n = split($9, a, ":"); print a[n] }' | grep -vx "${REMOTE_PORT:-x}" | head -1)"
    CODE="$(grep -o 'Pair with [0-9 ]*' "$T/$name.log" | tail -1 | tr -dc 0-9)"
}

client() {   # client DIR ARGS…: the headless client with its own key folder; output in $OUT
    mkdir -p "$T/$1"; chmod 700 "$T/$1"
    local dir="$1"; shift
    OUT="$(SILL_CLIENT_IDENTITY_DIR="$T/$dir" "$bin/SillMacClient" --headless "$@" 2>&1)"; STATUS=$?
    echo "$OUT" | sed 's/^/    /'
}

check() {   # check NAME CONDITION…
    local name="$1"; shift
    if "$@"; then echo "PASS $name"; else echo "FAIL $name"; failed=$((failed + 1)); fi
}

wrong_code() {   # a well-formed code (Damm check digit) that is not the host's
    python3 -c "
t=[[0,3,1,7,5,9,8,6,4,2],[7,0,9,2,1,5,4,8,6,3],[4,2,0,6,8,7,1,3,5,9],[1,7,5,0,9,8,3,4,2,6],[6,1,2,3,0,4,5,9,7,8],
[3,6,7,4,2,0,9,5,8,1],[5,8,6,9,7,2,0,1,3,4],[8,9,4,5,3,6,2,0,1,7],[9,4,3,8,6,1,7,2,0,5],[2,5,8,1,4,3,6,7,9,0]]
d=[1,2,3,4,5,6,7,8,9,0,1];i=0
for x in d: i=t[i][x]
print(''.join(map(str,d))+str(i))"
}

echo "== remote door (the Tailscale path), loopback as a VPN"
HOST_ENV="SILL_TEST_ORIGIN=vpn" host a --remote
echo "host a: home $HOME_PORT, remote $REMOTE_PORT"
client ca --address "127.0.0.1:$REMOTE_PORT" --code "$CODE" --seconds 6 --input
check remote bash -c '[ '"$STATUS"' = 0 ] && grep -q "frames decoded" <<<"$0" && grep -q "Remote client connected" '"$T/a.log"' && grep -q "in.dry" '"$T/a.log" "$OUT"
client ca --saved --seconds 3
check saved test "$STATUS" = 0
client cw --address "127.0.0.1:$REMOTE_PORT" --code "$(wrong_code)" --seconds 2
check wrongcode bash -c '[ '"$STATUS"' = 1 ] && grep -q "reason code" <<<"$0" && ! [ -s '"$T/cw/saved-macs.json"' ]' "$OUT"
kill "$HOST_PID" 2>/dev/null; wait "$HOST_PID" 2>/dev/null

echo "== home door"
HOST_ENV="" host b
echo "host b: home $HOME_PORT"
client cb --home --address "127.0.0.1:$HOME_PORT" --code "$CODE" --seconds 5 --input
check home bash -c '[ '"$STATUS"' = 0 ] && grep -q "Client hello" '"$T/b.log"
client cb --home --saved --seconds 3
check homesaved test "$STATUS" = 0
kill "$HOST_PID" 2>/dev/null; wait "$HOST_PID" 2>/dev/null

echo "== another key at the saved Mac's address"
HOST_ENV="" host c
python3 - "$T/cb/saved-macs.json" "$HOME_PORT" <<'EOF'
import json, sys
path, port = sys.argv[1], int(sys.argv[2])
macs = json.load(open(path))
for m in macs:
    m["typedAddresses"] = [dict(a, port=port) for a in m.get("typedAddresses", [])]
json.dump(macs, open(path, "w"))
EOF
client cb --home --saved --seconds 3
check otherkey bash -c '[ '"$STATUS"' = 1 ] && grep -q "pin refused" <<<"$0" && grep -q "another key" <<<"$0" && ! grep -q "Client hello" '"$T/c.log" "$OUT"

echo "logs in $T"
[ "$failed" = 0 ] && echo "All passed." || echo "$failed failed."
exit "$failed"
