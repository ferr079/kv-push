# kv-push

Push homelab infrastructure metrics to Cloudflare KV namespaces — powers a live status dashboard on a static site.

## What it does

Runs every 5 minutes via systemd timer, collecting metrics from multiple sources and pushing them to two Cloudflare KV namespaces:

- **Status KV**: service availability (HTTP checks, TCP checks, Proxmox node status)
- **Stats KV**: infrastructure metrics (LXC count, HTTPS services, commits, flags, etc.)

## Metrics collected (15)

| Metric | Source |
|---|---|
| `services_up` / `services_total` | HTTP/TCP checks against all services |
| `uptime_pct` | Calculated from services_up/total |
| `proxmox_nodes` | Proxmox API (CPU, RAM, uptime per node) |
| `lxc_count` | Proxmox API (total LXC containers) |
| `https_services` | Count of Traefik-proxied services |
| `ansible_playbooks` | Semaphore API |
| `ansible_hosts` | Semaphore SSH key count |
| `forgejo_commits_30d` / `total` | Forgejo API (paginated, excluding mirrors) |
| `journal_entries` | Ops journal markdown heading count |
| `beszel_agents` | Beszel SQLite DB |
| `htb_flags` | HackTheBox API activity feed |
| `rootme_score` | Root-Me API |
| `blog_articles` | Forgejo API (content listing) |

## Setup

1. Copy `kv-push.env.example` to `kv-push.env` and fill in your API tokens
2. Edit `kv-push.sh` — update `CF_ACCOUNT`, KV namespace IDs, and service definitions
3. Deploy as a systemd timer or cron job

```bash
# Test run
source kv-push.env && ./kv-push.sh

# Cron (every 5 min)
*/5 * * * * /opt/scripts/kv-push.sh
```

## Requirements

- Bash 4+, `curl`, `jq`
- Cloudflare account with KV namespaces
- API tokens for your infrastructure services

## License

MIT
