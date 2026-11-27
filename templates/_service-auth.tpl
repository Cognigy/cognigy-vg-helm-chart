{{/*
Signed service-to-service auth (vg-resources docs/work/CGY-46075-signed-service-to-service-auth/concept.md, epic
CGY-40538). Every call into api-server /svc/v1, feature-server /v1 and resource-resolver carries an
ES256 JWS signed per request with the caller's own key.

Keys (CGY-43682 C1, rotation CGY-43688 K1). One Secret per key, created by the hook Job in
templates/common-secrets/vg-service-keys-job.yaml and never overwritten:

  key            Secret                          iss                 signs for
  internal       vg-service-key-internal         vg-api-server       api-server -> feature-server /v1
  sbc-inbound    vg-service-key-sbc-inbound      vg-sbc-inbound      sbc-inbound -> resolver, -> api-server /svc/v1
  sbc-outbound   vg-service-key-sbc-outbound     vg-sbc-outbound     sbc-outbound -> resolver
  feature-server vg-service-key-feature-server   vg-feature-server   feature-server -> resolver, -> feature-server /v1 (command forward)
  sbc-sip-sidecar vg-service-key-sbc-sip-sidecar vg-sbc-sip-sidecar runtime regbots -> resolver (CSA-109611)
  ops            vg-service-key-ops              vg-ops              ops minter (templates/ops-minter/) -> api-server /svc/v1

Each Secret holds up to two P-256 pairs, key-<slot>.pem (PKCS #8) and key-<slot>.pub.pem (SPKI), slot a
or b. serviceAuth.keys.<name>.slots lists the slots the Job makes sure exist; .active is the one the
caller signs with.

Mounts are whole directories with `items`, never subPath, so kubelet updates the files in place when a
slot is added or removed. Every volume is optional: outside FedRAMP a caller without its key sends
unsigned (counted as vg_service_auth_unsigned_total), and under FedRAMP
SERVICE_AUTH_REQUIRE_SIGNING_KEY=true makes it send nothing and fail its startup or readiness probe
(a failed startup probe restarts it), rather than the pod never being created. A receiver
lists both public halves of every trusted caller; the library re-reads them every 60 s and drops a key
whose file is gone, which is how a retired key stops being trusted.

Files are mode 0444: the service images run as a non-root user and the pods set no fsGroup, so a
tighter mode would make the key unreadable. `items` limits each pod to the files it needs.
*/}}

{{/*
Key name -> issuer (`iss`): which identity each key Secret belongs to, so a receiver's
SERVICE_AUTH_TRUSTED_KEYS is keyed by issuer. The issuers must be names from SERVICE in
@cognigy-internal/vg-service-auth: a receiver fails boot on any other name.
*/}}
{{- define "vg.serviceAuth.issuers" -}}
internal: vg-api-server
sbc-inbound: vg-sbc-inbound
sbc-outbound: vg-sbc-outbound
feature-server: vg-feature-server
sbc-sip-sidecar: vg-sbc-sip-sidecar
ops: vg-ops
{{- end -}}

{{/* Key names in the order the Job creates them. */}}
{{- define "vg.serviceAuth.keyNames" -}}
- internal
- sbc-inbound
- sbc-outbound
- feature-server
- sbc-sip-sidecar
- ops
{{- end -}}

{{/*
Receivers and the keys they trust (wave-1 contract). `modeKey` / `fedrampKey` name the rollout-mode
settings; api-server /svc/v1 has none because it always enforces.
*/}}
{{- define "vg.serviceAuth.receivers" -}}
featureServerV1:
  label: feature-server /v1
  # feature-server: the cross-pod /v2 call command forward to the pod that owns the call (CGY-46069).
  trusts: [internal, feature-server]
  modeKey: featureServerV1
  fedrampKey: serviceAuthFeatureServerV1Mode
resolver:
  label: resource-resolver
  trusts: [feature-server, sbc-inbound, sbc-outbound, sbc-sip-sidecar]
  modeKey: resolver
  fedrampKey: serviceAuthResolverMode
apiServerSvc:
  label: api-server /svc/v1
  trusts: [sbc-inbound, ops]
callRouter:
  label: sbc-call-router (basic auth)
  trusts: []
  modeKey: callRouter
  fedrampKey: serviceAuthCallRouterMode
{{- end -}}

{{- define "vg.serviceAuth.secretName" -}}vg-service-key-{{ . }}{{- end -}}

{{/*
A key's slots, validated. Takes (dict "name" <key name> "root" $); returns YAML {active, slots}.
Fails when the active slot is not one the Job creates, so a typo cannot point a caller at a key that
will never exist.
*/}}
{{- define "vg.serviceAuth.keyConfig" -}}
{{- $cfg := dig "keys" .name (dict) (.root.Values.serviceAuth | default (dict)) -}}
{{- $active := $cfg.active | default "a" -}}
{{- $slots := list "a" -}}
{{- if hasKey $cfg "slots" -}}{{- $slots = $cfg.slots | default list -}}{{- end -}}
{{- if not (has $active (list "a" "b")) -}}
{{- fail (printf "serviceAuth.keys.%s.active must be a or b, got %v" .name $active) -}}
{{- end -}}
{{- if or (not $slots) (gt (len $slots) 2) -}}
{{- fail (printf "serviceAuth.keys.%s.slots must list one or two of a, b" .name) -}}
{{- end -}}
{{- range $slots -}}
{{- if not (has . (list "a" "b")) -}}
{{- fail (printf "serviceAuth.keys.%s.slots may only contain a and b, got %v" $.name .) -}}
{{- end -}}
{{- end -}}
{{- if not (has $active $slots) -}}
{{- fail (printf "serviceAuth.keys.%s.active is %s but serviceAuth.keys.%s.slots is %v: add the slot first, wait until every receiver trusts it, then switch (vg-resources docs/operations/sops/rotate-vg-service-signing-key.md)" .name $active .name $slots) -}}
{{- end -}}
active: {{ $active }}
slots: {{ $slots | uniq | toJson }}
{{- end -}}

{{/*
Caller env: the active key path, and under FedRAMP the hard requirement. Takes (dict "name"
"extraEnvVars" <the workload's extraEnvVars> "root"); under FedRAMP an extraEnvVars entry naming one
of these variables fails the render. No issuer: a service signs as its own identity, which is a code
constant (SERVICE in @cognigy-internal/vg-service-auth), not a deployment setting.
*/}}
{{- define "vg.serviceAuth.callerEnv" -}}
{{- include "vg.fedramp.refuseEnvOverride" (dict "extraEnvVars" .extraEnvVars "names" (list "SERVICE_AUTH_SIGNING_KEY_PATH" "SERVICE_AUTH_REQUIRE_SIGNING_KEY") "instead" (printf "serviceAuth.keys.%s" .name) "root" .root) -}}
{{- $cfg := include "vg.serviceAuth.keyConfig" . | fromYaml -}}
- name: SERVICE_AUTH_SIGNING_KEY_PATH
  value: {{ printf "/etc/vg-service-auth/signing/key-%s.pem" $cfg.active | quote }}
{{- if include "vg.fedramp.enabled" .root }}
- name: SERVICE_AUTH_REQUIRE_SIGNING_KEY
  value: "true"
{{- end }}
{{- end -}}

{{- define "vg.serviceAuth.callerVolumeMount" -}}
- name: vg-service-auth-signing
  mountPath: /etc/vg-service-auth/signing
  readOnly: true
{{- end -}}

{{/*
Fails when the Secret exists but lacks the active slot's private key. Takes (dict "name" "active"
"secret" <the Secret from lookup, or empty>). The hook Job adds a slot during the same upgrade, so
switching `active` in that upgrade would point callers at a key no receiver has read yet. An empty
lookup (fresh install, offline render) skips the check: the Job then creates every listed slot.
*/}}
{{- define "vg.serviceAuth.checkActiveSlotPresent" -}}
{{- $file := printf "key-%s.pem" .active -}}
{{- if and .secret (not (hasKey (.secret.data | default dict) $file)) -}}
{{- fail (printf "serviceAuth.keys.%s.active is %s but Secret %s has no %s yet: add the slot first (slots [a, b] with the old active), wait until every receiver trusts it, then switch (vg-resources docs/operations/sops/rotate-vg-service-signing-key.md)" .name .active (include "vg.serviceAuth.secretName" .name) $file) -}}
{{- end -}}
{{- end -}}

{{/* The caller's own active private key, and nothing else from its Secret. Takes (dict "name" "root"). */}}
{{- define "vg.serviceAuth.callerVolume" -}}
{{- $cfg := include "vg.serviceAuth.keyConfig" . | fromYaml -}}
{{- include "vg.serviceAuth.checkActiveSlotPresent" (dict "name" .name "active" $cfg.active "secret" (lookup "v1" "Secret" .root.Release.Namespace (include "vg.serviceAuth.secretName" .name))) -}}
- name: vg-service-auth-signing
  secret:
    secretName: {{ include "vg.serviceAuth.secretName" .name }}
    items:
      - key: key-{{ $cfg.active }}.pem
        path: key-{{ $cfg.active }}.pem
    optional: true
    defaultMode: 292
{{- end -}}

{{/*
Receiver env: SERVICE_AUTH_TRUSTED_KEYS, and SERVICE_AUTH_MODE when the receiver has a mode.
Takes (dict "receiver" <featureServerV1|resolver|apiServerSvc> "extraEnvVars" <the workload's
extraEnvVars> "root" $); under FedRAMP an extraEnvVars entry naming either variable fails the render.
*/}}
{{- define "vg.serviceAuth.receiverEnv" -}}
{{- $r := get (include "vg.serviceAuth.receivers" . | fromYaml) .receiver -}}
{{- $instead := "serviceAuth.keys" -}}
{{- with $r.fedrampKey -}}{{- $instead = printf "global.fedramp.%s or serviceAuth.keys" . -}}{{- end -}}
{{- include "vg.fedramp.refuseEnvOverride" (dict "extraEnvVars" .extraEnvVars "names" (list "SERVICE_AUTH_MODE" "SERVICE_AUTH_TRUSTED_KEYS") "instead" $instead "root" .root) -}}
{{- $issuers := include "vg.serviceAuth.issuers" . | fromYaml -}}
{{- $trusted := dict -}}
{{- range $r.trusts -}}
{{- $_ := set $trusted (get $issuers .) (list (printf "/etc/vg-service-auth/trust/%s/key-a.pub.pem" .) (printf "/etc/vg-service-auth/trust/%s/key-b.pub.pem" .)) -}}
{{- end -}}
{{- if $r.modeKey }}
- name: SERVICE_AUTH_MODE
  value: {{ (include "vg.fedramp.serviceAuthMode" (dict "receiver" .receiver "root" .root) | fromJson).mode | quote }}
{{- end }}
- name: SERVICE_AUTH_TRUSTED_KEYS
  value: {{ $trusted | toJson | quote }}
{{- end -}}

{{- define "vg.serviceAuth.receiverVolumeMounts" -}}
{{- range (get (include "vg.serviceAuth.receivers" . | fromYaml) .receiver).trusts }}
- name: vg-service-auth-trust-{{ . }}
  mountPath: /etc/vg-service-auth/trust/{{ . }}
  readOnly: true
{{- end }}
{{- end -}}

{{/* Both public halves of each trusted key; key-b exists only during a rotation, hence optional. */}}
{{- define "vg.serviceAuth.receiverVolumes" -}}
{{- range (get (include "vg.serviceAuth.receivers" . | fromYaml) .receiver).trusts }}
- name: vg-service-auth-trust-{{ . }}
  secret:
    secretName: {{ include "vg.serviceAuth.secretName" . }}
    items:
      - key: key-a.pub.pem
        path: key-a.pub.pem
      - key: key-b.pub.pem
        path: key-b.pub.pem
    optional: true
    defaultMode: 292
{{- end }}
{{- end -}}

{{/*
Readiness marker and default mode (ADR-001 §2.6), for a receiver whose per-service mode is unset
outside FedRAMP. The chart renders ConfigMap vg-service-auth-state (templates/common/) and, before
that, reads the running release's copy with `lookup`.

"true" once this chart turns on enforce-by-default. Wave 1 (2026.23) only renders the marker; E1
(2026.24) returns "true" here. Kept as an explicit switch rather than a comparison with
.Chart.Version, because preview builds of the next version are cut from main before E1 lands.
*/}}
{{- define "vg.serviceAuth.enforceDefaultReleased" -}}{{- end -}}

{{/*
The decision itself, with the lookup results as inputs so render tests can reach every case.
Takes (dict "released" <bool> "marker" <data of the running release's marker, or empty>
"missing" <list of caller key Secrets the lookup did not find>). Returns JSON {"mode", "reason"}.
enforce only when enforce-by-default is released, the running release already rendered
callersSign, and every caller's key Secret exists. A cluster that skips a release has no marker
yet, so it renders report on that upgrade and enforce on the next; a failed key Job never leads to
enforcement.
*/}}
{{- define "vg.serviceAuth.decideDefaultMode" -}}
{{- $reason := "" -}}
{{- if not .released -}}
{{- $reason = "default: this chart release does not enforce by default yet" -}}
{{- else if ne (toString (get .marker "callersSign")) "true" -}}
{{- $reason = "default: no readiness marker with callersSign from the running release (first install, skipped release or offline render)" -}}
{{- else if .missing -}}
{{- $reason = printf "default: caller key Secret(s) missing: %s" (join ", " .missing) -}}
{{- end -}}
{{- if $reason -}}
{{- dict "mode" "report" "reason" $reason | toJson -}}
{{- else -}}
{{- dict "mode" "enforce" "reason" "default: readiness marker and every caller key present" | toJson -}}
{{- end -}}
{{- end -}}

{{/*
The lookups behind the decision. Takes (dict "receiver" "root"); returns JSON {"mode", "reason"}.
sbc-call-router (basic auth, ADR-001 §2.8) always defaults to report here: sbc-sip and sbc-call-router roll
out at different times. Its enforce default (marker callRouterCredentials) comes in a later release.
*/}}
{{- define "vg.serviceAuth.defaultMode" -}}
{{- if eq .receiver "callRouter" -}}
{{- dict "mode" "report" "reason" "default: the call-router enforce default is not released yet" | toJson -}}
{{- else -}}
{{- $root := .root -}}
{{- $ns := $root.Release.Namespace -}}
{{- $marker := (lookup "v1" "ConfigMap" $ns "vg-service-auth-state").data | default dict -}}
{{- $missing := list -}}
{{- range (get (include "vg.serviceAuth.receivers" . | fromYaml) .receiver).trusts -}}
{{- $secret := include "vg.serviceAuth.secretName" . -}}
{{- if not (lookup "v1" "Secret" $ns $secret) -}}
{{- $missing = append $missing $secret -}}
{{- end -}}
{{- end -}}
{{- include "vg.serviceAuth.decideDefaultMode" (dict "released" (include "vg.serviceAuth.enforceDefaultReleased" $root) "marker" $marker "missing" $missing) -}}
{{- end -}}
{{- end -}}

{{/*
sbc-inbound Dev Config login fallback (CGY-43873, ADR-001 §5). sbc-inbound reads Dev Config through
signed GET /svc/v1/dev-config and needs no admin credentials. An api-server without /svc/v1 (every
release before the one that ships vg-api-server#377 with this chart change) answers 404, and an
upgrade from such a release runs its api-server pods for a while. The running release says whether
its api-server serves the route: marker key svcV1DevConfig, which this chart renders. callersSign is
not that signal: releases render it before api-server has /svc/v1. On an upgrade whose running release
lacks svcV1DevConfig, and never under the FedRAMP profile, sbc-inbound gets VG_API_ADMIN_* so it can
fall back to the old login while old api-server pods answer 404. The next upgrade sees the key and
drops them. Fresh installs and offline renders (not an upgrade) get none.
Takes (dict "upgrade" <bool> "marker" <data of the running release's marker, or empty> "fedramp"
<bool>); returns "true" or "".
*/}}
{{- define "vg.serviceAuth.decideSbcInboundLoginFallback" -}}
{{- if and .upgrade (not .fedramp) (ne (toString (get .marker "svcV1DevConfig")) "true") -}}true{{- end -}}
{{- end -}}

{{/* The lookup behind the decision. Takes the root context. */}}
{{- define "vg.serviceAuth.sbcInboundLoginFallback" -}}
{{- $marker := (lookup "v1" "ConfigMap" .Release.Namespace "vg-service-auth-state").data | default dict -}}
{{- include "vg.serviceAuth.decideSbcInboundLoginFallback" (dict "upgrade" .Release.IsUpgrade "marker" $marker "fedramp" (include "vg.fedramp.enabled" .)) -}}
{{- end -}}

{{/*
The NOTES line for sbc-inbound's Dev Config path, so an upgrade shows whether the login fallback was
rendered and why. Takes the same inputs as vg.serviceAuth.decideSbcInboundLoginFallback.
*/}}
{{- define "vg.serviceAuth.sbcInboundDevConfigNote" -}}
{{- $reason := "" -}}
{{- if include "vg.serviceAuth.decideSbcInboundLoginFallback" . -}}
{{- $reason = "on: upgrade from a release whose api-server has no /svc/v1" -}}
{{- else if .fedramp -}}
{{- $reason = "off: FedRAMP profile" -}}
{{- else if not .upgrade -}}
{{- $reason = "off: fresh install or offline render" -}}
{{- else -}}
{{- $reason = "off: the running release's api-server serves /svc/v1" -}}
{{- end -}}
sbc-inbound Dev Config: signed GET /svc/v1/dev-config (login fallback {{ $reason }})
{{- end -}}

{{/* NOTES lines: each receiver's mode and the reason. */}}
{{- define "vg.serviceAuth.notes" -}}
Signed service-to-service auth (vg-resources docs/work/CGY-46075-signed-service-to-service-auth/concept.md):
{{- range $name := list "featureServerV1" "resolver" "callRouter" }}
{{- $r := get (include "vg.serviceAuth.receivers" $ | fromYaml) $name }}
{{- $m := include "vg.fedramp.serviceAuthMode" (dict "receiver" $name "root" $) | fromJson }}
  {{ $r.label }}: SERVICE_AUTH_MODE={{ $m.mode }} ({{ $m.reason }})
{{- end }}
  api-server /svc/v1: always enforce
{{- if not .Values.serviceAuth.callRouter.autoGenerate }}
  sbc-call-router credential: serviceAuth.callRouter.autoGenerate=false, so Secret {{ include "vg.callRouterAuth.secretName" . }} must exist (key credentials). Without it drachtio sends no credential, and enforce refuses every INVITE.
{{- end }}
{{- $marker := (lookup "v1" "ConfigMap" .Release.Namespace "vg-service-auth-state").data | default dict }}
  {{ include "vg.serviceAuth.sbcInboundDevConfigNote" (dict "upgrade" .Release.IsUpgrade "marker" $marker "fedramp" (include "vg.fedramp.enabled" .)) }}
{{- end -}}

{{/* NOTES lines for the ops minter (CGY-43874): who can mint and the command. Empty when it is off. */}}
{{/*
opsMinter.execGroup, trimmed; empty when unset or null (so `required` reports it, not `trim`).
*/}}
{{- define "vg.opsMinter.execGroup" -}}
{{- toString (.Values.opsMinter.execGroup | default "") | trim -}}
{{- end -}}

{{- define "vg.opsMinter.notes" -}}
{{- if .Values.opsMinter.enabled }}

Ops minter: members of {{ include "vg.opsMinter.execGroup" . | quote }} mint a vg-ops token for api-server /svc/v1 with
  kubectl exec -n {{ .Release.Namespace }} vg-ops-minter-0 -- node build/lib/ops-mint.js --sub <user> --ttl 15m
{{- end }}
{{- end -}}


{{/*
sbc-call-router exception (ADR-001 §2.8, CGY-43876). drachtio (sbc-sip, hostNetwork) is C++ and calls the
router with fixed libcurl options, so it cannot sign. It sends a basic-auth credential in its INVITE
request-handler URL instead; libcurl turns URL userinfo into `Authorization: Basic`.

The hook Job in templates/common-secrets/vg-call-router-credentials-job.yaml creates Secret
vg-call-router-credentials once (key `credentials` = drachtio:<64 hex>) and never overwrites it. Helm
renders before hooks run, so the chart never knows the value: sbc-sip's init container writes
drachtio.conf.xml from the template Secret sbc-sip-drachtio-config and the mounted credential into a
memory-backed emptyDir. The credential so never sits in a ConfigMap, a rendered manifest or on node disk.
Both volumes are optional: without the Secret drachtio sends no credential, which report counts and
enforce refuses.
*/}}
{{- define "vg.callRouterAuth.secretName" -}}vg-call-router-credentials{{- end -}}

{{/* The credential drachtio can carry in its request-handler URL inside drachtio.conf.xml: user:password in
unreserved URL characters only. A bash ERE, matched against the whole value (no line-by-line grep), by the
credential Job and by sbc-sip's init container. */}}
{{- define "vg.callRouterAuth.credentialPattern" -}}^[A-Za-z0-9._~-]+:[A-Za-z0-9._~-]+${{- end -}}

{{/* Secret volume with only the credential file. Shared by sbc-sip's init container and sbc-call-router. */}}
{{- define "vg.callRouterAuth.credentialsVolume" -}}
- name: call-router-credentials
  secret:
    secretName: {{ include "vg.callRouterAuth.secretName" . }}
    items:
      - key: credentials
        path: credentials
    optional: true
    defaultMode: 292
{{- end -}}

{{/* sbc-sip: the init container that writes drachtio.conf.xml with the credential. Takes the root context. */}}
{{- define "vg.callRouterAuth.drachtioInitContainer" -}}
- name: drachtio-config
  image: {{ include "vg.common.image.render" (dict "global" .Values.global "image" .Values.drachtio.image) }}
  imagePullPolicy: {{ .Values.drachtio.imagePullPolicy }}
  command: ["/bin/bash", "-c"]
  args:
    - |
      set -euo pipefail
      ## The credential pattern matches ASCII only, whatever locale the image sets (the Job does the same).
      export LC_ALL=C
      umask 077
      ## bash 5.2 would expand & in the replacement below.
      shopt -u patsub_replacement 2>/dev/null || true
      template=$(cat /etc/drachtio-template/drachtio.conf.xml)
      userinfo=""
      ## The file exists when the Secret has the key; an empty value is refused like the Job refuses it.
      if [ -e /etc/vg-call-router-credentials/credentials ]; then
        ## $(...) would drop a NUL byte silently, while sbc-call-router reads the raw file.
        if [ "$(tr -d '\000' < /etc/vg-call-router-credentials/credentials | wc -c)" -ne "$(wc -c < /etc/vg-call-router-credentials/credentials)" ]; then
          echo "ERROR: Secret {{ include "vg.callRouterAuth.secretName" . }} key credentials contains a NUL byte (value not printed)" >&2
          exit 1
        fi
        ## $(...) drops trailing newlines, as the Job's check and sbc-call-router do; the pattern then
        ## covers the whole value, so a second line is refused.
        credential=$(cat /etc/vg-call-router-credentials/credentials)
        pattern='{{ include "vg.callRouterAuth.credentialPattern" . }}'
        if ! [[ $credential =~ $pattern ]]; then
          echo "ERROR: Secret {{ include "vg.callRouterAuth.secretName" . }} key credentials is not user:password in letters, digits and ._~- (value not printed)" >&2
          exit 1
        fi
        userinfo="$credential@"
      else
        echo "WARNING: Secret {{ include "vg.callRouterAuth.secretName" . }} not mounted; drachtio calls sbc-call-router without credentials"
      fi
      printf '%s\n' "${template//__CALL_ROUTER_USERINFO__/$userinfo}" > /etc/drachtio/drachtio.conf.xml
      echo "OK: wrote /etc/drachtio/drachtio.conf.xml"
  resources:
    requests:
      cpu: 10m
      memory: 16Mi
    limits:
      cpu: 100m
      memory: 32Mi
  volumeMounts:
    - name: drachtio-config-template
      mountPath: /etc/drachtio-template
      readOnly: true
    - name: call-router-credentials
      mountPath: /etc/vg-call-router-credentials
      readOnly: true
    - name: drachtio-config
      mountPath: /etc/drachtio
{{- end -}}

{{/* sbc-sip: drachtio reads the written file. */}}
{{- define "vg.callRouterAuth.drachtioVolumeMount" -}}
- name: drachtio-config
  mountPath: /etc/drachtio.conf.xml
  subPath: drachtio.conf.xml
{{- end -}}

{{- define "vg.callRouterAuth.drachtioVolumes" -}}
- name: drachtio-config-template
  secret:
    secretName: sbc-sip-drachtio-config
    items:
      - key: drachtio.conf.xml
        path: drachtio.conf.xml
- name: drachtio-config
  emptyDir:
    medium: Memory
    sizeLimit: 1Mi
{{ include "vg.callRouterAuth.credentialsVolume" . }}
{{- end -}}
