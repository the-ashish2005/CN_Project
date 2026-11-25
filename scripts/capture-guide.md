# Task G — packet capture guide

This is the only evidence nobody can prepare for you: the three captures have
to come off a real interface on your LAN. Budget **10 minutes**.

It produces the three files the README's evidence index expects:

| File | Where | Shows |
|---|---|---|
| `G1-client-tls12.pcapng` | a client Mac | DNS + TCP handshake + full TLS 1.2 handshake, **certificate visible** |
| `G2-client-tls13.pcapng` | a client Mac | the same request on TLS 1.3, **certificate encrypted** |
| `G3-edge-to-backend.pcap` | the edge Mac | plain HTTP after TLS termination |

Save all three into `evidence/phase1/G-captures/`.

Why two client captures: in TLS 1.2 the server's certificate crosses the wire
in cleartext, so you can literally click it in Wireshark. In TLS 1.3 everything
after ServerHello is encrypted, so the certificate is **not** visible. Showing
both is the cleanest way to demonstrate that you understand what TLS 1.3
actually changed — and it is a very likely viva question.

---

## Before you start

Bring the whole system up and confirm it is healthy:

```bash
bash scripts/preflight.sh      # must be all-OK before capturing
```

Install Wireshark if needed (gives you `tshark` too):

```bash
brew install --cask wireshark
```

---

## Capture G1 — TLS 1.2, certificate visible

Run on a **client** Mac (Vaibhav's or Ashish's). Two terminals.

**Terminal 1 — start the capture.** The filter keeps the file small by limiting
it to traffic with the DNS server and the edge:

```bash
cd evidence/phase1/G-captures

sudo tshark -i en0 -w G1-client-tls12.pcapng \
  -f "host 10.7.3.140 or host 10.7.25.158"
```

**Terminal 2 — flush the DNS cache, then make one clean request.** The flush
matters: without it macOS answers from cache and **no DNS packet is ever sent**,
which is the single most common reason this capture comes out missing its DNS
query.

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
sleep 1
curl -v --tlsv1.2 --tls-max 1.2 https://app.admv.test/api/status
```

Go back to Terminal 1 and press **Ctrl-C**.

Save the `curl -v` output from Terminal 2 as well — it is your HTTP-headers
evidence and pairs with the capture:

```bash
curl -v --tlsv1.2 --tls-max 1.2 https://app.admv.test/api/status \
  > ../E-tls/E-curl-verbose-tls12.txt 2>&1
```

## Capture G2 — TLS 1.3, certificate encrypted

Same shape, forcing 1.3:

```bash
# Terminal 1
sudo tshark -i en0 -w G2-client-tls13.pcapng \
  -f "host 10.7.3.140 or host 10.7.25.158"

# Terminal 2
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
sleep 1
curl -v --tlsv1.3 https://app.admv.test/api/status
```

## Capture G3 — edge to backend, in the clear

Run on the **edge** Mac (Mukul's). This proves TLS really is terminated at the
edge: traffic onward to the backends is unencrypted HTTP.

```bash
# Terminal 1 (on the edge)
sudo tshark -i en0 -w G3-edge-to-backend.pcap \
  -f "tcp port 3001 or tcp port 3002"

# Terminal 2 (from any client) — generate some load
for i in $(seq 1 10); do curl -s https://app.admv.test/api/status > /dev/null; done
```

---

## What to point at during the demo

Open the capture and use these display filters (type them in the bar at the top
of Wireshark — these are *display* filters, different from the `-f` capture
filters above).

### DNS — Task G row 1

```
dns
```
Two packets: your query for `app.admv.test`, and the response carrying
`10.7.25.158`. Click the response and expand *Answers* to show the A record and
its TTL of 30. Note the transport in the packet detail: **UDP port 53**.

### TCP three-way handshake — row 2

```
tcp.flags.syn == 1
```
You should see SYN then SYN-ACK. Clear the filter and look at the three packets
together: **SYN → SYN-ACK → ACK**, all before a single byte of application data.
In the packet list, read off the **source port** (an ephemeral high-numbered
port, usually 49152-65535) and the **destination port 443**. That is your
socket pair, and it answers the "Port Identification" row directly.

### TLS handshake — row 3

```
tls.handshake
```
In **G1** you will see, in order:

| Filter | Packet |
|---|---|
| `tls.handshake.type == 1` | ClientHello — offered ciphers, SNI = `app.admv.test` |
| `tls.handshake.type == 2` | ServerHello — the chosen cipher |
| `tls.handshake.type == 11` | **Certificate** — expand it; `CN=app.admv.test`, issuer `admv Local CA` |
| `tls.record.content_type == 20` | ChangeCipherSpec — everything after this is encrypted |

Now open **G2** and apply `tls.handshake.type == 11`. **Zero packets.** That is
the point: TLS 1.3 encrypts the certificate. Say so out loud — it shows you know
the difference rather than having memorised a packet list.

### Application data is encrypted — row 4

```
tls.record.content_type == 23
```
Click one, then *Follow → TLS Stream*. It is unreadable bytes. Your `curl -v`
output shows the same exchange in plaintext **because curl prints it before
encryption**, not because it crosses the wire that way. That contrast is the
clearest way to answer "why is the payload encrypted in the capture?".

### Load balancing — row 5

Not in the capture (it is inside TLS). Show it from `curl` instead:
`evidence/phase1/D-loadbalancing/D-round-robin.txt`, or live from
`scripts/preflight.sh`.

### TLS terminated at the edge

Open **G3** and filter:

```
http
```
Readable HTTP requests and responses to ports 3001/3002, with the `X-Backend`
header in plain sight. Encrypted on the client side, cleartext behind the edge —
one picture that explains what "TLS termination" means.

---

## Quick self-check

Before committing, confirm each file contains what it should:

```bash
cd evidence/phase1/G-captures

tshark -r G1-client-tls12.pcapng -Y "dns" | wc -l                      # expect >= 2
tshark -r G1-client-tls12.pcapng -Y "tcp.flags.syn==1" | wc -l         # expect >= 2
tshark -r G1-client-tls12.pcapng -Y "tls.handshake.type==11" | wc -l   # expect >= 1  (certificate)
tshark -r G2-client-tls13.pcapng -Y "tls.handshake.type==11" | wc -l   # expect 0     (encrypted)
tshark -r G3-edge-to-backend.pcap -Y "http" | wc -l                    # expect >= 10
```

If the DNS count is 0, the cache was not flushed — redo the capture.

## Troubleshooting

**No DNS packets.** The cache was warm. Flush it, and make sure the browser is
closed (Safari and Chrome both keep their own resolver caches).

**tshark: permission denied on en0.** Run with `sudo`, or run the
`Install ChmodBPF` package that ships inside the Wireshark app bundle.

**TLS 1.2 refused.** Confirm `ssl_protocols TLSv1.2 TLSv1.3;` is present in the
edge config and that nginx was reloaded after any change.

**Capture is enormous.** The `-f` capture filter was dropped. Keep it — it is
what limits the file to the hosts you care about.
