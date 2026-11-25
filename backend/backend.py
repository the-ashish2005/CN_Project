#!/usr/bin/env python3
"""
Backend REST service — Team admv, Computer Networks course project.

One file runs BOTH backends; the identity comes from the environment:

    BACKEND_ID=A PORT=3001 python3 backend/backend.py     # Ashish  (Backend A)
    BACKEND_ID=B PORT=3002 python3 backend/backend.py     # Dikshant (Backend B)

Deliberately dependency-free (standard library only) — the project brief says
"keep the application simple; the network is the project". Nothing here is
clever: the interesting behaviour is in the HTTP headers, because those are
what the edge, the cache demo and the load-balancing demo actually rely on.

Endpoints
---------
GET /             liveness page            -> {"message": "Backend A is running"}
GET /api/status   load-balancing probe     -> Cache-Control: no-store   (never cached,
                                              so every request really reaches a backend)
GET /api/info     caching / 304 demo       -> Cache-Control: max-age=60 + ETag
                                              (static body, so the ETag is stable)

Every response carries  X-Backend: A  or  X-Backend: B  so a client can see which
instance served it.

Why 0.0.0.0 and not 127.0.0.1
-----------------------------
Binding to the loopback address would make the service reachable only from the
machine it runs on, so the nginx edge on another laptop could never connect.
0.0.0.0 means "every interface on this host", including the Wi-Fi interface en0.
"""

import hashlib
import json
import os
import socket
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------------------
# Identity — supplied by the environment so one file serves both laptops
# ---------------------------------------------------------------------------
BACKEND_ID = os.environ.get("BACKEND_ID", "A").upper()
PORT = int(os.environ.get("PORT", "3001"))
HOST = os.environ.get("HOST", "0.0.0.0")

STARTED_AT = time.time()

# ---------------------------------------------------------------------------
# /api/info — a STATIC payload, IDENTICAL on both backends.
#
# Two separate reasons it must be exactly these bytes:
#
# 1. It has to be STATIC. An ETag is a fingerprint of the body, so if the body
#    changed per request the fingerprint would change too and a conditional
#    request could never return 304. /api/status carries the live values, and
#    that is exactly why it is marked no-store instead.
#
# 2. It has to be the SAME ON BOTH BACKENDS. This is the subtle one. We are
#    behind a round-robin load balancer, so consecutive requests for the same
#    URL land on different instances. If Backend A and Backend B computed
#    different ETags, a client that cached A's copy and then revalidated
#    against B would be told "changed" and sent a fresh 200 — the 304 would
#    appear only about half the time, at random.
#
#    So deliberately NO BACKEND_ID in here. A cache validator is a property of
#    the RESOURCE, not of the server instance that happened to answer. Real
#    load-balanced deployments hit this constantly; it is why ETags are
#    normally derived from content or a version, never from the host.
#
#    Which backend served the response is still visible — in the X-Backend
#    header, which is metadata and plays no part in the fingerprint.
# ---------------------------------------------------------------------------
INFO_PAYLOAD = {
    "service": "admv-backend",
    "version": "1.0.0",
    "domain": "admv.test",
    "endpoints": ["/", "/api/status", "/api/info"],
}
INFO_BODY = json.dumps(INFO_PAYLOAD, indent=2).encode("utf-8")

# Strong ETag: md5 over the exact bytes we will send.
INFO_ETAG = '"%s"' % hashlib.md5(INFO_BODY).hexdigest()


def _utc_now() -> str:
    """RFC3339 / ISO8601 timestamp in UTC, e.g. 2026-11-24T08:58:20.022Z"""
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class BackendHandler(BaseHTTPRequestHandler):
    # Advertise HTTP/1.1 so keep-alive works; nginx proxies to us over HTTP/1.x.
    protocol_version = "HTTP/1.1"
    server_version = "admv-backend/1.0"
    sys_version = ""

    # -- helpers ------------------------------------------------------------

    def _send(self, status: int, body: bytes, cache_control: str, etag: str = None,
              content_type: str = "application/json"):
        """
        Single place where every response is written, so the X-Backend header
        can never be forgotten on one branch.

        body_only_on_get: for a HEAD request we must send identical headers but
        no body (RFC 9110). curl -I sends HEAD, and the caching demo uses it.
        """
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache_control)
        if etag:
            self.send_header("ETag", etag)
        # Evidence header — this is what the load-balancing demo greps for.
        self.send_header("X-Backend", BACKEND_ID)
        self.send_header("X-Backend-Host", socket.gethostname())
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def _json(self, status: int, payload: dict, cache_control: str, etag: str = None):
        self._send(status, json.dumps(payload, indent=2).encode("utf-8"), cache_control, etag)

    # -- routing ------------------------------------------------------------

    def _route(self):
        # Strip any query string: /api/status?x=1 is still /api/status
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        # ---- GET /  : liveness ------------------------------------------
        if path == "/":
            self._json(200, {"message": f"Backend {BACKEND_ID} is running"}, "no-store")
            return

        # ---- GET /api/status : load-balancing probe ----------------------
        # no-store guarantees neither the browser nor any intermediary serves
        # this from cache, so repeated requests genuinely hit the upstream and
        # the A/B alternation is real rather than a cached artefact.
        if path == "/api/status":
            self._json(200, {
                "backend": BACKEND_ID,
                "status": "ok",
                "uptime_s": int(time.time() - STARTED_AT),
                "time": _utc_now(),
            }, "no-store")
            return

        # ---- GET /api/info : caching + conditional request ---------------
        if path == "/api/info":
            # Conditional request: the client is asking "has it changed since
            # the copy I hold?". If its ETag matches ours, answer 304 with no
            # body — that is the bandwidth saving the demo is meant to show.
            if_none_match = self.headers.get("If-None-Match", "")
            if INFO_ETAG in [t.strip() for t in if_none_match.split(",")]:
                self._send(304, b"", "max-age=60", INFO_ETAG)
                return
            self._send(200, INFO_BODY, "max-age=60", INFO_ETAG)
            return

        # ---- anything else ------------------------------------------------
        self._json(404, {"error": "not found", "path": path, "backend": BACKEND_ID}, "no-store")

    def do_GET(self):
        self._route()

    def do_HEAD(self):
        # curl -I sends HEAD. _send() suppresses the body for us, so the same
        # routing code produces headers identical to the GET.
        self._route()

    def log_message(self, fmt, *args):
        # Timestamped one-liner per request — this is the backend-side evidence
        # that the edge, and only the edge, is connecting (Extension C).
        print(f"[{_utc_now()}] {self.address_string()} -> {fmt % args}", flush=True)


def main():
    server = ThreadingHTTPServer((HOST, PORT), BackendHandler)
    print("=" * 62, flush=True)
    print(f" Backend {BACKEND_ID} listening on http://{HOST}:{PORT}", flush=True)
    print(f" host: {socket.gethostname()}", flush=True)
    print(f" ETag for /api/info: {INFO_ETAG}", flush=True)
    print(" endpoints: /  /api/status  /api/info", flush=True)
    print("=" * 62, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
