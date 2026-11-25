# Backend services (Task C)

One file, `backend.py`, runs both backends. Identity comes from the environment,
so the two laptops run byte-identical code.

## Run

```bash
# Ashish — Backend A (Mac 3)
BACKEND_ID=A PORT=3001 python3 backend/backend.py

# Dikshant — Backend B (Mac 4)
BACKEND_ID=B PORT=3002 python3 backend/backend.py
```

No dependencies — Python 3 from the macOS Command Line Tools is enough.

## Endpoints

| Endpoint | Response | Cache-Control | Purpose |
|---|---|---|---|
| `GET /` | `{"message": "Backend A is running"}` | `no-store` | liveness |
| `GET /api/status` | `{"backend","status","uptime_s","time"}` | `no-store` | load-balancing probe |
| `GET /api/info` | static JSON + `ETag` | `max-age=60` | caching / 304 demo |

Every response carries `X-Backend: A` or `X-Backend: B`.

## Two things worth being able to explain in the viva

**Why `0.0.0.0` and not `127.0.0.1`.** Loopback is reachable only from the
machine itself, so the edge on another laptop could never connect. `0.0.0.0`
means every interface on this host, including Wi-Fi `en0`.

**Why `/api/status` is `no-store` but `/api/info` is `max-age=60`.** They are
demonstrating opposite things. `/api/status` must never be cached, or repeated
requests would be answered locally and the A/B alternation would stop being
real. `/api/info` must be cacheable, or there would be nothing to revalidate
with an ETag and no 304 to show.

The ETag is an MD5 of the exact response bytes. That is why `/api/info` returns
a *static* payload — if the body changed per request the fingerprint would
change too, and a conditional request could never match.
