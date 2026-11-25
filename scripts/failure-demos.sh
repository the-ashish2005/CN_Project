#!/bin/bash
# =============================================================================
#  failure-demos.sh — Team admv
#
#  Runs the five REQUIRED Phase 1 failure demonstrations (brief section 6.3)
#  and writes the output to evidence/phase1/failures/.
#
#  Guided, not fully automatic: three of the five need a service stopped on
#  another laptop, so the script pauses and tells you exactly what to do and
#  who has to do it. Press Enter when the step is done.
#
#      bash scripts/failure-demos.sh
#
#  The point of each scenario is NOT that something breaks — it is that it
#  breaks at ONE identifiable layer while the layers below keep working.
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1090
. "$ROOT/team.env"

OUTDIR="$ROOT/evidence/phase1/failures"
mkdir -p "$OUTDIR"
CURL_EXTRA="${CURL_EXTRA:-}"
URL="https://${DOMAIN}"
[ "$HTTPS_PORT" != "443" ] && URL="https://${DOMAIN}:${HTTPS_PORT}"

BOLD=$'\033[1m'; YEL=$'\033[33m'; RESET=$'\033[0m'
pause() { echo; echo "${YEL}${BOLD}ACTION: $1${RESET}"; read -r -p "   press Enter when done... " _; echo; }
hdr()   { printf '%s\n# %s\n# %s\n%s\n\n' "$(printf '=%.0s' {1..70})" "$1" "$(date)" "$(printf '=%.0s' {1..70})"; }

echo "${BOLD}Phase 1 failure demonstrations${RESET}"
echo "Output -> $OUTDIR"

# ---------------------------------------------------------------------------
# 1. WRONG DNS SERVER ON THE CLIENT
#    Expect: name lookup fails, but raw IP connectivity is untouched.
# ---------------------------------------------------------------------------
OUT="$OUTDIR/1-wrong-dns-server.txt"
{
  hdr "FAILURE 1 — client points at a DNS server that does not exist"
  echo "Simulated by querying 192.0.2.1 (RFC 5737 'TEST-NET-1', guaranteed dead)."
  echo
  echo "--- name lookup against the bad resolver ---"
  dig @192.0.2.1 "$DOMAIN" +time=2 +tries=1 2>&1 | tail -6
  echo
  echo "--- but the edge is still perfectly reachable by IP ---"
  ping -c 2 -t 2 "$EDGE" 2>&1 | tail -3
  echo
  echo "--- and it still serves, if we skip DNS and supply the IP ourselves ---"
  curl -s $CURL_EXTRA --resolve "${DOMAIN}:${HTTPS_PORT}:${EDGE}" \
       -o /dev/null -w 'HTTP %{http_code}\n' "$URL/api/status"
  echo
  echo "WHAT THIS SHOWS"
  echo "  Name resolution and IP connectivity are independent. Nothing about the"
  echo "  network path changed — only our ability to look the name up. DNS is a"
  echo "  separate service that can fail entirely on its own."
} > "$OUT" 2>&1
echo "  [1/5] wrote $(basename "$OUT")"

# ---------------------------------------------------------------------------
# 2. DNS RECORD POINTS AT THE WRONG IP
#    Expect: resolution SUCCEEDS, connection goes to the wrong place.
# ---------------------------------------------------------------------------
OUT="$OUTDIR/2-dns-wrong-ip.txt"
{
  hdr "FAILURE 2 — DNS resolves successfully, but to the wrong address"
  echo "Simulated client-side with --resolve, which substitutes the answer DNS"
  echo "would have given. 10.7.99.99 is an address with nothing on it."
  echo
  echo "--- resolution 'succeeds' (we have an answer) ---"
  echo "    ${DOMAIN} -> 10.7.99.99"
  echo
  echo "--- the connection attempt that follows ---"
  curl -s -m 6 $CURL_EXTRA --resolve "${DOMAIN}:${HTTPS_PORT}:10.7.99.99" \
       -o /dev/null -w 'HTTP %{http_code}  (exit follows)\n' "$URL/api/status" 2>&1
  echo "    curl exit code: $?"
  echo
  echo "--- the real record, for comparison ---"
  dig @"$DNS_PRIMARY" "$DOMAIN" +short
  echo
  echo "WHAT THIS SHOWS"
  echo "  DNS is a DIRECTORY, not a connection. It answered without error; the"
  echo "  answer was simply wrong. The failure surfaces one layer up, at TCP,"
  echo "  as a timeout — and no amount of DNS debugging would reveal it,"
  echo "  because DNS did its job."
  echo
  echo "REAL VARIANT (do this live if the evaluator asks):"
  echo "  On $DNS_PRIMARY, edit host-record for $DOMAIN to 10.7.99.99,"
  echo "  sudo brew services restart dnsmasq, flush the client cache, retry."
} > "$OUT" 2>&1
echo "  [2/5] wrote $(basename "$OUT")"

# ---------------------------------------------------------------------------
# 3. ONE BACKEND STOPPED
# ---------------------------------------------------------------------------
echo
echo "${BOLD}Failure 3 — one backend down${RESET}"
pause "Ashish: stop Backend A on $BACKEND_A  (Ctrl-C the python process)"
OUT="$OUTDIR/3-one-backend-down.txt"
{
  hdr "FAILURE 3 — Backend A stopped; the edge must keep serving"
  echo "--- 8 requests with Backend A down ---"
  for i in $(seq 1 8); do
    H=$(curl -s $CURL_EXTRA -D - -o /dev/null "$URL/api/status" | tr -d '\r')
    C=$(printf '%s\n' "$H" | head -1 | awk '{print $2}')
    B=$(printf '%s\n' "$H" | awk 'tolower($1)=="x-backend:"{print $2}')
    printf '  request %d -> HTTP %-4s served by %s\n' "$i" "${C:-???}" "${B:-?}"
  done
  echo
  echo "WHAT THIS SHOWS"
  echo "  Every request still returns 200, all from Backend B. nginx marks the"
  echo "  dead upstream failed (max_fails=1) and proxy_next_upstream retries the"
  echo "  request on the survivor, so the CLIENT NEVER SEES THE FAILURE."
  echo "  This is passive health checking: nginx learns a backend is down by"
  echo "  trying it, not by polling it."
} > "$OUT" 2>&1
echo "  [3/5] wrote $(basename "$OUT")"

# ---------------------------------------------------------------------------
# 4. BOTH BACKENDS STOPPED
# ---------------------------------------------------------------------------
echo
echo "${BOLD}Failure 4 — both backends down${RESET}"
pause "Dikshant: ALSO stop Backend B on $BACKEND_B  (Backend A stays down)"
OUT="$OUTDIR/4-both-backends-down.txt"
{
  hdr "FAILURE 4 — both backends stopped; the edge itself is still healthy"
  echo "--- DNS still resolves ---"
  dig @"$DNS_PRIMARY" "$DOMAIN" +short
  echo
  echo "--- TCP to the edge still connects ---"
  nc -z -G 2 "$EDGE" "$HTTPS_PORT" && echo "    port $HTTPS_PORT OPEN" || echo "    port CLOSED"
  echo
  echo "--- TLS still completes (certificate still served) ---"
  curl -s $CURL_EXTRA -o /dev/null -w '    TLS verify result: %{ssl_verify_result} (0 = ok)\n' "$URL/" 2>&1
  echo
  echo "--- but the application layer now fails ---"
  for i in 1 2 3; do
    curl -s $CURL_EXTRA -o /dev/null -w "    request $i -> HTTP %{http_code}\n" "$URL/api/status"
  done
  echo
  echo "WHAT THIS SHOWS"
  echo "  Exactly where the edge ends and the backend begins. DNS, TCP and TLS"
  echo "  are all functions of the EDGE and all still work. 502 Bad Gateway is"
  echo "  nginx telling us it is healthy but has nothing to forward to."
  echo "  A 502 therefore always points downstream, never at the edge itself."
} > "$OUT" 2>&1
echo "  [4/5] wrote $(basename "$OUT")"

pause "Both of you: RESTART the backends now (A on $BACKEND_A, B on $BACKEND_B)"

# ---------------------------------------------------------------------------
# 5. WRONG DESTINATION PORT
# ---------------------------------------------------------------------------
OUT="$OUTDIR/5-wrong-port.txt"
{
  hdr "FAILURE 5 — correct host, wrong port"
  echo "--- the host answers ICMP perfectly well ---"
  ping -c 2 -t 2 "$EDGE" 2>&1 | tail -3
  echo
  echo "--- port $HTTPS_PORT (the real service) ---"
  nc -z -G 2 "$EDGE" "$HTTPS_PORT" && echo "    OPEN" || echo "    closed"
  echo
  echo "--- port 4443 (nothing listening) ---"
  nc -vz -G 2 "$EDGE" 4443 2>&1 | tail -2
  curl -s -m 5 -o /dev/null -w '    curl to :4443 -> HTTP %{http_code}\n' "https://${DOMAIN}:4443/" 2>&1
  echo "    curl exit code: $?"
  echo
  echo "--- and the backend ports are firewalled from here (Extension C) ---"
  curl -s -m 3 -o /dev/null -w "    direct to backend A :$PORT_A -> %{http_code}\n" \
       "http://${BACKEND_A}:${PORT_A}/api/status" 2>&1
  echo
  echo "WHAT THIS SHOWS"
  echo "  An IP address identifies a HOST; a port identifies a SERVICE on it."
  echo "  The machine is up and reachable, but nothing is bound to 4443, so the"
  echo "  TCP handshake is refused (RST) rather than timing out. Compare that"
  echo "  with the firewalled backend port, which DROPS and therefore times out"
  echo "  — refused means 'nobody home', dropped means 'not talking to you'."
} > "$OUT" 2>&1
echo "  [5/5] wrote $(basename "$OUT")"

echo
echo "${BOLD}All five failure demonstrations captured.${RESET}"
echo "Re-run scripts/preflight.sh to confirm the system is back to healthy."
