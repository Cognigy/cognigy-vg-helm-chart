#!/usr/bin/env bash
# helm template assertions for the sbc-rtp RTP traffic gate
# (vg-resources docs/superpowers/specs/2026-07-28-rtp-traffic-gate-design.md).
#
# Run from anywhere: ./scripts/test-traffic-gate.sh
set -uo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CHART_DIR"

# This chart cannot be rendered bare: Chart.yaml caps kubeVersion at <v1.35.0-0
# while a cluster-less helm client reports a newer default, and four values are
# `required`. None relate to this feature — they just have to be present.
KUBE_VERSION="${KUBE_VERSION:-1.34.0}"
FIXTURE="$(mktemp -t rtpgate-fixture)"
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
EOF

PASS=0
FAIL=0

pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if [[ $1 == 0 ]]; then pass "$2"; else fail "$2"; fi; }

render() {
  helm template voicegateway . --kube-version "$KUBE_VERSION" -f "$FIXTURE" "$@" 2>&1
}

# Only the sbc-rtp documents from a full-chart render.
#
# Never use `helm template -s` for this: with the escape hatch off the ConfigMap
# template renders empty and helm hard-errors ("could not find template ... in
# chart"), and only one of stateful-set/daemon-set renders per useStatefulSet
# mode, so naming both always fails. Never grep the full render either — other
# services in this chart have their own /health/ready probes and would produce
# false positives.
rtp_docs() {
  render "$@" | python3 -c '
import sys, yaml
out = []
for doc in yaml.safe_load_all(sys.stdin.read()):
    if not isinstance(doc, dict):
        continue
    name = (doc.get("metadata") or {}).get("name", "")
    if name == "sbc-rtp" or name == "sbc-rtp-traffic-gate":
        out.append(yaml.safe_dump(doc, default_flow_style=False))
sys.stdout.write("\n---\n".join(out))
'
}

DRAIN=(--set 'sbc.rtp.trafficGate.drainAddresses[0]=3.1.2.3' --set 'sbc.rtp.trafficGate.drainAddresses[1]=3.4.5.6')

# Only the sbc-rtp pod-template annotations, for the checksum-stability check.
rtp_checksums() {
  helm template voicegateway . --kube-version "$KUBE_VERSION" -f "$FIXTURE" "$@" \
    -s templates/sbc-rtp/stateful-set.yaml 2>/dev/null | grep -E '^\s+checksum/' | sort
}

echo "== default: gate wired, nothing drained =="
for mode in true false; do
  out="$(rtp_docs --set "sbc.rtp.useStatefulSet=$mode")"
  grep -q 'name: sbc-rtp-traffic-gate' <<<"$out"; check $? "useStatefulSet=$mode: ConfigMap rendered by default"
  grep -qF 'SBC_RTP_DRAIN_ADDRESSES: ""' <<<"$out"; check $? "useStatefulSet=$mode: key present and EMPTY (never absent)"
  grep -q 'readinessProbe' <<<"$out"; check $? "useStatefulSet=$mode: readinessProbe rendered by default"
  grep -q 'mountPath: /config/rtp-gate' <<<"$out"; check $? "useStatefulSet=$mode: mount rendered by default"
done

echo "== escape hatch: trafficGate.enabled=false removes everything =="
out="$(rtp_docs --set sbc.rtp.trafficGate.enabled=false)"
grep -q 'sbc-rtp-traffic-gate' <<<"$out"; check $((1 - $?)) "no ConfigMap or volume"
grep -q 'readinessProbe' <<<"$out";       check $((1 - $?)) "no readinessProbe"
grep -q 'SBC_RTP_TRAFFIC_GATE_ENABLED' <<<"$out"; check $((1 - $?)) "no gate env var"

echo "== draining: ConfigMap carries a comma-separated scalar =="
out="$(rtp_docs "${DRAIN[@]}")"
grep -q 'name: sbc-rtp-traffic-gate' <<<"$out"; check $? "ConfigMap rendered"
grep -qF 'SBC_RTP_DRAIN_ADDRESSES: "3.1.2.3,3.4.5.6"' <<<"$out"; check $? "scalar, comma-joined (NOT a YAML sequence)"

echo "== draining: both workload types are wired =="
for mode in true false; do
  kind=$([[ $mode == true ]] && echo StatefulSet || echo DaemonSet)
  out="$(rtp_docs "${DRAIN[@]}" --set "sbc.rtp.useStatefulSet=$mode")"
  grep -q "kind: $kind" <<<"$out";         check $? "useStatefulSet=$mode: renders a $kind"
  grep -q 'readinessProbe' <<<"$out";      check $? "useStatefulSet=$mode: readinessProbe"
  grep -q 'path: /health/ready' <<<"$out"; check $? "useStatefulSet=$mode: probe path"
  grep -q 'SBC_RTP_TRAFFIC_GATE_ENABLED' <<<"$out"; check $? "useStatefulSet=$mode: gate env var"
  grep -q 'mountPath: /config/rtp-gate' <<<"$out"; check $? "useStatefulSet=$mode: sidecar mount"
  grep -q 'name: sbc-rtp-traffic-gate' <<<"$out"; check $? "useStatefulSet=$mode: pod volume"

  # Structural, not textual: the volume must sit on the POD spec and the mount on
  # the SIDECAR container. A grep would pass even if either landed in the wrong
  # place and Kubernetes rejected the manifest.
  rtp_docs "${DRAIN[@]}" --set "sbc.rtp.useStatefulSet=$mode" | python3 -c '
import sys, yaml
ok = False
for doc in yaml.safe_load_all(sys.stdin.read()):
    if not isinstance(doc, dict) or doc.get("kind") not in ("StatefulSet", "DaemonSet"):
        continue
    spec = doc["spec"]["template"]["spec"]
    vols = [v["name"] for v in spec.get("volumes", [])]
    sc = [c for c in spec["containers"] if c["name"] == "rtp-engine-sidecar"][0]
    mounts = [(m["name"], m["mountPath"]) for m in sc.get("volumeMounts", [])]
    ok = ("sbc-rtp-traffic-gate" in vols
          and ("sbc-rtp-traffic-gate", "/config/rtp-gate") in mounts
          and sc["readinessProbe"]["httpGet"]["path"] == "/health/ready")
sys.exit(0 if ok else 1)
'
  check $? "useStatefulSet=$mode: volume on pod spec, mount + probe on the sidecar"
done

echo "== readiness port must not collide with health (8001) or metrics (8002) =="
# getMetricsPort() defaults to 8002 and .Values.metrics.port is 8002, so an 8002
# readiness port makes the listener fail with EADDRINUSE and the metrics app
# answer every probe with a 404.
port="$(rtp_docs "${DRAIN[@]}" | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin.read()):
    if isinstance(doc, dict) and doc.get("kind") in ("StatefulSet", "DaemonSet"):
        sc = [c for c in doc["spec"]["template"]["spec"]["containers"] if c["name"] == "rtp-engine-sidecar"][0]
        print(sc["readinessProbe"]["httpGet"]["port"])
')"
{ [[ -n "$port" ]] && [[ "$port" != "8001" ]] && [[ "$port" != "8002" ]]; }
check $? "readiness port is ${port:-<unset>} (not 8001/8002)"

echo "== REGRESSION GUARD: a gate change must not move any pod-template checksum =="
# This is the assertion that would have caught delivering the list as an env var.
# If the traffic-gate ConfigMap ever lands in a checksum/... annotation, editing
# the gate rolls every sbc-rtp pod and kills in-flight calls.
a="$(rtp_checksums)"                                          # nothing drained (steady state)
b="$(rtp_checksums "${DRAIN[@]}")"                            # two addresses drained
c="$(rtp_checksums --set 'sbc.rtp.trafficGate.drainAddresses[0]=9.9.9.9')"
{ [[ "$a" == "$b" ]] && [[ "$b" == "$c" ]]; }
check $? "sbc-rtp checksums identical across empty/two/one drained addresses"
grep -q 'traffic-gate' <<<"$a$b$c"; check $((1 - $?)) "no checksum annotation names the traffic-gate ConfigMap"

echo "== explicit null drain list == nothing drained =="
out="$(rtp_docs --set-json 'sbc.rtp.trafficGate.drainAddresses=null')"
grep -qF 'SBC_RTP_DRAIN_ADDRESSES: ""' <<<"$out"
check $? "drainAddresses: null renders an empty key, not an absent one"

echo "== guards reject misconfiguration at template time =="
assert_fails() { # <name> <expected substring> <helm args...>
  local name="$1" needle="$2"; shift 2
  local out rc
  out="$(render "$@")"; rc=$?
  if [[ $rc -ne 0 ]] && grep -qF "$needle" <<<"$out"; then pass "$name"; else fail "$name"; fi
}

# An EMPTY drain list is the steady state, so it must be ACCEPTED, not rejected.
out="$(render --set-json 'sbc.rtp.trafficGate.drainAddresses=[]')"; rc=$?
{ [[ $rc -eq 0 ]] && grep -qF 'SBC_RTP_DRAIN_ADDRESSES: ""' <<<"$out"; }
check $? "empty drain list is accepted (it is the steady state)"

# Verified: --set 'x=[]' yields the STRING "[]", not an empty list, so it trips the
# kindIs-slice guard. It is a realistic operator typo and must fail legibly.
assert_fails "--set '[]' string rejected"  "must be a list"      --set 'sbc.rtp.trafficGate.drainAddresses=[]'
assert_fails "non-IPv4 entry rejected"     "is not a valid IPv4" --set 'sbc.rtp.trafficGate.drainAddresses[0]=not-an-ip'
assert_fails "out-of-range octet rejected" "is not a valid IPv4" --set 'sbc.rtp.trafficGate.drainAddresses[0]=999.1.1.1'
assert_fails "non-aws cloud rejected"      "only supported on cloud=aws" \
  "${DRAIN[@]}" --set cloud=azure
assert_fails "cognigyEnv copy rejected"    "must not be set in cognigyEnv" \
  "${DRAIN[@]}" --set 'cognigyEnv.SBC_RTP_DRAIN_ADDRESSES=3.1.2.3'
assert_fails "readiness port colliding with health.port rejected"  "must not equal health.port" \
  --set 'rtpEngineSidecar.ports.readiness=8001'
assert_fails "readiness port colliding with metrics.port rejected" "must not equal metrics.port" \
  --set 'rtpEngineSidecar.ports.readiness=8002'

echo "== non-aws clouds are unaffected while nothing is drained =="
for c in azure stackit; do
  out="$(helm template voicegateway . --kube-version "$KUBE_VERSION" -f "$FIXTURE" --set "cloud=$c" 2>&1)"
  check $? "cloud=$c renders with an empty drain list"
done

echo "== helm lint =="
helm lint . --kube-version "$KUBE_VERSION" -f "$FIXTURE" "${DRAIN[@]}" >/dev/null 2>&1
check $? "lint clean with the gate on"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
