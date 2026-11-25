# Private Network Service Platform — Team admv

**Computer Networks Course Project** · Phase 1 (Build & Observe) + Phase 2 (Harden & Recover)

A private service environment built on four macOS laptops on a local network,
with no cloud. A client types `https://app.admv.test`, the name is resolved by
**our own DNS server**, the request reaches an **nginx edge over HTTPS**, and it
is **load-balanced across two REST backends**. Phase 2 adds a backup resolver,
firewall isolation, automatic backend failover and a standby edge.

> The application stays simple; the network is the project.

---

## Team

| Member | Machine | Role | Also runs |
|---|---|---|---|
| Vaibhav Vats | Mac 1 | Private DNS server + test client | Wireshark captures |
| Mukul Kumar | Mac 2 | Edge: reverse proxy + load balancer + TLS | certificates |
| Ashish Kumar Yadav | Mac 3 | Backend A (`:3001`) + test client | — |
| Dikshant Jangra | Mac 4 | Backend B (`:3002`) | backup DNS (Ext A), standby edge (Ext E) |

Every member can explain every component; roles only record who configured what.

---

## Addresses

Current as of the verified run on **24 Nov 2026**. The lab Wi-Fi reassigns
addresses per session — if they change, edit **`team.env` only** and re-run
`scripts/preflight.sh`.

| Machine | Role | IPv4 | Services (port) | Cloud equivalent |
|---|---|---|---|---|
| Mac 1 | DNS + client | `10.7.3.140` | dnsmasq (UDP/TCP 53) | AWS Route 53 |
| Mac 2 | Edge | `10.7.25.158` | nginx (80 → 443) | AWS ALB / CDN edge |
| Mac 3 | Backend A | `10.7.29.240` | Python REST (TCP 3001) | EC2 instance A |
| Mac 4 | Backend B | `10.7.24.165` | Python REST (3002), dnsmasq (53), nginx (443) | EC2 B + standby |

MAC addresses, subnet reasoning and the full protocol-to-layer mapping are in
[`architecture/architecture.md`](architecture/architecture.md).

---

## Request flow

```
Client (Mac 1 / Mac 3)
   │ 1. DNS query  app.admv.test ?          UDP 53   ──►  Mac 1 (dnsmasq)
   │ ◄── answer: 10.7.25.158 (TTL 30 s)
   │ 2. TCP handshake  SYN / SYN-ACK / ACK   TCP 443  ──►  Mac 2 (nginx)
   │ 3. TLS handshake  (TLS terminated at the edge)
   │ 4. HTTPS GET /api/status  (HTTP/2, encrypted)
   ▼
Mac 2 (nginx, round-robin)
   ├── plain HTTP ──► Mac 3  Backend A :3001
   └── plain HTTP ──► Mac 4  Backend B :3002
```

---

## Repository layout

```
.
├── team.env                 single source of truth for addresses
├── README.md
├── architecture/            topology diagrams (both phases), architecture.md
├── backend/                 backend.py + run notes
├── config/
│   ├── dnsmasq.conf             primary resolver          (Mac 1)
│   ├── dnsmasq-backup.conf      backup resolver, Ext A    (Mac 4)
│   ├── nginx-phase1.conf        primary edge              (Mac 2)
│   ├── nginx-standby.conf       standby edge, Ext E       (Mac 4)
│   ├── pf-backend-a.anchor      firewall, Ext C           (Mac 3)
│   ├── pf-backend-b.anchor      firewall, Ext C           (Mac 4)
│   ├── pf-setup-and-rollback.md install + restore procedure
│   ├── tls-setup.md             CA + certificate commands
│   └── ca.crt                   public CA certificate
├── scripts/
│   ├── preflight.sh             layered health check, run before any demo
│   ├── collect-evidence.sh      generates Task C/D/E/F evidence
│   ├── failure-demos.sh         the five required failure scenarios
│   ├── D-failover-demo.sh       Extension D on the real laptops
│   └── capture-guide.md         Wireshark procedure for Task G
├── evidence/
│   ├── phase1/   A-lan B-dns C-backends D-loadbalancing E-tls F-caching G-captures failures
│   └── phase2/   A–E extension evidence + final system verification
└── phase2/       Phase2-Final-Report.pdf
```

---

## Setup

### 1. DNS server (Mac 1)

```bash
cp config/dnsmasq.conf $(brew --prefix)/etc/dnsmasq.conf
$(brew --prefix)/sbin/dnsmasq --test
sudo brew services start dnsmasq
```

Point every client at it — primary first, backup second:

```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.3.140 10.7.24.165
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

### 2. Backends (Mac 3 and Mac 4)

```bash
BACKEND_ID=A PORT=3001 python3 backend/backend.py    # Ashish
BACKEND_ID=B PORT=3002 python3 backend/backend.py    # Dikshant
```

Details in [`backend/README.md`](backend/README.md).

### 3. TLS certificates (Mac 2)

A private CA (`admv Local CA`) signs a server certificate for both names. Full
commands in [`config/tls-setup.md`](config/tls-setup.md). Trust it on every
client:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain config/ca.crt
```

### 4. Edge (Mac 2)

```bash
cp config/nginx-phase1.conf $(brew --prefix)/etc/nginx/servers/admv.conf
sudo nginx -t && sudo nginx
```

### 5. Phase 2 additions

```bash
# Mac 4 — backup DNS
cp config/dnsmasq-backup.conf $(brew --prefix)/etc/dnsmasq.conf

# Mac 3 / Mac 4 — firewall isolation (back up /etc/pf.conf first!)
#   see config/pf-setup-and-rollback.md

# Mac 4 — standby edge
cp config/nginx-standby.conf $(brew --prefix)/etc/nginx/servers/admv.conf
```

---

## Start-up order (demo day)

| # | Machine | Command |
|---|---|---|
| 1 | All | join the team network; `ipconfig getifaddr en0` |
| 2 | All | update `team.env` if any address changed |
| 3 | Mac 1 | `sudo brew services start dnsmasq` |
| 4 | Mac 3 | `BACKEND_ID=A PORT=3001 python3 backend/backend.py` |
| 5 | Mac 4 | `BACKEND_ID=B PORT=3002 python3 backend/backend.py` |
| 6 | Mac 2 | `sudo nginx -t && sudo nginx` |
| 7 | any client | `bash scripts/preflight.sh` ← must be all-OK |

---

## Verification

```bash
bash scripts/preflight.sh                      # checks every layer in order

dig app.admv.test                              # SERVER: 10.7.3.140#53, answer 10.7.25.158
curl -v https://app.admv.test/api/status       # no certificate warnings, no -k
for i in {1..6}; do
  curl -s -D - -o /dev/null https://app.admv.test/api/status | grep -i x-backend
done                                            # A, B, A, B, A, B
curl -I https://app.admv.test/api/info         # Cache-Control + ETag
```

---

## Evidence index

Each row maps to a step of the final demonstration sequence.

| Demo step | What it shows | Evidence |
|---|---|---|
| 1. Topology and IP inventory | roles, IPs, services | [`architecture/`](architecture/) |
| 2. All machines on the LAN | interface details, ping between every pair | [`A-lan/`](evidence/phase1/A-lan/) |
| 3. Private name resolution | `dig` from two clients, resolver settings, dnsmasq log | [`B-dns/`](evidence/phase1/B-dns/) |
| — Backends reachable from the edge | `X-Backend: A`/`B` by direct IP from Mac 2 | [`C-backends/`](evidence/phase1/C-backends/) |
| 4. HTTPS by name, no warnings | `curl -v`, certificate chain, trust verified | [`E-tls/`](evidence/phase1/E-tls/) |
| 5. Load balancing | A/B alternating; HTTP/2 vs HTTP/1.1 | [`D-loadbalancing/`](evidence/phase1/D-loadbalancing/) |
| 6. Packet evidence | DNS, TCP handshake, TLS handshake, certificate | [`G-captures/`](evidence/phase1/G-captures/) |
| 7. HTTP caching | headers, 200 vs 304, no-store vs max-age | [`F-caching/`](evidence/phase1/F-caching/) |
| 8. Backend failure | service continues on Backend B | [`failures/`](evidence/phase1/failures/) |
| 9. Phase 2 resilience | backup DNS, TTL, isolation, HA, cutover | [`evidence/phase2/`](evidence/phase2/) |

### Packet captures

| File | Contents | Useful Wireshark filters |
|---|---|---|
| `G1-client-tls12.pcapng` | full client request, TLS 1.2 (certificate visible) | `dns`, `tcp.flags.syn==1`, `tls.handshake.type==11` |
| `G2-client-tls13.pcapng` | same request, TLS 1.3 (certificate encrypted) | `tls.handshake` |
| `G3-edge-to-backend.pcap` | Mac 2 → backends, plain HTTP after TLS termination | `http` |

Procedure: [`scripts/capture-guide.md`](scripts/capture-guide.md).

---

## Failure demonstrations (Phase 1, section 6.3)

Run `bash scripts/failure-demos.sh` — guided, writes into `evidence/phase1/failures/`.

| # | Failure | Observation | What it shows |
|---|---|---|---|
| 1 | Wrong DNS server on a client | `dig` times out; `ping` to the edge works | DNS and IP connectivity are independent |
| 2 | DNS record points to a wrong IP | resolution succeeds; connection times out | DNS is a directory, not a connection |
| 3 | Backend A stopped | all requests served by B, no errors | nginx fails over to the healthy upstream |
| 4 | Both backends stopped | DNS, TCP and TLS work; nginx returns 502 | where the edge ends and the backend begins |
| 5 | Wrong destination port | host pingable; TCP refused on 4443 | IP finds the host, the port finds the service |

---

## Phase 2 extensions

| Ext | What it adds | Evidence |
|---|---|---|
| A | Backup DNS resolver on Mac 4 | [`A-dns-failover.txt`](evidence/phase2/A-dns-failover.txt) |
| B | Short TTL and controlled record change | [`B-dns-ttl.txt`](evidence/phase2/B-dns-ttl.txt) |
| C | `pf` rules — backend ports accept the edges only | [`C-A-edge-verification.txt`](evidence/phase2/C-A-edge-verification.txt) |
| D | nginx passive health checks, automatic failover | [`D-ha-failover.txt`](evidence/phase2/D-ha-failover.txt) |
| E | Standby edge + DNS-based cutover | [`E-edge-migration.txt`](evidence/phase2/E-edge-migration.txt) |
| F | Layered diagnosis ladder (performed live) | [`phase2/Phase2-Final-Report.pdf`](phase2/Phase2-Final-Report.pdf) |

Full write-up, learning summaries and the configuration appendix:
[`phase2/Phase2-Final-Report.pdf`](phase2/Phase2-Final-Report.pdf).

### Troubleshooting ladder (Extension F)

Diagnose in strict layer order; the symptom identifies the layer.

| # | Layer | Check | A failure here means |
|---|---|---|---|
| 1 | DNS | `dig app.admv.test +short` | wrong/empty answer → resolver, dnsmasq, or the record |
| 2 | IP / TCP | `nc -vz 10.7.25.158 443` | refused/timeout → network, port, firewall, edge down |
| 3 | TLS | `openssl s_client -connect 10.7.25.158:443 -servername app.admv.test` | handshake/verify error → cert path, expiry, trust |
| 4 | HTTP | `curl -s -D - https://app.admv.test/api/status` | 502 → backends down; wrong body → app/route |

`scripts/preflight.sh` walks exactly this ladder, so its first failure names the
broken layer.

---

## Security note

Private keys (`ca.key`, `server.key`) are **deliberately not in this repository**
and are excluded by `.gitignore`. Only public certificates are included. The CA
exists solely for this project and should be removed from client keychains
afterwards.

---

## Clean-up

```bash
sudo brew services stop dnsmasq                  # Mac 1, Mac 4
sudo nginx -s stop                               # Mac 2, Mac 4
sudo pfctl -a admv -F rules && sudo pfctl -d     # Mac 3, Mac 4 — then restore /etc/pf.conf
sudo networksetup -setdnsservers Wi-Fi empty     # every client
# Keychain Access → System → delete "admv Local CA"
```
