# kv-push

Push homelab infrastructure metrics to Cloudflare KV — the data behind a live status dashboard on an otherwise static site.

One shell script, run on a timer inside the LAN. It probes what only a machine on the inside can see, writes two JSON blobs to KV, and a Worker serves them to the public site. Nothing is exposed, nothing is polled from the outside.

## What it does

Each run writes two keys:

- **Status KV** — per-service availability (HTTP status-code checks, TCP port checks) plus Proxmox node CPU / RAM / uptime
- **Stats KV** — aggregate figures: LXC count, HTTPS-exposed services, forge commits, CTF progress, Ansible templates

## Metrics

| Key | Source | Requires |
|---|---|---|
| `services_up` / `services_total` / `uptime_pct` | HTTP + TCP checks from `services.conf` | — |
| `https_services` | count of `https://` entries in `services.conf` | — |
| `proxmox_nodes` / `lxc_count` | Proxmox API (`/nodes/*/status`, `/nodes/*/lxc`) | `PVE_NODES` |
| `forgejo_commits_30d` / `forgejo_commits_total` | Forgejo API, own repos only (mirrors excluded) | `FORGEJO_URL` + `FORGEJO_TOKEN` |
| `htb_rank` / `htb_ranking` / `htb_system_owns` / `htb_user_owns` / `htb_flags` | Hack The Box profile API | `HTB_API_TOKEN` + `HTB_USER_ID` |
| `rootme_score` | Root-Me API | `ROOTME_UID` + `ROOTME_API_KEY` |
| `ansible_playbooks` | Semaphore API (job templates) | `SEMAPHORE_URL` + `SEMAPHORE_TOKEN` |

Every collector is optional: leave its variables unset and it is skipped.

## Two design rules worth stealing

**Omit on failure, never substitute.** When a collector fails, its key is left *out* of the payload instead of being published as `0` or a hardcoded constant. The consumer then keeps the last value it knew. A hardcoded fallback is worse than a gap: it looks alive and it lies — this script used to print a frozen Root-Me score for weeks before that was noticed.

**A powered-off node is not a failed run.** Nodes that do not answer are reported `offline` and the run continues. Wake-on-LAN backup nodes are meant to be asleep most of the time.

## Setup

```bash
sudo install -m 755 kv-push.sh /usr/local/bin/kv-push
sudo mkdir -p /etc/kv-push
sudo cp services.conf.example /etc/kv-push/services.conf   # your services
sudo cp kv-push.env.example  /etc/kv-push/kv-push.env      # your tokens
sudo chmod 600 /etc/kv-push/kv-push.env

# Test run — prints both payloads instead of writing them
set -a; source /etc/kv-push/kv-push.env; set +a; DRY_RUN=1 kv-push
```

Then schedule it — systemd timer or cron:

```cron
*/15 * * * * root . /etc/kv-push/kv-push.env && /usr/local/bin/kv-push >> /var/log/kv-push.log 2>&1
```

Every 15 minutes is enough for a status page: pick a period from how fast the dashboard has to react, not from how cheap the run is.

## Cloudflare token

Use a **scoped** API token — *Workers KV Storage: Edit*, restricted to the two namespaces. The legacy Global API Key grants the whole account and is being retired; this script no longer accepts it.

## Requirements

- Bash 4+, `curl`, `python3` (stdlib only)
- A Cloudflare account with two KV namespaces
- Read-only API tokens for whichever sources you enable

Service checks use `curl -k`: internal services usually sit behind a private CA, and this is an availability probe, not a certificate audit. Certificate expiry is a separate job — see [cert-check](https://github.com/ferr079/cert-check).

## License

MIT
