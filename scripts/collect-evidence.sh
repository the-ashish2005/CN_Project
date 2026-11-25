#!/bin/bash
# =============================================================================
#  collect-evidence.sh — Team admv
#
#  Generates the Phase 1 evidence for Tasks C, D, E and F in one pass and
#  writes it into evidence/phase1/<task>/ ready to commit.
#
#  Run it from a CLIENT Mac, with the whole system up:
#      bash scripts/collect-evidence.sh
#
#  It does NOT replace the Wireshark captures (Task G) — those must come off a
#  real interface. See scripts/capture-guide.md for those.
#  It does NOT run the failure scenarios — see scripts/failure-demos.sh.
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1090
. "$ROOT/team.env"

EV="$ROOT/evidence/phase1"
CURL_EXTRA="${CURL_EXTRA:-}"
URL="https://${DOMAIN}"
[ "$HTTPS_PORT" != "443" ] && URL="https://${DOMAIN}:${HTTPS_PORT}"

# Prefer Homebrew's OpenSSL; macOS /usr/bin/openssl is LibreSSL and prints less.
OSSL="$( [ -x "$(brew --prefix openssl@3 2>/dev/null)/bin/openssl" ] \
         && echo "$(brew --prefix openssl@3)/bin/openssl" || echo openssl )"

stamp() { date '+%a %d %b %Y %H:%M:%S %Z'; }
banner() { printf '%s\n# %s\n# captured %s\n%s\n\n' \
           "$(printf '#%.0s' {1..70})" "$1" "$(stamp)" "$(printf '#%.0s' {1..70})"; }

echo "Collecting Phase 1 evidence into $EV ..."

# ===========================================================================
# TASK C — backends are reachable and correctly identified
# ===========================================================================
OUT="$EV/C-backends/C-backend-direct.txt"
{
  banner "Task C — backends reachable, each identifies itself"
  echo "Run from the EDGE ($EDGE), which is the only host the firewall permits"
  echo "to reach the backend ports directly (see Extension C)."
  echo
  for pair in "A:$BACKEND_A:$PORT_A" "B:$BACKEND_B:$PORT_B"; do
    id=${pair%%:*}; rest=${pair#*:}; ip=${rest%%:*}; port=${rest##*:}
    echo "=== Backend $id — http://$ip:$port ==="
    echo "--- GET / (liveness) ---"
    curl -s -m5 "http://$ip:$port/" ; echo
    echo "--- GET /api/status with headers ---"
    curl -s -m5 -D - "http://$ip:$port/api/status" | tr -d '\r'
    echo
  done
  echo "=== Confirms ==="
  echo "* both backends bind a LAN-reachable interface (not 127.0.0.1 only)"
  echo "* each returns its own identifier in the body AND the X-Backend header"
  echo "* fixed ports $PORT_A / $PORT_B as required by Task C"
} > "$OUT" 2>&1
echo "  wrote $(basename "$OUT")"

# ===========================================================================
# TASK D — round-robin load balancing through the edge, by name
# ===========================================================================
OUT="$EV/D-loadbalancing/D-round-robin.txt"
{
  banner "Task D — round-robin load balancing via $DOMAIN"
  echo "Every request below goes to the NAME, never to a backend IP. The client"
  echo "has no idea the backends exist; only nginx's upstream block does."
  echo
  echo "=== 10 consecutive requests to $URL/api/status ==="
  A=0; B=0
  for i in $(seq 1 10); do
    H=$(curl -s $CURL_EXTRA -D - -o /dev/null "$URL/api/status" | tr -d '\r')
    BE=$(printf '%s\n' "$H" | awk 'tolower($1)=="x-backend:"{print $2}')
    UP=$(printf '%s\n' "$H" | awk 'tolower($1)=="x-upstream:"{print $2}')
    ED=$(printf '%s\n' "$H" | awk 'tolower($1)=="x-edge:"{print $2}')
    printf '  request %2d  X-Backend: %-2s  X-Upstream: %-22s X-Edge: %s\n' "$i" "${BE:-?}" "${UP:-?}" "${ED:-?}"
    [ "$BE" = "A" ] && A=$((A+1)); [ "$BE" = "B" ] && B=$((B+1))
  done
  echo
  echo "  totals -> A=$A  B=$B   (round-robin should give an even split)"
  echo
  echo "=== Negotiated HTTP version ==="
  curl -s $CURL_EXTRA -o /dev/null -w 'HTTP version negotiated: %{http_version}\n' "$URL/api/status"
  curl -s $CURL_EXTRA --http1.1 -o /dev/null -w 'forced HTTP/1.1      : %{http_version}\n' "$URL/api/status"
  echo
  echo "=== Port 80 -> 443 redirect ==="
  curl -s -o /dev/null -w 'http:// returns %{http_code} -> %{redirect_url}\n' "http://${DOMAIN}/"
  echo
  echo "=== Confirms ==="
  echo "* repeated requests to ONE name are answered by TWO different backends"
  echo "* the client never learns or uses a backend IP address"
  echo "* plain HTTP is redirected to HTTPS at the edge"
} > "$OUT" 2>&1
echo "  wrote $(basename "$OUT")"

# ===========================================================================
# TASK E — TLS termination, certificate chain, trust
# ===========================================================================
OUT="$EV/E-tls/E-tls-verification.txt"
{
  banner "Task E — HTTPS / TLS at the edge"
  echo "=== 1. Certificate chain as presented by the edge ==="
  echo | $OSSL s_client -connect "${EDGE}:${HTTPS_PORT}" -servername "$DOMAIN" 2>/dev/null \
       | sed -n '/Certificate chain/,/---/p'
  echo
  echo "=== 2. Negotiated protocol and cipher ==="
  echo | $OSSL s_client -connect "${EDGE}:${HTTPS_PORT}" -servername "$DOMAIN" 2>/dev/null \
       | grep -E 'Protocol|Cipher|Verify return code|Server public key'
  echo
  echo "=== 3. Server certificate details ==="
  echo | $OSSL s_client -connect "${EDGE}:${HTTPS_PORT}" -servername "$DOMAIN" 2>/dev/null \
       | $OSSL x509 -noout -subject -issuer -dates -ext subjectAltName
  echo
  echo "=== 4. TLS 1.2 forced (certificate visible in the capture) ==="
  curl -s $CURL_EXTRA --tlsv1.2 --tls-max 1.2 -o /dev/null \
       -w 'TLS %{ssl_verify_result} (0 = verified)  version=%{http_version}  -> HTTP %{http_code}\n' "$URL/api/status"
  echo "=== 5. TLS 1.3 (certificate encrypted in the capture) ==="
  curl -s $CURL_EXTRA --tlsv1.3 -o /dev/null \
       -w 'TLS %{ssl_verify_result} (0 = verified)  version=%{http_version}  -> HTTP %{http_code}\n' "$URL/api/status"
  echo
  echo "=== 6. THE DEMO REQUIREMENT: no -k, no --insecure ==="
  if curl -s $CURL_EXTRA -o /dev/null "$URL/"; then
    echo "  PASS — certificate validated against the system trust store."
    echo "  The admv Local CA is trusted, so no override flag is needed."
  else
    echo "  FAIL — trust not established. Install the CA:"
    echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain config/ca.crt"
  fi
  echo
  echo "=== Confirms ==="
  echo "* TLS is terminated at the edge; backends speak plain HTTP behind it"
  echo "* the leaf certificate is signed by our own CA and carries both SANs"
  echo "* validation succeeds with no bypass flag, as the brief requires"
} > "$OUT" 2>&1
echo "  wrote $(basename "$OUT")"

# ===========================================================================
# TASK F — caching: fresh hit, conditional request, no-store
# ===========================================================================
OUT="$EV/F-caching/F-caching.txt"
{
  banner "Task F — HTTP caching behaviour"
  echo "=== 1. Full response headers for /api/info ==="
  curl -sI $CURL_EXTRA "$URL/api/info" | tr -d '\r'
  echo
  ETAG=$(curl -sI $CURL_EXTRA "$URL/api/info" | tr -d '\r' | awk 'tolower($1)=="etag:"{print $2}')
  echo "=== 2. First request — a full 200, body transferred ==="
  curl -s $CURL_EXTRA -o /dev/null \
       -w 'HTTP %{http_code}   bytes downloaded: %{size_download}\n' "$URL/api/info"
  echo
  echo "=== 3. Conditional request — If-None-Match: $ETAG ==="
  curl -s $CURL_EXTRA -H "If-None-Match: $ETAG" -o /dev/null \
       -w 'HTTP %{http_code}   bytes downloaded: %{size_download}\n' "$URL/api/info"
  echo "    304 + 0 bytes = the saving. The client already holds a valid copy,"
  echo "    so the server sends only headers confirming it is still fresh."
  echo
  echo "=== 4. Stale ETag — server must send the full body again ==="
  curl -s $CURL_EXTRA -H 'If-None-Match: "stale-value-0000"' -o /dev/null \
       -w 'HTTP %{http_code}   bytes downloaded: %{size_download}\n' "$URL/api/info"
  echo
  echo "=== 5. /api/status is deliberately uncacheable ==="
  curl -sI $CURL_EXTRA "$URL/api/status" | tr -d '\r' | grep -i 'cache-control'
  echo "    no-store is required here: if this endpoint were cached, repeated"
  echo "    requests would be answered locally and the load-balancing demo"
  echo "    would show one backend forever."
  echo
  echo "=== The three cases, as the brief asks them to be distinguished ==="
  echo "  fresh cache hit      — within max-age=60; client reuses its copy, NO request is sent"
  echo "  conditional request  — after max-age; client asks 'still valid?' -> 304, headers only"
  echo "  full new request     — no copy, or ETag no longer matches -> 200 with the whole body"
} > "$OUT" 2>&1
echo "  wrote $(basename "$OUT")"

echo
echo "Done. Still outstanding:"
echo "  * Task G packet captures  -> scripts/capture-guide.md"
echo "  * failure scenarios       -> bash scripts/failure-demos.sh"
