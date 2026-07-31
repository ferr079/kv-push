#!/bin/bash
# kv-push.sh — Push homelab status & stats to Cloudflare KV
#
# Reads its whole configuration from the environment (see kv-push.env.example)
# and a services file, so this script can be dropped on any host without edits.
#
#   set -a; source /etc/kv-push/kv-push.env; set +a
#   ./kv-push.sh
#
# Every optional collector is skipped when its variables are unset: what cannot
# be measured is omitted from the payload rather than published as a stale
# constant — a dashboard showing nothing beats a dashboard showing a lie.

set -euo pipefail

# --- Required configuration ---------------------------------------------------
: "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID is required}"
: "${CF_API_TOKEN:?CF_API_TOKEN is required (scoped token, not the Global API Key)}"
: "${CF_STATUS_NAMESPACE_ID:?CF_STATUS_NAMESPACE_ID is required}"
: "${CF_STATS_NAMESPACE_ID:?CF_STATS_NAMESPACE_ID is required}"

SERVICES_FILE="${SERVICES_FILE:-/etc/kv-push/services.conf}"
TIMEOUT="${CHECK_TIMEOUT:-5}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

CF_API="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces"

# --- Service definitions ------------------------------------------------------
# One service per line in $SERVICES_FILE: name|url|category
# URLs may be http(s):// for a status-code check, or tcp://host:port for a port
# check. Lines starting with # and blank lines are ignored.
#
#   Forgejo|https://forgejo.example.lab|infra
#   Postgres|tcp://10.0.0.20:5432|storage

if [ ! -r "$SERVICES_FILE" ]; then
  echo "kv-push: services file not found: $SERVICES_FILE" >&2
  echo "kv-push: copy services.conf.example and adapt it" >&2
  exit 1
fi

mapfile -t SERVICES < <(grep -vE '^\s*(#|$)' "$SERVICES_FILE")

# --- Ping services ------------------------------------------------------------
up=0
down=0
json_services=""

for svc in "${SERVICES[@]}"; do
  IFS='|' read -r name url category <<< "$svc"
  start_ns=$(date +%s%N)
  is_up=false

  if [[ "$url" == tcp://* ]]; then
    hostport="${url#tcp://}"
    host="${hostport%%:*}"
    port="${hostport##*:}"
    if timeout "$TIMEOUT" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
      is_up=true
    fi
  else
    http_code=$(curl -sk --max-time "$TIMEOUT" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    # 2xx-6xx: the service answered. Only a connection failure counts as down.
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

json_services="${json_services%,}"
total=$((up + down))

# --- Proxmox nodes ------------------------------------------------------------
# PVE_NODES holds one "name|host|api_token" per line:
#   PVE_NODES="pve1|10.0.0.11|user@pam!kvpush=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   pve2|10.0.0.12|user@pam!kvpush=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
json_nodes=""
node_count=0
lxc_count=0
lxc_seen=false

if [ -n "${PVE_NODES:-}" ]; then
  while IFS='|' read -r nname nhost ntoken; do
    [ -z "${nname:-}" ] && continue
    node_count=$((node_count + 1))

    node_data=$(curl -sk --max-time "$TIMEOUT" \
      "https://${nhost}:8006/api2/json/nodes/${nname}/status" \
      -H "Authorization: PVEAPIToken=${ntoken}" 2>/dev/null || echo "")

    cpu=$(echo "$node_data" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(round(d['cpu']*100))" 2>/dev/null || echo "")

    if [ -n "$cpu" ]; then
      ram_used=$(echo "$node_data" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(round(d['memory']['used']/d['memory']['total']*100))" 2>/dev/null || echo "0")
      uptime_days=$(echo "$node_data" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(round(d['uptime']/86400))" 2>/dev/null || echo "0")
      json_nodes+='{"name":"'"$nname"'","cpu":'"$cpu"',"ram":'"$ram_used"',"uptime_days":'"$uptime_days"'},'

      count=$(curl -sk --max-time "$TIMEOUT" \
        "https://${nhost}:8006/api2/json/nodes/${nname}/lxc" \
        -H "Authorization: PVEAPIToken=${ntoken}" 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "")
      if [ -n "$count" ]; then
        lxc_count=$((lxc_count + count))
        lxc_seen=true
      fi
    else
      # Unreachable: powered off (on-demand node), no token, or genuinely down.
      json_nodes+='{"name":"'"$nname"'","status":"offline"},'
    fi
  done <<< "$PVE_NODES"
fi

json_nodes="${json_nodes%,}"

# --- Count HTTPS-exposed services ---------------------------------------------
https_count=0
for svc in "${SERVICES[@]}"; do
  IFS='|' read -r _name url _cat <<< "$svc"
  [[ "$url" == https://* ]] && https_count=$((https_count + 1))
done

# --- Uptime percentage --------------------------------------------------------
if [ "$total" -gt 0 ]; then
  uptime_pct=$(python3 -c "print(round($up/$total*100, 1))")
else
  uptime_pct="0"
fi

# --- Push STATUS_KV -----------------------------------------------------------
# DRY_RUN=1 prints the payloads instead of writing them, so a run can be
# inspected before it touches the dashboard.
kv_put() {
  local namespace="$1" key="$2" payload="$3"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s → %s\n%s\n\n' "$namespace" "$key" "$payload"
    return
  fi
  curl -s -X PUT \
    "${CF_API}/${namespace}/values/${key}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" > /dev/null
}

status_payload='{"ok":true,"services":['"$json_services"'],"nodes":['"$json_nodes"'],"summary":{"total":'"$total"',"up":'"$up"',"down":'"$down"',"uptime_pct":'"$uptime_pct"'},"updated_at":"'"$TIMESTAMP"'"}'

kv_put "$CF_STATUS_NAMESPACE_ID" "${CF_STATUS_KEY:-services}" "$status_payload"

# --- Optional collectors ------------------------------------------------------
# Each one prints nothing when it cannot measure; empty values are dropped from
# the stats payload below instead of being replaced by a hardcoded fallback.

# Forgejo: commits over the last 30 days and all-time, own repos only
commits_30d=""
commits_total=""
if [ -n "${FORGEJO_URL:-}" ] && [ -n "${FORGEJO_TOKEN:-}" ]; then
  SINCE_DATE=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  read -r commits_30d commits_total <<< "$(
    SINCE="$SINCE_DATE" TOKEN="$FORGEJO_TOKEN" BASE="$FORGEJO_URL" \
    VERIFY="${FORGEJO_TLS_VERIFY:-1}" python3 << 'PYEOF' || true
import urllib.request, json, ssl, os
ctx = ssl.create_default_context()
if os.environ.get("VERIFY") != "1":
    # Internal CA not trusted by this host: opt-in only, never the default.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
token = os.environ["TOKEN"]
since = os.environ.get("SINCE", "")
base = os.environ["BASE"].rstrip("/") + "/api/v1"
recent = alltime = 0
try:
    req = urllib.request.Request(f"{base}/repos/search?limit=50", headers={"Authorization": f"token {token}"})
    repos = json.loads(urllib.request.urlopen(req, context=ctx, timeout=15).read()).get("data", [])
    for r in repos:
        if r.get("mirror", False):
            continue
        owner, name = r["owner"]["login"], r["name"]
        branch = r.get("default_branch", "main")
        try:
            url = f"{base}/repos/{owner}/{name}/commits?limit=1"
            res = urllib.request.urlopen(
                urllib.request.Request(url, headers={"Authorization": f"token {token}"}), context=ctx, timeout=15)
            alltime += int(res.headers.get("x-total-count", 0))
        except Exception:
            pass
        if not since:
            continue
        page = 1
        while page <= 20:
            try:
                url = f"{base}/repos/{owner}/{name}/commits?sha={branch}&since={since}&limit=50&page={page}"
                commits = json.loads(urllib.request.urlopen(
                    urllib.request.Request(url, headers={"Authorization": f"token {token}"}),
                    context=ctx, timeout=15).read())
                count = len(commits) if isinstance(commits, list) else 0
                recent += count
                if count < 50:
                    break
                page += 1
            except Exception:
                break
    print(recent, alltime)
except Exception:
    pass
PYEOF
  )"
fi

# Hack The Box: flags = user owns + system owns.
# The /activity endpoint was removed by HTB in 2026 — do not reintroduce it.
htb_rank=""
htb_ranking=""
htb_system_owns=""
htb_user_owns=""
htb_flags=""
if [ -n "${HTB_API_TOKEN:-}" ] && [ -n "${HTB_USER_ID:-}" ]; then
  read -r htb_rank htb_ranking htb_system_owns htb_user_owns htb_flags <<< "$(
    TOKEN="$HTB_API_TOKEN" UID_="$HTB_USER_ID" python3 << 'HTBEOF' || true
import urllib.request, json, os
token, uid = os.environ["TOKEN"], os.environ["UID_"]
headers = {"Authorization": f"Bearer {token}", "User-Agent": "kv-push/2.0"}
try:
    req = urllib.request.Request(
        f"https://labs.hackthebox.com/api/v4/user/profile/basic/{uid}", headers=headers)
    p = json.loads(urllib.request.urlopen(req, timeout=10).read()).get("profile", {})
    sys_owns, usr_owns = int(p.get("system_owns", 0)), int(p.get("user_owns", 0))
    print(p.get("rank", ""), p.get("ranking", ""), sys_owns, usr_owns, sys_owns + usr_owns)
except Exception:
    pass
HTBEOF
  )"
fi

# Root-Me: the API throttles the default python-urllib agent with a 429,
# so an explicit User-Agent is mandatory, not cosmetic.
rootme_score=""
if [ -n "${ROOTME_UID:-}" ] && [ -n "${ROOTME_API_KEY:-}" ]; then
  rootme_score=$(
    UID_="$ROOTME_UID" KEY="$ROOTME_API_KEY" python3 << 'RMEOF' || true
import urllib.request, json, os
uid, key = os.environ["UID_"], os.environ["KEY"]
try:
    req = urllib.request.Request(
        f"https://api.www.root-me.org/auteurs/{uid}",
        headers={"User-Agent": "kv-push/2.0", "Accept": "application/json"})
    req.add_header("Cookie", f"api_key={key}")
    d = json.loads(urllib.request.urlopen(req, timeout=10).read())
    score = d.get("score")
    if score is not None:
        print(score)
except Exception:
    pass
RMEOF
  )
fi

# Semaphore: number of Ansible job templates
ansible_playbooks=""
if [ -n "${SEMAPHORE_URL:-}" ] && [ -n "${SEMAPHORE_TOKEN:-}" ]; then
  ansible_playbooks=$(curl -sk --max-time "$TIMEOUT" \
    "${SEMAPHORE_URL%/}/api/project/${SEMAPHORE_PROJECT_ID:-1}/templates" \
    -H "Authorization: Bearer ${SEMAPHORE_TOKEN}" 2>/dev/null | \
    python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || true)
fi

# --- Push STATS_KV ------------------------------------------------------------
stats_payload=$(
  UP="$up" TOTAL="$total" UPTIME="$uptime_pct" HTTPS="$https_count" \
  NODES="$node_count" LXC="$([ "$lxc_seen" = true ] && echo "$lxc_count")" \
  C30="$commits_30d" CALL="$commits_total" \
  HTB_RANK="$htb_rank" HTB_RANKING="$htb_ranking" HTB_SYS="$htb_system_owns" \
  HTB_USR="$htb_user_owns" HTB_FLAGS="$htb_flags" ROOTME="$rootme_score" \
  PLAYBOOKS="$ansible_playbooks" TS="$TIMESTAMP" python3 << 'JSONEOF'
import json, os

def num(key):
    raw = os.environ.get(key, "").strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        try:
            return float(raw)
        except ValueError:
            return None

stats = {
    "services_up": num("UP"),
    "services_total": num("TOTAL"),
    "uptime_pct": num("UPTIME"),
    "https_services": num("HTTPS"),
    "proxmox_nodes": num("NODES") or None,
    "lxc_count": num("LXC"),
    "forgejo_commits_30d": num("C30"),
    "forgejo_commits_total": num("CALL"),
    "htb_rank": os.environ.get("HTB_RANK") or None,
    "htb_ranking": num("HTB_RANKING"),
    "htb_system_owns": num("HTB_SYS"),
    "htb_user_owns": num("HTB_USR"),
    "htb_flags": num("HTB_FLAGS"),
    "rootme_score": num("ROOTME"),
    "ansible_playbooks": num("PLAYBOOKS"),
}
# Omit-on-failure: a key absent from the payload lets the consumer keep the last
# known value, whereas a zero would overwrite it with a wrong one.
stats = {k: v for k, v in stats.items() if v is not None}
print(json.dumps({"ok": True, "stats": stats, "updated_at": os.environ["TS"]}))
JSONEOF
)

kv_put "$CF_STATS_NAMESPACE_ID" "${CF_STATS_KEY:-stats}" "$stats_payload"

# --- Optional: history snapshot endpoint --------------------------------------
history_msg=""
if [ -n "${HISTORY_URL:-}" ] && [ -n "${HISTORY_KEY:-}" ]; then
  history_res=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$HISTORY_URL" \
    -H "X-History-Key: ${HISTORY_KEY}" \
    -H "Content-Type: application/json" 2>/dev/null || echo "000")
  [ "$history_res" = "200" ] && history_msg=" — history OK"
  [ "$history_res" != "200" ] && history_msg=" — history HTTP ${history_res}"
fi

echo "[$(date -u +%H:%M:%S)] KV push: ${up}/${total} UP (${uptime_pct}%) — ${down} down${history_msg}"
