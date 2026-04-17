#!/bin/bash
# kv-push.sh — Push homelab status & stats to Cloudflare KV
# Runs every 5 min via systemd timer on CT 192 (OpenFang)
# Secrets in /opt/openfang/scripts/kv-push.env (EnvironmentFile)

set -euo pipefail

CF_ACCOUNT="c14f021007b64942165602a76b258b97"
STATUS_NS="52300c6bc4a548af882ee63b6422a471"
STATS_NS="299a7b4537b049649736e23b84753a6a"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Service definitions: name|url|category ---
# Format: name|url_or_tcp|category
# TCP checks use tcp://host:port format
SERVICES=(
  "Traefik|https://traefik.pixelium.internal|infra"
  "TechnitiumDNS|http://192.168.1.100:5380|infra"
  "TechnitiumDNS 2|http://192.168.1.101:5380|infra"
  "step-ca|https://192.168.1.102:443/health|infra"
  "Headscale|tcp://192.168.1.106:22|infra"
  "Authentik|https://authentik.pixelium.internal|infra"
  "Forgejo|https://forgejo.pixelium.internal|infra"
  "Forgejo Runner|tcp://192.168.1.178:22|infra"
  "NetBox|https://netbox.pixelium.internal|infra"
  "netboot.xyz|http://192.168.1.188:80|infra"
  "Homepage|https://homepage.pixelium.internal|apps"
  "Vaultwarden|https://vaultwarden.pixelium.internal|apps"
  "Jellyfin|https://jellyfin.pixelium.internal|apps"
  "Immich|https://immich.pixelium.internal|apps"
  "Kavita|https://kavita.pixelium.internal|apps"
  "FreshRSS|https://freshrss.pixelium.internal|apps"
  "The Lounge|https://the-lounge.pixelium.internal|apps"
  "Linkwarden|https://linkwarden.pixelium.internal|apps"
  "ByteStash|https://bytestash.pixelium.internal|apps"
  "draw.io|https://drawio.pixelium.internal|apps"
  "Excalidraw|https://excalidraw.pixelium.internal|apps"
  "Joplin Server|http://192.168.1.170:22300|apps"
  "Semaphore|https://semaphore.pixelium.internal|apps"
  "OpenFang|tcp://127.0.0.1:22|apps"
  "IronClaw|http://192.168.1.190:3000|apps"
  "Mosquitto MQTT|tcp://192.168.1.142:1883|infra"
  "Home Assistant|https://homeassistant.pixelium.internal|infra"
  "Wiki.js Infra|https://wikinfra.pixelium.internal|apps"
  "Beszel|https://beszel.pixelium.internal|monitoring"
  "Wazuh|https://wazuh.pixelium.internal|monitoring"
  "VictoriaMetrics|https://victoriametrics.pixelium.internal|monitoring"
  "Patchmon|https://patchmon.pixelium.internal|monitoring"
  "Loki|http://192.168.1.240:3100/ready|monitoring"
  "PBS|https://192.168.1.150:8007|storage"
  "share2|tcp://192.168.1.104:445|storage"
  "APT Cache|http://192.168.1.200:3142|storage"
)

# --- Ping services ---
up=0
down=0
json_services=""

for svc in "${SERVICES[@]}"; do
  IFS='|' read -r name url category <<< "$svc"
  start_ns=$(date +%s%N)
  is_up=false

  if [[ "$url" == tcp://* ]]; then
    # TCP port check
    hostport="${url#tcp://}"
    host="${hostport%%:*}"
    port="${hostport##*:}"
    if timeout 3 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
      is_up=true
    fi
  else
    # HTTP(S) check
    http_code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^[23456] ]]; then
      is_up=true
    fi
  fi

  if $is_up; then
    latency=$(( ($(date +%s%N) - start_ns) / 1000000 ))
    json_services+='{"name":"'"$name"'","status":"up","latency":'"$latency"',"category":"'"$category"'"},'
    up=$((up + 1))
  else
    json_services+='{"name":"'"$name"'","status":"down","latency":null,"category":"'"$category"'"},'
    down=$((down + 1))
  fi
done

# Remove trailing comma
json_services="${json_services%,}"
total=$((up + down))

# --- Proxmox node metrics ---
json_nodes=""

for node_info in "pve1|192.168.1.251|${PVE1_TOKEN:-}" "pve2|192.168.1.252|${PVE2_TOKEN:-}" "pve3|192.168.1.253|${PVE3_TOKEN:-}"; do
  IFS='|' read -r nname nip ntoken <<< "$node_info"

  node_data=$(curl -sk --max-time 5 \
    "https://${nip}:8006/api2/json/nodes/${nname}/status" \
    -H "Authorization: PVEAPIToken=${ntoken}" 2>/dev/null || echo "")

  cpu=$(echo "$node_data" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(round(d['cpu']*100))" 2>/dev/null || echo "")

  if [ -n "$cpu" ]; then
    ram_used=$(echo "$node_data" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(round(d['memory']['used']/d['memory']['total']*100))" 2>/dev/null || echo "0")
    uptime_days=$(echo "$node_data" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(round(d['uptime']/86400))" 2>/dev/null || echo "0")
    json_nodes+='{"name":"'"$nname"'","cpu":'"$cpu"',"ram":'"$ram_used"',"uptime_days":'"$uptime_days"'},'
  else
    # Node unreachable (off or no token)
    json_nodes+='{"name":"'"$nname"'","status":"offline"},'
  fi
done
# Remove trailing comma
json_nodes="${json_nodes%,}"

# --- Count HTTPS services (from SERVICES array) ---
https_count=0
for svc in "${SERVICES[@]}"; do
  IFS='|' read -r _name url _cat <<< "$svc"
  [[ "$url" == https://* ]] && https_count=$((https_count + 1))
done

# --- Count LXC containers (from Proxmox API) ---
lxc_count=0
for node_info in "pve1|192.168.1.251|${PVE1_TOKEN:-}" "pve2|192.168.1.252|${PVE2_TOKEN:-}" "pve3|192.168.1.253|${PVE3_TOKEN:-}"; do
  IFS='|' read -r nname nip ntoken <<< "$node_info"
  count=$(curl -sk --max-time 5 \
    "https://${nip}:8006/api2/json/nodes/${nname}/lxc" \
    -H "Authorization: PVEAPIToken=${ntoken}" 2>/dev/null | \
    python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "0")
  lxc_count=$((lxc_count + count))
done
# pve3 has 3 CTs — add statically if pve3 was unreachable (count was 0 from API)
if ! echo "$json_nodes" | grep -q '"pve3","cpu"'; then
  lxc_count=$((lxc_count + 3))
fi

# --- Ansible playbooks count (from Semaphore API) ---
ansible_playbooks=$(curl -sk --max-time 5 \
  "https://semaphore.pixelium.internal/api/project/1/templates" \
  -H "Authorization: Bearer ${SEMAPHORE_TOKEN:-}" 2>/dev/null | \
  python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "14")

# --- Ansible hosts count (from inventory on Semaphore CT 202) ---
ansible_hosts=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@192.168.1.202 \
  "grep -c ansible_host /opt/semaphore/tmp/project_1/repository_1_template_2/inventories/hosts.yml" 2>/dev/null || echo "34")

# --- Beszel agents count (from PocketBase on CT 230) ---
beszel_agents=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@192.168.1.230 \
  "sqlite3 /opt/beszel/beszel_data/data.db 'SELECT COUNT(*) FROM systems'" 2>/dev/null || echo "30")

# --- Compute uptime percentage (simple: up/total * 100) ---
if [ "$total" -gt 0 ]; then
  uptime_pct=$(python3 -c "print(round($up/$total*100, 1))")
else
  uptime_pct="0"
fi

# --- Push STATUS_KV ---
status_payload='{"ok":true,"services":['"$json_services"'],"nodes":['"$json_nodes"'],"summary":{"total":'"$total"',"up":'"$up"',"down":'"$down"',"uptime_pct":'"$uptime_pct"'},"updated_at":"'"$TIMESTAMP"'"}'

curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/storage/kv/namespaces/${STATUS_NS}/values/services" \
  -H "X-Auth-Email: ${CF_EMAIL}" \
  -H "X-Auth-Key: ${CF_KEY}" \
  -H "Content-Type: application/json" \
  -d "$status_payload" > /dev/null

# --- Push STATS_KV ---
# Forgejo commits (last 30 days) — own repos only (exclude mirrors), paginated
SINCE_DATE=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
commits_30d=$(SINCE="$SINCE_DATE" TOKEN="$FORGEJO_TOKEN" python3 << 'PYEOF'
import urllib.request, json, ssl, os
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
token = os.environ["TOKEN"]
since = os.environ["SINCE"]
base = "https://forgejo.pixelium.internal/api/v1"
total = 0
try:
    req = urllib.request.Request(f"{base}/repos/search?limit=50&token={token}")
    repos = json.loads(urllib.request.urlopen(req, context=ctx).read()).get("data", [])
    for r in repos:
        if r.get("mirror", False):
            continue
        owner = r["owner"]["login"]
        name = r["name"]
        branch = r.get("default_branch", "main")
        page = 1
        while page <= 20:
            try:
                url = f"{base}/repos/{owner}/{name}/commits?sha={branch}&since={since}&limit=50&page={page}&token={token}"
                commits = json.loads(urllib.request.urlopen(urllib.request.Request(url), context=ctx).read())
                count = len(commits) if isinstance(commits, list) else 0
                total += count
                if count < 50:
                    break
                page += 1
            except:
                break
    print(total)
except: print(0)
PYEOF
)

# Forgejo total commits (all-time, own repos) — via x-total-count header
commits_total=$(TOKEN="$FORGEJO_TOKEN" python3 << 'PYTEOF'
import urllib.request, json, ssl, os
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
token = os.environ["TOKEN"]
base = "https://forgejo.pixelium.internal/api/v1"
total = 0
try:
    req = urllib.request.Request(f"{base}/repos/search?limit=50&token={token}")
    repos = json.loads(urllib.request.urlopen(req, context=ctx).read()).get("data", [])
    for r in repos:
        if r.get("mirror", False):
            continue
        owner, name = r["owner"]["login"], r["name"]
        try:
            url = f"{base}/repos/{owner}/{name}/commits?limit=1&token={token}"
            res = urllib.request.urlopen(urllib.request.Request(url), context=ctx)
            count = int(res.headers.get("x-total-count", 0))
            total += count
        except: pass
    print(total)
except: print(0)
PYTEOF
)

# --- HTB stats (profile + activity feed) ---
read htb_flags htb_rank htb_ranking htb_system_owns htb_user_owns <<< $(TOKEN="${HTB_API_TOKEN:-}" python3 << 'HTBEOF'
import urllib.request, json, os
token = os.environ.get("TOKEN", "")
if not token:
    print("95 Hacker 972 24 26")
    raise SystemExit
headers = {"Authorization": f"Bearer {token}", "User-Agent": "kv-push/1.0"}
flags, rank, ranking, sys_owns, usr_owns = 95, "Hacker", 972, 24, 26
try:
    req = urllib.request.Request("https://labs.hackthebox.com/api/v4/user/profile/basic/1161145", headers=headers)
    d = json.loads(urllib.request.urlopen(req, timeout=10).read())
    p = d.get("profile", {})
    rank = p.get("rank", rank)
    ranking = p.get("ranking", ranking)
    sys_owns = p.get("system_owns", sys_owns)
    usr_owns = p.get("user_owns", usr_owns)
except: pass
try:
    req = urllib.request.Request("https://labs.hackthebox.com/api/v4/user/profile/activity/1161145", headers=headers)
    d = json.loads(urllib.request.urlopen(req, timeout=10).read())
    flags = len(d.get("profile", {}).get("activity", []))
except: pass
print(f"{flags} {rank} {ranking} {sys_owns} {usr_owns}")
HTBEOF
)

# --- Root-Me score (from API) ---
rootme_score=$(ROOTME_UID="${ROOTME_UID:-}" ROOTME_KEY="${ROOTME_API_KEY:-}" python3 << 'RMEOF'
import urllib.request, json, os
uid = os.environ.get("ROOTME_UID", "")
key = os.environ.get("ROOTME_KEY", "")
if not uid or not key:
    print(765)
    raise SystemExit
try:
    req = urllib.request.Request(f"https://api.www.root-me.org/auteurs/{uid}")
    req.add_header("Cookie", f"api_key={key}")
    d = json.loads(urllib.request.urlopen(req, timeout=10).read())
    print(d.get("score", 765))
except:
    print(765)
RMEOF
)

# Journal entries count (### headings in latest journal files)
journal_entries=$(TOKEN="$FORGEJO_TOKEN" python3 << 'PYJEOF'
import urllib.request, json, ssl, os
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
token = os.environ["TOKEN"]
base = "https://forgejo.pixelium.internal/api/v1"
total = 0
try:
    for month in ["2026-01", "2026-02", "2026-03", "2026-04"]:
        url = f"{base}/repos/uzer/homelab-infra/raw/journal/{month}.md?token={token}"
        try:
            text = urllib.request.urlopen(urllib.request.Request(url), context=ctx).read().decode()
            total += text.count("\n### ")
        except: pass
    print(total)
except: print(0)
PYJEOF
)

stats_payload='{"ok":true,"stats":{"services_up":'"$up"',"services_total":'"$total"',"uptime_pct":'"$uptime_pct"',"forgejo_commits_30d":'"$commits_30d"',"forgejo_commits_total":'"$commits_total"',"journal_entries":'"$journal_entries"',"proxmox_nodes":2,"htb_flags":'"$htb_flags"',"htb_rank":"'"$htb_rank"'","htb_ranking":'"$htb_ranking"',"htb_system_owns":'"$htb_system_owns"',"htb_user_owns":'"$htb_user_owns"',"rootme_score":'"$rootme_score"',"ansible_playbooks":'"$ansible_playbooks"',"lxc_count":'"$lxc_count"',"https_services":'"$https_count"',"ansible_hosts":'"$ansible_hosts"',"beszel_agents":'"$beszel_agents"'},"updated_at":"'"$TIMESTAMP"'"}'

curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/storage/kv/namespaces/${STATS_NS}/values/stats" \
  -H "X-Auth-Email: ${CF_EMAIL}" \
  -H "X-Auth-Key: ${CF_KEY}" \
  -H "Content-Type: application/json" \
  -d "$stats_payload" > /dev/null

# --- Record history snapshot (D1, hourly dedup server-side) ---
if [ -n "${HISTORY_KEY:-}" ]; then
  history_res=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "https://pixelium.win/api/history/record" \
    -H "X-History-Key: ${HISTORY_KEY}" \
    -H "Content-Type: application/json" 2>/dev/null || echo "000")
  history_msg=""
  [ "$history_res" = "200" ] && history_msg=" — history OK"
  [ "$history_res" = "401" ] && history_msg=" — history AUTH FAIL"
fi

echo "[$(date -u +%H:%M:%S)] KV push: ${up}/${total} UP (${uptime_pct}%) — ${down} down${history_msg:-}"
