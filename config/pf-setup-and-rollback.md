# Extension C — firewall install and rollback

The project brief requires a rollback copy of any firewall rules and a restore
after the demonstration. Follow this exactly on each backend laptop.

- Backend A = Ashish, `10.7.29.240`, port 3001 -> use `pf-backend-a.anchor`
- Backend B = Dikshant, `10.7.24.165`, port 3002 -> use `pf-backend-b.anchor`

## 1. Back up the existing config FIRST

```bash
sudo cp /etc/pf.conf ~/pf.conf.backup-$(date +%Y%m%d)
ls -l ~/pf.conf.backup-*          # confirm the backup exists before continuing
```

## 2. Install the anchor file

```bash
# on Backend A:
sudo cp config/pf-backend-a.anchor /etc/pf.anchors/admv
# on Backend B:
sudo cp config/pf-backend-b.anchor /etc/pf.anchors/admv
```

## 3. Register the anchor in /etc/pf.conf

Append these two lines to `/etc/pf.conf`:

```
anchor "admv"
load anchor "admv" from "/etc/pf.anchors/admv"
```

## 4. Load and enable

```bash
sudo pfctl -f /etc/pf.conf      # parse + load; errors print here
sudo pfctl -E                   # enable pf (prints an Enable Reference token)
sudo pfctl -a admv -s rules     # verify: should list your pass/block rules
```

## 5. Verify the rules do what they claim

```bash
# From the EDGE (10.7.25.158) — must SUCCEED:
curl -s -m3 http://10.7.29.240:3001/api/status

# From a NON-edge client (e.g. Vaibhav 10.7.3.140) — must TIME OUT:
curl -s -m3 -o /dev/null -w '%{http_code}\n' http://10.7.29.240:3001/api/status
# expect: 000, and curl exit code 28
```

Both halves matter. Showing only the refusal does not prove the edge still works.

## 6. Rollback after the demonstration

```bash
sudo pfctl -a admv -F rules            # flush just our anchor
sudo pfctl -d                          # disable pf
sudo cp ~/pf.conf.backup-YYYYMMDD /etc/pf.conf   # restore the original
sudo pfctl -f /etc/pf.conf             # reload the restored config
```

## Why a timeout and not "connection refused"

`block drop` discards the packet without replying. The client waits for a
response that never comes and gives up — curl exit 28. If the rule were
`block return`, pf would send a TCP RST and curl would report "connection
refused" instantly. Worth being able to state the difference in the viva: a
drop hides that the service exists at all, a reset admits it and declines.
