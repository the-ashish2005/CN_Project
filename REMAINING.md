# What is left to do

Everything that could be written has been. What remains is evidence that has to
be *generated on your machines* — nobody can prepare it off-site, and a
fabricated capture would be both dishonest and obvious to anyone who opens it
in Wireshark.

Total time: **about 45 minutes** with all four laptops up.

---

## Before anything else

```bash
# on every laptop: check the address it actually has today
ipconfig getifaddr en0
```

If any address differs from `team.env`, update **`team.env` only**, then update
the literal IPs in `config/dnsmasq.conf`, `config/nginx-phase1.conf`,
`config/nginx-standby.conf` and the two `pf-*.anchor` files (grep for the old
address). Then:

```bash
bash scripts/preflight.sh      # must be all-OK before collecting any evidence
```

---

## 1. Task G — packet captures · 10 min · **7 marks, currently unevidenced**

Follow [`scripts/capture-guide.md`](scripts/capture-guide.md). Produces:

- `evidence/phase1/G-captures/G1-client-tls12.pcapng`
- `evidence/phase1/G-captures/G2-client-tls13.pcapng`
- `evidence/phase1/G-captures/G3-edge-to-backend.pcap`

This is the single highest-value item on the list. Do it first.

## 2. Tasks C, D, E, F — automated · 2 min

```bash
bash scripts/collect-evidence.sh
```

Writes into the four matching `evidence/phase1/` folders. Nothing manual.

## 3. Failure scenarios — guided · 15 min

```bash
bash scripts/failure-demos.sh
```

Pauses and tells you who has to stop what. Get Ashish and Dikshant on a call
first so nobody is waiting.

## 4. Extension D re-run on real laptops · 10 min

The current `evidence/phase2/D-ha-failover.txt` was captured against Docker
containers on `127.0.0.1` and still contains a `# TOMORROW (real laptops)`
to-do note inside it. An evaluator reading that file will see it.

```bash
bash scripts/D-failover-demo.sh | tee evidence/phase2/D-ha-failover.txt
```

## 5. Extension B re-run at TTL 30 · 8 min

The existing evidence was captured at TTL 300 and shows cached-old plus a
manual flush — but never the record changing **on its own** when the TTL
expires, which the brief asks for explicitly. With `local-ttl=30` the wait is
30 seconds instead of five minutes:

```bash
# Mac 1 — confirm local-ttl=30 in dnsmasq.conf, then:
dig app.admv.test +short                 # prime the cache
# change host-record to 10.7.99.99, restart dnsmasq
dscacheutil -q host -a name app.admv.test   # still OLD
sleep 35
dscacheutil -q host -a name app.admv.test   # now NEW, with no flush
# then flush and show the instant version too
```

Capture all of it into `evidence/phase2/B-dns-ttl.txt`.

## 6. Two screenshots · 5 min

The brief's demo sequence asks for a browser specifically, so terminal output
alone leaves a gap:

- `evidence/phase1/E-tls/` — browser padlock + certificate viewer on `https://app.admv.test`
- `evidence/phase1/F-caching/` — DevTools Network tab showing a 304 or a memory-cache hit

## 7. Install the corrected firewall rules · 5 min

`config/pf-backend-a.anchor` now whitelists **both** edges. See
[`config/pf-setup-and-rollback.md`](config/pf-setup-and-rollback.md) — back up
`/etc/pf.conf` before you start.

---

## Then push

```bash
git add -A
git commit -m "Complete Phase 1 + Phase 2 deliverables"
git push
```

---

# What changed in this rebuild

## Added

| Item | Why |
|---|---|
| `backend/backend.py` | named deliverable, was never committed |
| `config/dnsmasq-backup.conf` | Extension A resolver |
| `config/nginx-standby.conf` | Extension E standby edge |
| `config/pf-backend-{a,b}.anchor` | Extension C rules — bundle item that was missing |
| `config/pf-setup-and-rollback.md` | the brief requires a rollback procedure |
| `scripts/collect-evidence.sh` | generates Tasks C/D/E/F evidence |
| `scripts/failure-demos.sh` | the five required failure scenarios |
| `scripts/capture-guide.md` | exact Wireshark procedure for Task G |
| `team.env` | one place to change addresses when the Wi-Fi reassigns them |
| `.gitignore` | private keys must never be committed |

## Fixed

**`scripts/preflight.sh` — `head()` shadowing.** The old version defined a
helper function called `head()`, which shadows the `head` command. Every later
`| head -1` therefore called the *function*, so the HTTP status code and the TLS
error line printed a bold `-1` instead of the real value. Renamed to `section()`.

**`nginx-standby.conf` — upstream pointed at the wrong host.** The Phase 2 draft
sent the standby edge's upstreams to `10.7.25.158:3001/3002` — the **primary
edge's** address, not a backend. A standby whose upstreams live on the machine
it is replacing is useless. Now points at the real backends.

**Extension C vs Extension E conflict.** The firewall rules whitelisted only the
primary edge. The moment an Extension E cutover happened, the standby edge would
have been blocked from the backends and every request would have returned 502 —
Extension C would silently have broken Extension E. Both anchors now whitelist
both edge addresses.

**ETag mismatch across backends.** `/api/info` originally included the backend ID
in its body, so A and B produced different ETags. Under round-robin, a client
caching from A and revalidating against B would get a 200 instead of a 304 —
the caching demo would have worked only about half the time. The payload is now
identical on both; identity is carried in the `X-Backend` header, which is not
part of the fingerprint. Verified: an ETag from A returns 304 from B.

**Address and role contradictions.** Phase 1 and Phase 2 documents disagreed on
every IP and on which teammate ran which backend. Everything now uses the
verified 24 Nov addresses, and the backend swap between phases is stated
explicitly in `architecture/architecture.md` so nobody is caught out in viva.

**MAC address placeholders.** `architecture.md` showed `xx:xx:xx:xx:xx:xx`.
Real values transcribed from your own Phase 1 screenshots:

| Member | MAC |
|---|---|
| Vaibhav | `5e:2a:74:cb:d1:2e` |
| Mukul | `9a:36:d5:6e:66:4a` |
| Ashish | `4a:73:18:71:2f:c8` |
| Dikshant | `16:ea:47:1f:74:d8` |

All four are locally administered (the `0x02` bit is set in the first octet) —
macOS private Wi-Fi addresses, not burned-in hardware addresses. Worth knowing
if you are asked.

**`README.md` filename mismatch.** It instructed you to copy
`config/nginx-phase1.conf`, which did not exist; the file was `nginx.conf`. The
file is now actually named `nginx-phase1.conf`.

**Phase 2 merged into the repo.** The brief asks for one Architecture Document
updated for Phase 2 and one Configuration Bundle covering both phases, not two
separate zips.

---

## Verified in this sandbox

- `backend.py` — all endpoints, `X-Backend` on every response, HEAD (`curl -I`),
  304 on matching ETag, 200 on stale ETag, 404 on unknown paths, 20 concurrent
  requests, both instances running together, cross-backend revalidation
- all four shell scripts pass `bash -n`
- both nginx configs: balanced braces, no missing semicolons, every `proxy_pass`
  target declared as an `upstream`

Not verified here: the nginx configs against a real nginx binary (none available
in this environment). Run `sudo nginx -t` on Mac 2 before demo day — it takes a
second and catches anything a structural check cannot.
