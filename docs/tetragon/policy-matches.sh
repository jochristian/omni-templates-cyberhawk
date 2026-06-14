#!/usr/bin/env bash
#
# policy-matches.sh — human-friendly view of Tetragon TracingPolicy *matches*.
#
# Our policies run in monitor (observe-only) mode; every match is emitted as a
# `process_kprobe` event. This tool shows them, either as recent history or as a
# live stream.
#
# Two history sources:
#   pods (default)  greps each agent's JSON export log (in-pod, EPHEMERAL — the
#                   export dir is an emptyDir, wiped on pod/node restart).
#   loki (--loki)   queries Loki (job="tetragon"), the DURABLE store fed by Alloy.
#                   Survives restarts and reaches back days; use --since to widen.
# Live follow (-f) always streams from the agents (Loki has no detail you'd tail).
#
# Usage:
#   docs/tetragon/policy-matches.sh                 # last 50 matches (in-pod logs)
#   docs/tetragon/policy-matches.sh 100             # last 100 matches
#   docs/tetragon/policy-matches.sh --loki          # last 50 from Loki (7d window)
#   docs/tetragon/policy-matches.sh --loki --since 30d 500
#   docs/tetragon/policy-matches.sh --loki --hook setuid-root
#   docs/tetragon/policy-matches.sh -f              # live follow (Ctrl-C to stop)
#   docs/tetragon/policy-matches.sh --ns media 200  # only events from namespace 'media'
#
# Options:
#   -f, --follow        live stream instead of history (always via agents)
#   --loki              read history from Loki instead of the in-pod export logs
#   --source pods|loki  same, explicit form (default: pods)
#   --since DUR         Loki look-back window, e.g. 30m 24h 7d (default 7d)
#   -n, --num N         number of history records (default 50; ignored with -f)
#   --hook LABEL        filter by hook: file-write file-mmap-write file-truncate
#                       kmod-request kmod-read kmod-load kmod-unload setuid-root
#   --ns NAMESPACE      filter by the workload's Kubernetes namespace
#   --host              also show host/runtime (<host>) events (default: in-pod only)
#   -h, --help          this help
#
# Note: host/runtime events (e.g. runc calling setuid(0) on every container start)
# are benign noise and hidden by default; --host includes them (mainly affects -f).
#
# Env: TETRAGON_NS (agents' namespace, default 'tetragon'), MONITORING_NS (Loki's
# namespace, default 'monitoring'), NO_COLOR.
# Read-only. Requires kubectl + python3. --loki port-forwards svc/loki briefly.
# Not a GitOps manifest — ArgoCD ignores it.
set -euo pipefail

NS="${TETRAGON_NS:-tetragon}"
MON_NS="${MONITORING_NS:-monitoring}"
NUM=50
FOLLOW=0
HOOK=""
WLNS=""
HOST=0          # 0 = in-pod only (default); 1 = also show host/runtime events
SOURCE=pods     # pods (in-pod export logs) | loki (durable store)
SINCE=7d        # Loki look-back window

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--follow) FOLLOW=1 ;;
    --loki)      SOURCE=loki ;;
    --source)    SOURCE="$2"; shift ;;
    --since)     SINCE="$2"; shift ;;
    -n|--num)    NUM="$2"; shift ;;
    --hook)      HOOK="$2"; shift ;;
    --ns)        WLNS="$2"; shift ;;
    --host)      HOST=1 ;;
    -h|--help)   sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    ''|*[!0-9]*) echo "unknown arg: $1" >&2; exit 2 ;;
    *)           NUM="$1" ;;   # bare number => history count
  esac
  shift
done

case "$SOURCE" in pods|loki) ;; *) echo "bad --source: $SOURCE (pods|loki)" >&2; exit 2 ;; esac

# Convert --since (30m / 24h / 7d, or bare seconds) to seconds for the Loki window.
case "$SINCE" in
  *m) SINCE_SECS=$(( ${SINCE%m} * 60 )) ;;
  *h) SINCE_SECS=$(( ${SINCE%h} * 3600 )) ;;
  *d) SINCE_SECS=$(( ${SINCE%d} * 86400 )) ;;
  *[!0-9]*) echo "bad --since: $SINCE (use e.g. 30m, 24h, 7d)" >&2; exit 2 ;;
  *) SINCE_SECS="$SINCE" ;;
esac

# Active log is tetragon.log; Tetragon rotates to tetragon-<timestamp>.log (NOT
# .log.N), so this glob must match both. Export dir is an emptyDir, so only the
# few most-recent rotated files survive and everything is lost on pod restart.
LOG="/var/run/cilium/tetragon/tetragon*.log"   # active + rotated backups
PYF="$(mktemp --suffix=.py)"
LOKIPY="$(mktemp --suffix=.py)"
TMP="$(mktemp)"
PIDS=()
cleanup() {
  rm -f "$PYF" "$LOKIPY" "$TMP"
  [ ${#PIDS[@]} -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null || true   # only OUR children
}
trap cleanup EXIT INT TERM

# ---- shared Python formatter -------------------------------------------------
cat > "$PYF" <<'PY'
import json, os, sys

MODE = sys.argv[1]                       # "batch" | "follow"
NUM  = int(sys.argv[2])
HOOK = sys.argv[3]                       # "" = any
WLNS = sys.argv[4]                       # "" = any
HOST = sys.argv[5] == "1"                # include host/runtime (<host>) events?

COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
def c(s, code): return f"\033[{code}m{s}\033[0m" if COLOR else s
DIM=lambda s:c(s,"2"); BOLD=lambda s:c(s,"1")
def hue(cat,s):
    return c(s, {"file":"33","priv":"31","kmod":"35"}.get(cat,"37"))

LABELS = {
    "security_file_permission":"file-write","security_mmap_file":"file-mmap-write",
    "security_path_truncate":"file-truncate","security_kernel_module_request":"kmod-request",
    "security_kernel_read_file":"kmod-read","do_init_module":"kmod-load","free_module":"kmod-unload",
}
EMOJI={"file":"📝","priv":"🔺","kmod":"🧩"}
def label(fn):
    if fn in LABELS: return LABELS[fn]
    if fn.startswith("__sys_set"): return "setuid-root"
    return None
def category(lab):
    if lab.startswith("file"): return "file"
    if lab.startswith("kmod"): return "kmod"
    return "priv"

FILEBITS=[(1,"exec"),(2,"write"),(4,"read"),(8,"append")]
def detail(kp, lab):
    args=kp.get("args",[])
    path=None; note=None; sval=None; ival=None
    for a in args:
        if a.get("file_arg",{}).get("path"): path=a["file_arg"]["path"]
        elif a.get("path_arg",{}).get("path"): path=a["path_arg"]["path"]
        elif "module_arg" in a: sval=a.get("module_arg") if isinstance(a.get("module_arg"),str) else (a["module_arg"].get("name") if isinstance(a.get("module_arg"),dict) else None)
        elif "string_arg" in a and sval is None: sval=str(a["string_arg"])
        elif "int_arg" in a and ival is None: ival=a["int_arg"]
    if lab.startswith("file"):
        if ival is not None:
            bits=[n for b,n in FILEBITS if ival & b] or [str(ival)]
            note="/".join(bits)
        elif lab=="file-truncate": note="truncate"
        return f"{path or '?'} [{note or 'access'}]"
    if lab=="setuid-root":
        return f"{kp.get('function_name','set*id')}({ival if ival is not None else 0})"
    # kmod
    return sval or path or "(module)"

def fmt(e):
    kp=e.get("process_kprobe")
    if not kp: return None
    lab=label(kp.get("function_name",""))
    if lab is None: return None
    if HOOK and lab!=HOOK: return None
    proc=kp.get("process",{}); pod=proc.get("pod",{})
    ns=pod.get("namespace",""); name=pod.get("name","")
    if not HOST and not name: return None      # hide host/runtime noise unless --host
    if WLNS and ns!=WLNS: return None
    podstr=f"{ns}/{name}" if name else "<host>"
    cat=category(lab)
    t=e.get("time","");
    when=(t[5:19].replace("T"," ") if MODE=="batch" else t[11:19]) if len(t)>=19 else t
    tgt=" ".join(detail(kp,lab).split())
    binargs=" ".join((proc.get("binary","")+" "+proc.get("arguments","")).split())
    node=e.get("node_name","")
    def trunc(s,n): return s if len(s)<=n else s[:n-1]+"…"
    # pad INSIDE the color wrappers so ANSI codes don't break column alignment
    line=(DIM(f"{when:<15}")
          + f"  {EMOJI[cat]} " + hue(cat, f"{lab:<14}")
          + "  " + f"{trunc(podstr,30):<30}"
          + "  " + BOLD(f"{trunc(tgt,26):<26}")
          + "  " + DIM("⟵ "+trunc(binargs,46))
          + "  " + DIM("@"+node))
    return (t, lab, line)

if MODE=="follow":
    print(DIM("# live — Ctrl-C to stop. monitor mode: events are OBSERVED, not blocked."))
    for raw in sys.stdin:
        raw=raw.strip()
        if not raw: continue
        try: e=json.loads(raw)
        except Exception: continue
        r=fmt(e)
        if r: print(r[2]); sys.stdout.flush()
else:
    rows=[]
    for raw in sys.stdin:
        raw=raw.strip()
        if not raw: continue
        try: e=json.loads(raw)
        except Exception: continue
        r=fmt(e)
        if r: rows.append(r)
    rows.sort(key=lambda x:x[0]); rows=rows[-NUM:]
    if not rows:
        print("No policy-match events found"+(f" for filter(s)" if (HOOK or WLNS) else "")+" yet."); sys.exit(0)
    for _,_,line in rows: print(line)
    tally={}
    for _,lab,_ in rows: tally[lab]=tally.get(lab,0)+1
    summ=", ".join(f"{k}={v}" for k,v in sorted(tally.items()))
    print()
    print(DIM(f"{len(rows)} match(es)  [{summ}]  — monitor mode: OBSERVED, not blocked."))
PY
# -----------------------------------------------------------------------------

# ---- Loki fetcher (used by --source loki): pulls process_kprobe lines via the
# query_range API and prints them oldest-first for the shared formatter. -------
cat > "$LOKIPY" <<'PY'
import json, os, sys, time, urllib.parse, urllib.request, urllib.error
params = urllib.parse.urlencode({
    "query": os.environ["LQ"], "limit": os.environ.get("LLIMIT", "5000"),
    "direction": "backward", "start": os.environ["LSTART"], "end": os.environ["LEND"]})
url = os.environ["LOKI_URL"] + "/loki/api/v1/query_range?" + params
data = None
for _ in range(50):                       # tolerate port-forward warmup
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            data = json.load(r); break
    except (urllib.error.URLError, ConnectionError):
        time.sleep(0.3)
if data is None:
    sys.stderr.write("loki: no response from %s (port-forward up?)\n" % os.environ["LOKI_URL"]); sys.exit(1)
if data.get("status") != "success":
    sys.stderr.write("loki error: %s\n" % json.dumps(data)[:300]); sys.exit(1)
rows = [(ts, line) for st in data["data"]["result"] for ts, line in st["values"]]
rows.sort(key=lambda x: x[0])
for _, line in rows:
    sys.stdout.write(line + "\n")
PY

run_loki() {
  # Brief background port-forward to the Loki service; cleaned up on exit.
  kubectl port-forward -n "$MON_NS" svc/loki 3100:3100 >/dev/null 2>&1 &
  PIDS+=($!)
  LOKI_URL="http://localhost:3100" LLIMIT=5000 \
    LQ='{job="tetragon"} |~ `^{"process_kprobe"`' \
    LSTART="$(( $(date +%s) - SINCE_SECS ))000000000" \
    LEND="$(date +%s)000000000" \
    python3 "$LOKIPY" > "$TMP"
}

require_agents() {
  pods="$(kubectl get pods -n "$NS" -l app.kubernetes.io/name=tetragon \
          -o jsonpath='{.items[*].metadata.name}')"
  if [ -z "${pods// }" ]; then echo "No Tetragon agents in namespace '$NS'." >&2; exit 1; fi
}

if [ "$FOLLOW" = 1 ]; then
  [ "$SOURCE" = loki ] && echo "# note: -f follows live via the agents (Loki is history-only)." >&2
  require_agents
  # one live stream per agent, all formatted to this terminal
  for p in $pods; do
    kubectl exec -n "$NS" "$p" -c tetragon -- tetra getevents -o json 2>/dev/null \
      | python3 "$PYF" follow 0 "$HOOK" "$WLNS" "$HOST" &
    PIDS+=($!)
  done
  wait
elif [ "$SOURCE" = loki ]; then
  run_loki
  python3 "$PYF" batch "$NUM" "$HOOK" "$WLNS" "$HOST" < "$TMP"
else
  require_agents
  for p in $pods; do
    # anchor on the JSON event key so we match real process_kprobe EVENTS, not
    # process_exec lines that merely mention 'process_kprobe' in their cmdline.
    kubectl exec -n "$NS" "$p" -c tetragon -- \
      sh -c "grep -h '^{\"process_kprobe\"' ${LOG} 2>/dev/null | tail -n 4000" >> "$TMP" 2>/dev/null || true
  done
  python3 "$PYF" batch "$NUM" "$HOOK" "$WLNS" "$HOST" < "$TMP"
fi
