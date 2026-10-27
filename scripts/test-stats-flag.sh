#!/usr/bin/env bash
# helm template assertions for the StatsD kill switch (stats.enabled, or global.fedramp.statsEnabled while global.fedramp.enabled is true)
# (vg-resources docs/plans/014-vg-stats-collector-decommission.md, REQ-OBS-001..004).
#
# Run from anywhere: ./scripts/test-stats-flag.sh
set -uo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CHART_DIR"

# This chart cannot be rendered bare: Chart.yaml caps kubeVersion at <v1.35.0-0
# while a cluster-less helm client reports a newer default, and four values are
# `required`. None relate to this feature — they just have to be present.
KUBE_VERSION="${KUBE_VERSION:-1.34.0}"

FIXTURE="$(mktemp "${TMPDIR:-/tmp}/statsflag-fixture.XXXXXX")" || exit 1
trap 'rm -f "$FIXTURE"' EXIT
cat > "$FIXTURE" <<'EOF'
cloud: aws
tls:
  existingSecret: dummy-tls
imageCredentials:
  registry: example.azurecr.io
  username: dummy
  password: dummy
sbc:
  sip:
    uri: "sip.example.com"
# The profile turns Redis auth on, which refuses an api-ban image without REDIS_USERNAME and
# requires the Secret the chart mints to be named.
apiBan:
  image: cognigy.azurecr.io/api-ban:1.4.0
redisHa:
  auth:
    existingSecret: redis-ha-auth
EOF

PASS=0
FAIL=0

pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if [[ $1 == 0 ]]; then pass "$2"; else fail "$2"; fi; }
# grep for pipelines: unlike `grep -q`, it reads all of its input. Under pipefail, `grep -q` exits on the first
# match, the writer gets SIGPIPE, and the pipeline fails although the match was found (seen on Linux runners).
has() { grep "$@" >/dev/null; }

render() {
  helm template voicegateway . --kube-version "$KUBE_VERSION" -f "$FIXTURE" "$@" 2>&1
}

# Never use `helm template -s templates/telegraf/service.yaml` here: with the
# flag off that template renders empty and helm hard-errors ("could not find
# template ... in chart"), which is indistinguishable from a real failure. Always
# render the whole chart and select documents from the output instead.
#
# Selects by parsed kind/name rather than grep: BSD grep (macOS) does not
# understand `\s`, so a `grep -E '^\s+name: telegraf$'` assertion silently never
# matches here and reports a passing template as broken.
doc_names() {
  local kind="$1"; shift
  render "$@" | python3 -c '
import sys, yaml
want = sys.argv[1]
for doc in yaml.safe_load_all(sys.stdin.read()):
    if isinstance(doc, dict) and doc.get("kind") == want:
        print((doc.get("metadata") or {}).get("name", ""))
' "$kind"
}

svc_names() { doc_names Service "$@"; }
sts_names() { doc_names StatefulSet "$@"; }

# The telegraf.conf value out of the telegraf ConfigMap, whatever else renders.
telegraf_conf() {
  render "$@" | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin.read()):
    if not isinstance(doc, dict):
        continue
    if doc.get("kind") == "ConfigMap" and (doc.get("metadata") or {}).get("name") == "telegraf":
        sys.stdout.write((doc.get("data") or {}).get("telegraf.conf", ""))
'
}

# Every env var name on every container of every workload, as "<workload> <VAR>".
env_names() {
  render "$@" | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin.read()):
    if not isinstance(doc, dict) or doc.get("kind") not in ("Deployment", "StatefulSet", "DaemonSet"):
        continue
    name = (doc.get("metadata") or {}).get("name", "")
    spec = (((doc.get("spec") or {}).get("template") or {}).get("spec") or {})
    for c in list(spec.get("containers") or []) + list(spec.get("initContainers") or []):
        for e in c.get("env") or []:
            print(name, e.get("name", ""))
'
}

# The FedRAMP profile is the path environments use.
# The FedRAMP profile requires redis-ha with auth (global.fedramp.redisAuth, docs/013-redis-auth.md).
OFF=(--set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true)

echo "== global.fedramp.enabled=true (REQ-OBS-001: no StatsD config on any workload) =="
out="$(env_names "${OFF[@]}")"
[[ -n $out ]]; check $? "render produced workloads to inspect"
! grep -qE ' STATS_' <<<"$out"; check $? "no STATS_* env var on any workload"
grep -qE ' ENABLE_METRICS$' <<<"$out"; check $? "ENABLE_METRICS still present on the SBC workloads"
# The value, not just the name: "0" is what makes the library a no-op.
render "${OFF[@]}" | grep -A1 'name: ENABLE_METRICS' | has -F 'value: "1"'
[[ $? -ne 0 ]]; check $? "ENABLE_METRICS is never \"1\" when the flag is off"

echo "== global.fedramp.enabled=true (REQ-OBS-002: no StatsD inputs in telegraf.conf) =="
conf="$(telegraf_conf "${OFF[@]}")"
[[ -n $conf ]]; check $? "telegraf ConfigMap still renders"
! grep -qF '[[inputs.statsd]]' <<<"$conf"; check $? "no [[inputs.statsd]] block"
! grep -qF '[[inputs.socket_listener]]' <<<"$conf"; check $? "no [[inputs.socket_listener]] block"
! grep -qF '8125' <<<"$conf"; check $? "no reference to port 8125"

echo "== global.fedramp.enabled=true (REQ-OBS-003: no telegraf Service) =="
! svc_names "${OFF[@]}" | has -x 'telegraf'; check $? "Service/telegraf is not created"

echo "== global.fedramp.enabled=true (REQ-OBS-004: Homer's path survives) =="
grep -qF 'heplify-server:9096/metrics' <<<"$conf"; check $? "heplify scrape input still present"
grep -qF 'database = "homer"' <<<"$conf"; check $? "homer output database still present"
grep -qF 'namepass = ["hep*"]' <<<"$conf"; check $? "hep* namepass filter still present"
sts_names "${OFF[@]}" | has -x 'telegraf'; check $? "telegraf StatefulSet still renders"

echo "== profile off, stats.enabled unset (default: unchanged from today) =="
conf_on="$(telegraf_conf)"
grep -qF '[[inputs.statsd]]' <<<"$conf_on"; check $? "[[inputs.statsd]] present"
grep -qF '[[inputs.socket_listener]]' <<<"$conf_on"; check $? "[[inputs.socket_listener]] present"
grep -qF 'heplify-server:9096/metrics' <<<"$conf_on"; check $? "heplify scrape still present"
svc_names | has -x 'telegraf'; check $? "Service/telegraf is created"
env_names | has -E ' STATS_HOST$'; check $? "STATS_HOST rendered on the SBC workloads"

echo "== feature-server carries no StatsD config in either state =="
for flag in "" "--set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true"; do
  label="${flag:-default}"
  # shellcheck disable=SC2086
  out="$(env_names $flag | grep -E '^feature-server')"
  [[ -n $out ]]; check $? "$label: feature-server workload found"
  # shellcheck disable=SC2086
  ! grep -qE ' (STATS_|ENABLE_METRICS)' <<<"$out"; check $? "$label: no STATS_*/ENABLE_METRICS on feature-server"
  # K8S_POD_NAME is read by dial.ts and call-session.ts — it must survive the cleanup.
  grep -qE ' K8S_POD_NAME$' <<<"$out"; check $? "$label: K8S_POD_NAME kept on feature-server"
done

echo "== profile on: stats.enabled is ignored, global.fedramp.statsEnabled decides =="
ON=(--set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true)
conf_ign="$(telegraf_conf "${ON[@]}" --set stats.enabled=true)"
! grep -qF '[[inputs.statsd]]' <<<"$conf_ign"; check $? "profile on + stats.enabled=true: no statsd input (ignored)"
! svc_names "${ON[@]}" --set stats.enabled=true | has -x 'telegraf'
check $? "profile on + stats.enabled=true: no Service/telegraf (ignored)"
conf_dev="$(telegraf_conf "${ON[@]}" --set global.fedramp.statsEnabled=true)"
grep -qF '[[inputs.statsd]]' <<<"$conf_dev"; check $? "profile on + statsEnabled=true: statsd input present"
svc_names "${ON[@]}" --set global.fedramp.statsEnabled=true | has -x 'telegraf'
check $? "profile on + statsEnabled=true: Service/telegraf created"
env_names "${ON[@]}" --set global.fedramp.statsEnabled=true | has -E ' STATS_HOST$'
check $? "profile on + statsEnabled=true: STATS_HOST rendered"
# An overlay that sets the key to null removes it; a missing key must never turn StatsD on.
conf_null="$(telegraf_conf "${ON[@]}" --set global.fedramp.statsEnabled=null)"
! grep -qF '[[inputs.statsd]]' <<<"$conf_null"; check $? "profile on + statsEnabled=null: no statsd input"

echo "== profile off: global.fedramp.statsEnabled is ignored, stats.enabled decides =="
conf_off="$(telegraf_conf --set stats.enabled=false)"
! grep -qF '[[inputs.statsd]]' <<<"$conf_off"; check $? "stats.enabled=false: no statsd input"
! svc_names --set stats.enabled=false | has -x 'telegraf'; check $? "stats.enabled=false: no Service/telegraf"
env_names --set stats.enabled=false | has -E ' STATS_'
[[ $? -ne 0 ]]; check $? "stats.enabled=false: no STATS_* env var"
grep -qF '[[inputs.statsd]]' <<<"$(telegraf_conf --set global.fedramp.statsEnabled=false)"
check $? "profile off + statsEnabled=false: statsd input still present"

echo "== schema =="
schema_out="$(render --set global.fedramp.statsEnabled=bogus)"
# Helm 3 (Flux) and Helm 4 word the error differently; both name the key.
grep -qE 'fedramp[./]statsEnabled.*(got string, want boolean|Expected: boolean, given: string)' <<<"$schema_out"
check $? "non-boolean global.fedramp.statsEnabled is rejected"

echo "== helm lint =="
helm lint . --kube-version "$KUBE_VERSION" -f "$FIXTURE" >/dev/null 2>&1
check $? "lint clean with the profile off (default)"
helm lint . --kube-version "$KUBE_VERSION" -f "$FIXTURE" "${OFF[@]}" >/dev/null 2>&1
check $? "lint clean with the profile on"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
