#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B && C || D` gate below: B/C are plain grep -q reads that
# cannot fail spuriously here; D (dump + exit) is the intended failure path, not a masked case.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
port=$(( 20000 + RANDOM % 20000 ))
python3 "$here/fake_hindsight_server.py" "$port" & srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/__state" && break; sleep 0.1; done
export HINDSIGHT_URL="http://127.0.0.1:$port" HINDSIGHT_TENANT_API_KEY=tk BOX_IP=198.51.100.9
tmp="$(mktemp -d)"; trap 'kill $srv 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"; cat > "$tmp/bin/nmap" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
PORT     STATE    SERVICE
22/tcp   open     ssh
80/tcp   open     http
443/tcp  open     https
8000/tcp filtered http-alt
6001/tcp filtered X11:1
6002/tcp filtered X11:2
8888/tcp filtered sun-answerbook
9999/tcp filtered abyss
OUT
EOF
chmod +x "$tmp/bin/nmap"; export PATH="$tmp/bin:$PATH"
V="$here/../ops/hindsight/verify.sh"
# before bootstrap: bank checks fail
if bash "$V" >"$tmp/o1" 2>&1; then echo "FAIL: passed before bootstrap"; cat "$tmp/o1"; exit 1; fi
grep -q 'FAIL.*bank' "$tmp/o1" || { echo "FAIL: no bank failure"; cat "$tmp/o1"; exit 1; }
bash "$here/../ops/hindsight/bootstrap_hindsight.sh" --lockdown >/dev/null
bash "$V" >"$tmp/o2" 2>&1 || { echo "FAIL: verify failed after bootstrap"; cat "$tmp/o2"; exit 1; }
grep -q 'PASS.*firewall' "$tmp/o2" && grep -q 'PASS.*401' "$tmp/o2" && grep -q 'PASS.*lockdown' "$tmp/o2" || { cat "$tmp/o2"; exit 1; }
# open dashboard port must fail
cat > "$tmp/bin/nmap" <<'EOF'
#!/usr/bin/env bash
printf '22/tcp open ssh\n80/tcp open http\n443/tcp open https\n8000/tcp open http-alt\n'
EOF
if bash "$V" >"$tmp/o3" 2>&1; then echo "FAIL: 8000 open accepted"; exit 1; fi
echo "PASS test_verify"
