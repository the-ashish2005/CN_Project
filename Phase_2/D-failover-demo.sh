#!/usr/bin/env bash
# Extension D - HA Failover demonstration + evidence capture.
set -uo pipefail
EDGE=${EDGE:-10.7.25.158}
r=(--resolve "app.admv.test:443:$EDGE")
hit(){ curl "${r[@]}" -s -D - -o /dev/null https://app.admv.test/api/status | awk 'tolower($1)=="x-backend:"{printf "%s ",$2}'; }
code(){ curl "${r[@]}" -s -o /dev/null -w '%{http_code} ' https://app.admv.test/api/status; }

echo "###############################################################"
echo "# Extension D - HA Failover - evidence  ($(date))"
echo "###############################################################"
echo
echo "=== nginx upstream config (passive health check) ==="
sed -n '/upstream admv_backends/,/^}/p' /opt/homebrew/etc/nginx/servers/admv.conf

echo; echo "=== 1. BASELINE: both up, 8 requests alternate A/B ==="
echo -n "served by:  "; for i in $(seq 1 8); do hit; done; echo
echo; echo "=== 2. STOP Backend A -> service continues via B ==="
docker stop backend-a >/dev/null; sleep 1
echo -n "HTTP codes: "; for i in $(seq 1 8); do code; done; echo
echo -n "served by:  "; for i in $(seq 1 8); do hit; done; echo
echo; echo "=== 3. RESTART Backend A -> LB resumes after fail_timeout (10s) ==="
docker start backend-a >/dev/null
echo "   (waiting 12s for nginx to retry the recovered upstream...)"; sleep 12
echo -n "served by:  "; for i in $(seq 1 8); do hit; done; echo
echo; echo "=== 4. BOTH down -> edge returns 502 (edge up, no upstream) ==="
docker stop backend-a backend-b >/dev/null; sleep 1
echo -n "HTTP codes: "; for i in $(seq 1 3); do code; done; echo
docker start backend-a backend-b >/dev/null; sleep 2
echo "(backends restarted)"
