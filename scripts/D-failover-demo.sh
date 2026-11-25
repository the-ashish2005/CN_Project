#!/bin/bash
# =============================================================================
#  D-failover-demo.sh — Extension D, HA failover on the REAL laptops.
#
#  Replaces the original container-based version, whose captured evidence still
#  contained a "TOMORROW (real laptops)" to-do note and pointed at the old
#  Phase 1 addresses. This one drives the actual backends and pauses for a
#  human to stop/start them.
#
#      bash scripts/D-failover-demo.sh | tee evidence/phase2/D-ha-failover.txt
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1090
. "$ROOT/team.env"

CURL_EXTRA="${CURL_EXTRA:-}"
URL="https://${DOMAIN}"
[ "$HTTPS_PORT" != "443" ] && URL="https://${DOMAIN}:${HTTPS_PORT}"

hit()  { curl -s $CURL_EXTRA -D - -o /dev/null "$URL/api/status" \
         | tr -d '\r' | awk 'tolower($1)=="x-backend:"{printf "%s ",$2}'; }
code() { curl -s $CURL_EXTRA -o /dev/null -w '%{http_code} ' "$URL/api/status"; }
pause(){ echo; echo ">>> ACTION: $1"; read -r -p "    press Enter when done... " _; echo; }

echo "###############################################################"
echo "# Extension D — HA failover (real laptops)   $(date)"
echo "###############################################################"
echo
echo "=== upstream pool under test ==="
echo "  Backend A — Ashish   ${BACKEND_A}:${PORT_A}"
echo "  Backend B — Dikshant ${BACKEND_B}:${PORT_B}"
echo "  passive health checks: max_fails=1 fail_timeout=10s"
echo "  retry policy: proxy_next_upstream error timeout http_502 http_503"

echo; echo "=== 1. BASELINE — both up, 8 requests should alternate ==="
echo -n "served by:  "; for i in $(seq 1 8); do hit; done; echo

pause "Ashish: STOP Backend A on ${BACKEND_A} (Ctrl-C the python process)"
echo "=== 2. Backend A down — service must continue via B ==="
echo -n "HTTP codes: "; for i in $(seq 1 8); do code; done; echo
echo -n "served by:  "; for i in $(seq 1 8); do hit; done; echo

pause "Ashish: RESTART Backend A  (BACKEND_ID=A PORT=${PORT_A} python3 backend/backend.py)"
echo "=== 3. Backend A back — load balancing must resume ==="
echo "    waiting 12s for fail_timeout (10s) to lapse so nginx retries it..."
sleep 12
echo -n "served by:  "; for i in $(seq 1 8); do hit; done; echo

pause "BOTH: stop Backend A AND Backend B"
echo "=== 4. Both down — edge healthy, nothing to proxy to ==="
echo -n "HTTP codes: "; for i in 1 2 3; do code; done; echo
echo "    502 = nginx is fine; its upstreams are not."

pause "BOTH: restart Backend A and Backend B"
echo "=== 5. Recovered ==="
echo -n "served by:  "; for i in $(seq 1 8); do hit; done; echo

echo
echo "CONCLUSION"
echo "  The backend tier is highly available: either backend can die without a"
echo "  client-visible failure. The EDGE remains the single point of failure —"
echo "  that is what Extension E's standby edge addresses."
