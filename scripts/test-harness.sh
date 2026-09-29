#!/usr/bin/env bash
# Enable/disable the vg-test-harness on a developer namespace, fast, by
# patching the live Helm release directly (bypasses Flux). Flux's next
# reconcile reverts to committed state.
set -euo pipefail

RELEASE="voicegateway"

usage() {
  cat <<EOF
Usage: $0 <enable|disable> [--namespace NS] [--freeswitch-image IMAGE]

  enable    Turn on vgTestHarness in the namespace.
  disable   Turn off vgTestHarness.

  --namespace NS         Target namespace (default: current kube-context ns)
  --freeswitch-image IMG Pin a specific freeswitch image. Optional, and not
                         needed for the harness: the production image works.
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage
ACTION="$1"; shift
NS=""
FS_IMAGE=""
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
    # No asan/debug image is forced any more. That existed for
    # TESTING_OVERRIDE_{TTS,STT}_URL, which the chart no longer sets: a
    # custom:<name> speech credential carries its own URL, and the vendor route
    # (vgTestHarness.speechInterception=vendor) redirects by DNS. Both work on
    # the production image, so `enable` no longer swaps it out from under you.
    EXTRA=()
    if [[ -n "$FS_IMAGE" ]]; then
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
