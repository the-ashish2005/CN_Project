#!/bin/bash
# =============================================================================
#  preflight.sh — Team admv pre-demo health check
#  Run on a CLIENT Mac:   bash scripts/preflight.sh
#
#  Walks every layer in order, bottom to top:
#     LAN -> DNS -> TCP -> TLS -> HTTP -> load balancing -> caching
#  The FIRST failure is the one to fix; everything above it will fail as a
#  consequence. That ordering is the whole point of the script.
#
#  FIXED since the original version:
#    * the helper function was named head(), which shadowed the `head` command.
#      Every later `| head -1` called the function instead, so the HTTP status
#      code and the TLS error line came out as a bold "-1". Renamed to section().
#    * addresses now come from team.env instead of being hardcoded twice.
# =============================================================================

set -uo pipefail

# ---- load team addresses ----------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/../team.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
else
  echo "team.env not found at $ENV_FILE — using built-in defaults"
  DOMAIN="app.admv.test"; DNS_PRIMARY="10.7.3.140"; DNS_BACKUP="10.7.24.165"
  EDGE="10.7.25.158"; BACKEND_A="10.7.29.240"; BACKEND_B="10.7.24.165"
  PORT_A=3001; PORT_B=3002; HTTPS_PORT=443
fi

# Set CURL_EXTRA="--cacert config/ca.crt" if curl is not using the system keychain.
CURL_EXTRA="${CURL_EXTRA:-}"

GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
PASS=0; FAIL=0
ok()      { echo "  ${GREEN}OK${RESET}   $1"; PASS=$((PASS+1)); }
bad()     { echo "  ${RED}FAIL${RESET} $1"; FAIL=$((FAIL+1)); }
warn()    { echo "  ${YEL}warn${RESET} $1"; }
section() { echo; echo "${BOLD}$1${RESET}"; }   # <-- was head(); see header note

URL="https://${DOMAIN}"
[ "$HTTPS_PORT" != "443" ] && URL="https://${DOMAIN}:${HTTPS_PORT}"

echo "${BOLD}Team admv preflight — $(date)${RESET}"
echo "edge=$EDGE  dns=$DNS_PRIMARY (backup $DNS_BACKUP)  backends=$BACKEND_A:$PORT_A $BACKEND_B:$PORT_B"

# -- 1. LAN reachability ------------------------------------------------------
section "1. LAN reachability (ping)"
for pair in "DNS-primary:$DNS_PRIMARY" "Edge:$EDGE" "Backend-A:$BACKEND_A" "Backend-B:$BACKEND_B"; do
  name=${pair%%:*}; ip=${pair##*:}
  if ping -c 1 -t 2 "$ip" >/dev/null 2>&1; then ok "$name ($ip) reachable"
  else bad "$name ($ip) NOT reachable — check Wi-Fi / firewall stealth mode"; fi
done

# -- 2. DNS -------------------------------------------------------------------
section "2. DNS resolution"
ANS=$(dig +short +time=2 +tries=1 @"$DNS_PRIMARY" "$DOMAIN" | tail -1)
if [ "$ANS" = "$EDGE" ]; then ok "primary DNS answers $DOMAIN -> $ANS"
else bad "primary DNS answered '${ANS:-nothing}' (expected $EDGE) — is dnsmasq running?"; fi

BANS=$(dig +short +time=2 +tries=1 @"$DNS_BACKUP" "$DOMAIN" | tail -1)
if [ "$BANS" = "$EDGE" ]; then ok "backup DNS answers $DOMAIN -> $BANS  (Ext A)"
else warn "backup DNS gave '${BANS:-nothing}' — only needed for Extension A"; fi

SYS=$(dig +short +time=2 +tries=1 "$DOMAIN" | tail -1)
if [ "$SYS" = "$EDGE" ]; then ok "this Mac's own resolver gives $DOMAIN -> $SYS"
else bad "this Mac's resolver gave '${SYS:-nothing}' — set DNS to $DNS_PRIMARY"; fi

echo "       configured resolvers: $(networksetup -getdnsservers Wi-Fi 2>/dev/null | tr '\n' ' ')"

# -- 3. TCP -------------------------------------------------------------------
section "3. TCP connectivity to the edge"
if nc -z -G 2 "$EDGE" "$HTTPS_PORT" >/dev/null 2>&1; then ok "edge port $HTTPS_PORT open"
else bad "edge port $HTTPS_PORT closed — is nginx running on $EDGE?"; fi

# -- 4. TLS -------------------------------------------------------------------
section "4. TLS certificate (no -k)"
if curl -s -o /dev/null $CURL_EXTRA "$URL/" 2>/dev/null; then
  ok "certificate valid and trusted — demo requirement met"
else
  ERR=$(curl -sS -o /dev/null $CURL_EXTRA "$URL/" 2>&1 | head -1)
  bad "TLS/HTTPS failed: $ERR"
fi

# -- 5. HTTP + load balancing -------------------------------------------------
section "5. HTTPS + load balancing (6 requests)"
SEEN=""
for i in 1 2 3 4 5 6; do
  HDRS=$(curl -s -D - -o /dev/null $CURL_EXTRA "$URL/api/status" 2>/dev/null | tr -d '\r')
  CODE=$(printf '%s\n' "$HDRS" | head -1 | awk '{print $2}')
  BE=$(printf '%s\n' "$HDRS"   | awk 'tolower($1)=="x-backend:"{print $2}')
  echo "       request $i -> HTTP ${CODE:-???}  backend ${BE:-?}"
  SEEN="$SEEN$BE"
done
case "$SEEN" in *A*) ok "Backend A served requests";; *) bad "Backend A never answered — check $BACKEND_A:$PORT_A";; esac
case "$SEEN" in *B*) ok "Backend B served requests";; *) bad "Backend B never answered — check $BACKEND_B:$PORT_B";; esac

# -- 6. Caching ---------------------------------------------------------------
section "6. HTTP caching (/api/info)"
INFO=$(curl -sI $CURL_EXTRA "$URL/api/info" 2>/dev/null | tr -d '\r')
CC=$(printf '%s\n'   "$INFO" | awk 'tolower($1)=="cache-control:"{ $1=""; sub(/^ /,""); print }')
ETAG=$(printf '%s\n' "$INFO" | awk 'tolower($1)=="etag:"{print $2}')
[ -n "$CC" ] && ok "Cache-Control: $CC" || bad "no Cache-Control header"
if [ -n "$ETAG" ]; then
  ok "ETag: $ETAG"
  C304=$(curl -s -o /dev/null -w "%{http_code}" -H "If-None-Match: $ETAG" $CURL_EXTRA "$URL/api/info")
  [ "$C304" = "304" ] && ok "conditional request -> 304 Not Modified" \
                      || bad "conditional request returned $C304 (expected 304)"
else
  bad "no ETag header"
fi

# -- summary ------------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
  echo "${GREEN}${BOLD}ALL $PASS CHECKS PASSED — ready for the demo.${RESET}"
else
  echo "${RED}${BOLD}$FAIL check(s) failed, $PASS passed.${RESET}"
  echo "Fix the FIRST failure above — it is the lowest broken layer, and the"
  echo "ones after it are probably just consequences of it."
fi
exit "$FAIL"
