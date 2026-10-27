#!/usr/bin/env bash
# helm template assertions for the vg-api-ban hardening env of the update-api-ban-list CronJob
# (apiBan.*, or global.fedramp.apiBan* while global.fedramp.enabled is true; CSA-100695).
#
# Run from anywhere: ./scripts/test-api-ban-flag.sh
set -uo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CHART_DIR"

# Chart.yaml caps kubeVersion and four values are `required`; they are unrelated to this feature.
KUBE_VERSION="${KUBE_VERSION:-1.34.0}"

FIXTURE="$(mktemp "${TMPDIR:-/tmp}/apibanflag-fixture.XXXXXX")" || exit 1
trap 'rm -f "$FIXTURE"' EXIT
cat > "$FIXTURE" <<'YAML'
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
YAML

PASS=0
FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

render() { helm template voicegateway . --kube-version "$KUBE_VERSION" -f "$FIXTURE" "$@" 2>&1; }

# Prints "NAME=VALUE" for every API_BAN_* env of the CronJob container (parsed, not grepped: BSD grep lacks \s).
ban_env() {
  render "$@" | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin.read()):
    if isinstance(doc, dict) and doc.get("kind") == "CronJob":
        c = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
        for e in c.get("env", []):
            if e["name"] in ("API_BAN_STRICT_RANGES", "API_BAN_MAX_REDIRECTS", "API_BAN_TIMEOUT_MS", "API_BAN_MAX_BATCHES"):
                print("%s=%s" % (e["name"], e.get("value")))
'
}

expect() { # description, expected "NAME=VALUE" line, then helm args
  local what="$1" want="$2"; shift 2
  if ban_env "$@" | grep -xF "$want" >/dev/null; then pass "$what"; else fail "$what (wanted $want, got: $(ban_env "$@" | tr '\n' ' '))"; fi
}

echo "profile off, chart defaults"
expect "strict ranges off"   "API_BAN_STRICT_RANGES=false"
expect "redirects 0"         "API_BAN_MAX_REDIRECTS=0"
expect "timeout 30000"       "API_BAN_TIMEOUT_MS=30000"
expect "batches 1000"        "API_BAN_MAX_BATCHES=1000"

echo "profile off, per-service keys apply"
expect "strict ranges on"    "API_BAN_STRICT_RANGES=true"  --set apiBan.strictRanges=true
expect "timeout override"    "API_BAN_TIMEOUT_MS=60000"    --set apiBan.timeoutMs=60000
expect "batches override"    "API_BAN_MAX_BATCHES=2000"    --set apiBan.maxBatches=2000

echo "profile on, global.fedramp.* applies and apiBan.* is ignored"
# The FedRAMP profile requires redis-ha with auth (global.fedramp.redisAuth, docs/013-redis-auth.md).
expect "strict ranges on"    "API_BAN_STRICT_RANGES=true"  --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true
expect "per-service strict ignored" "API_BAN_STRICT_RANGES=true" --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set apiBan.strictRanges=false
expect "per-service redirects ignored" "API_BAN_MAX_REDIRECTS=0" --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set apiBan.maxRedirects=5
expect "per-service timeout ignored" "API_BAN_TIMEOUT_MS=30000" --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set apiBan.timeoutMs=90000
expect "per-service batches ignored" "API_BAN_MAX_BATCHES=1000" --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set apiBan.maxBatches=3000
expect "documented deviation applies" "API_BAN_STRICT_RANGES=false" --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set global.fedramp.apiBanStrictRanges=false
# Non-default values, so a misspelled or unread global key cannot pass by matching the helper's fallback.
expect "global redirects override" "API_BAN_MAX_REDIRECTS=3"   --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set global.fedramp.apiBanMaxRedirects=3
expect "global timeout override"   "API_BAN_TIMEOUT_MS=45000"  --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set global.fedramp.apiBanTimeoutMs=45000
expect "global batches override"   "API_BAN_MAX_BATCHES=500"   --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set global.fedramp.apiBanMaxBatches=500

echo "profile off, a null per-service key falls back to the chart default"
# Helm drops a null key, so without a fallback the integers render "0" (rejected by vg-api-ban)
# and the strict flag renders empty (read as strict).
expect "strict ranges"       "API_BAN_STRICT_RANGES=false" --set apiBan.strictRanges=null
expect "redirects"           "API_BAN_MAX_REDIRECTS=0"     --set apiBan.maxRedirects=null
expect "timeout"             "API_BAN_TIMEOUT_MS=30000"    --set apiBan.timeoutMs=null
expect "batches"             "API_BAN_MAX_BATCHES=1000"    --set apiBan.maxBatches=null

echo "profile on, a null global key falls back to the FedRAMP value"
expect "strict ranges"       "API_BAN_STRICT_RANGES=true"  --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set global.fedramp.apiBanStrictRanges=null
expect "redirects"           "API_BAN_MAX_REDIRECTS=0"     --set global.fedramp.enabled=true --set redisHa.enabled=true --set redisHa.auth.enabled=true --set global.fedramp.apiBanMaxRedirects=null

echo "schema"
# Output is captured first: with pipefail, `grep -q` closing the pipe early would fail the pipeline.
# Helm 3 reports the key as apiBan.maxBatches, Helm 4 as /apiBan/maxBatches.
out="$(render --set apiBan.maxBatches=4000)"
if grep -qE "apiBan[./]maxBatches" <<<"$out"; then pass "maxBatches above 3999 is rejected"; else fail "maxBatches above 3999 is rejected"; fi
out="$(render --set global.fedramp.apiBanTimeoutMs=10)"
if grep -qE "fedramp[./]apiBanTimeoutMs" <<<"$out"; then pass "timeout below 1000 is rejected"; else fail "timeout below 1000 is rejected"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
