#!/usr/bin/env bash
# Enable/disable the vg-test-harness on a developer namespace, fast, by
# patching the live Helm release directly (bypasses Flux). Flux's next
# reconcile reverts to committed state.
set -euo pipefail

RELEASE="voicegateway"
# Default testing freeswitch image (asan build carrying vg-freeswitch PR #255).
# vg-freeswitch renamed its final image from vg-freeswitch-mrf to vg-freeswitch
# (Cognigy/vg-freeswitch#244) and appends the buildType with no separator, so the
# asan variant is `vg-freeswitchasan`. This default was left on the pre-rename
# name. Preview releases build production only; asan comes from the main
# build-freeswitch workflow, dev registry only.
DEFAULT_FS_IMAGE="cognigydevelopment.azurecr.io/vg-freeswitchasan:2026.07.31-30614981012"

usage() {
  cat <<EOF
Usage: $0 <enable|disable> [--namespace NS] [--freeswitch-image IMAGE]

  enable    Turn on vgTestHarness in the namespace and ensure an asan/debug
            freeswitch image is in use.
  disable   Turn off vgTestHarness.

  --namespace NS         Target namespace (default: current kube-context ns)
  --freeswitch-image IMG Override the testing freeswitch image used by 'enable'
                         (default: $DEFAULT_FS_IMAGE)
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage
ACTION="$1"; shift
NS=""
FS_IMAGE="$DEFAULT_FS_IMAGE"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --freeswitch-image) FS_IMAGE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

command -v helm >/dev/null    || { echo "helm not found on PATH" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found on PATH" >&2; exit 1; }

if [[ -z "$NS" ]]; then
  NS="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
  [[ -z "$NS" ]] && { echo "No --namespace given and no namespace set in kube-context" >&2; exit 1; }
fi

helm status "$RELEASE" -n "$NS" >/dev/null 2>&1 \
  || { echo "Helm release '$RELEASE' not found in namespace '$NS'" >&2; exit 1; }

case "$ACTION" in
  enable)
    # Matches both the current vg-freeswitchasan/debug names and the pre-rename
    # vg-freeswitch-mrfasan/debug ones (Cognigy/vg-freeswitch#244). The earlier
    # 'mrf' filter missed every current build, so `enable` would silently
    # re-pin the default over a perfectly good asan image the user had set.
    CUR_FS="$(helm get values "$RELEASE" -n "$NS" -o json 2>/dev/null \
              | grep -o '"image"[^,}]*vg-freeswitch[a-z-]*[^,}]*' || true)"
    EXTRA=()
    if ! printf '%s' "$CUR_FS" | grep -qE 'vg-freeswitch(-mrf)?(asan|debug)'; then
      echo "WARNING: current freeswitch image is not an asan/debug build."
      echo "         Setting freeswitch.image=$FS_IMAGE so overrides take effect."
      EXTRA=(--set "freeswitch.image=$FS_IMAGE")
    fi
    echo "Enabling test harness in namespace '$NS'..."
    helm upgrade "$RELEASE" . -n "$NS" --reuse-values \
      --set vgTestHarness.enabled=true "${EXTRA[@]}"
    echo "Waiting for mock pods..."
    for app in mock-cognigy mock-speech sip-caller; do
      kubectl rollout status deploy/"$app" -n "$NS" --timeout=120s
    done
    cat <<EOF

Test harness ENABLED in '$NS'.
  Port-forward:  kubectl port-forward -n $NS svc/sip-caller 8090:8090
  Fire a call:   curl -s -X POST http://localhost:8090/calls \\
                   -H 'Content-Type: application/json' \\
                   -d @scenarios/gather-speech.json | jq .
EOF
    ;;
  disable)
    echo "Disabling test harness in namespace '$NS'..."
    helm upgrade "$RELEASE" . -n "$NS" --reuse-values \
      --set vgTestHarness.enabled=false
    echo "Test harness DISABLED in '$NS'. (Flux will reconcile committed state.)"
    ;;
  *) usage ;;
esac
