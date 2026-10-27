{{/*
FedRAMP profile.

`global.fedramp.enabled` is the switch an environment sets. While it is on, each FedRAMP feature
takes its value from `global.fedramp.<feature>` in values.yaml and per-service overrides are
ignored, so a value inherited from a shared overlay cannot weaken the profile unnoticed. The only
way to deviate from a FedRAMP value is to change `global.fedramp.<feature>` itself, for example in
the environment's Flux overlay during an incident, which keeps every deviation next to the switch
(see docs/009-fedramp-profile.md). Services never read a "FedRAMP" variable: each one receives its
own feature setting.

Rules for adding a feature to the profile:
  1. Add `global.fedramp.<feature>` with its FedRAMP value to values.yaml and values.schema.json.
  2. Add a helper below that returns `global.fedramp.<feature>` when the profile is on (falling
     back to the FedRAMP value when the key is missing), and the per-service override (null by
     default) when it is off. Return an empty string to render nothing, so the service keeps its
     own default.
  3. Render it in the service template with `{{- with include ... }}`, before `extraEnvVars`.
  4. Add a row to docs/009-fedramp-profile.md with the control ID.
A component the profile forbids outright gets a refusal helper instead (vg.fedramp.refuseLegacyFeatureServer):
it has no global.fedramp.<feature> key, fails the render, and is included by every template of that component.
*/}}

{{/* "true" when the FedRAMP profile is on, empty otherwise. Takes the root context. */}}
{{- define "vg.fedramp.enabled" -}}
{{- if dig "fedramp" "enabled" false .Values.global -}}true{{- end -}}
{{- end -}}

{{/*
RTPENGINE_DTMF_SOURCE_VALIDATION (vg-rtpengine-utils, CSA-104130 / AC-4, SI-10).
Takes (dict "override" <per-service value or nil> "root" $).
  - Profile on: global.fedramp.dtmfSourceValidation ("enforce" in values.yaml, and "enforce" if the
    key is missing). The per-service override is ignored.
  - Profile off: the per-service override. When it is null, nothing is rendered and the library
    default ("warn") applies.

WARNING: "enforce" is only safe with sbc.rtp.useStatefulSet: true (the chart default).
The library accepts a DTMF datagram only when its source address matches the address that
sbc.rtp resolves to (engine.host) and its port is the sidecar's DTMF port. With
sbc.rtp.useStatefulSet: false, sbc-rtp runs as a DaemonSet on the host network. engine.host then
resolves to a ClusterIP Service, but the sidecar sends from its node IP. The two never match, so
"enforce" would drop every DTMF digit and calls would lose DTMF input with no error. The chart
therefore fails to render "enforce" when sbc.rtp.useStatefulSet is false.
*/}}
{{- define "vg.fedramp.dtmfSourceValidation" -}}
{{- $mode := "" -}}
{{- if include "vg.fedramp.enabled" .root -}}
{{- $mode = dig "fedramp" "dtmfSourceValidation" "enforce" .root.Values.global -}}
{{- else -}}
{{- $mode = .override | default "" -}}
{{- end -}}
{{- if and (eq $mode "enforce") (not .root.Values.sbc.rtp.useStatefulSet) -}}
{{- fail "DTMF source validation cannot be \"enforce\" when sbc.rtp.useStatefulSet is false: the sidecar replies from a node IP that never matches sbc.rtp, so every DTMF digit would be dropped. Enable the StatefulSet, or set the mode to \"warn\" or \"off\": global.fedramp.dtmfSourceValidation while the FedRAMP profile is on, sbcInbound.dtmfSourceValidation and sbcOutbound.dtmfSourceValidation otherwise." -}}
{{- end -}}
{{ $mode }}
{{- end -}}

{{/*
StatsD (vg-stats-collector -> telegraf :8125; STAT-SC8-001, SC-8 / SC-8(1) / SC-13). StatsD has no
transport encryption, so the profile removes the flow instead of encrypting it. Takes the root
context. Returns "true" when StatsD is on, empty when it is off.
  - Profile on: global.fedramp.statsEnabled (false in values.yaml, and false if the key is missing).
    stats.enabled is ignored.
  - Profile off: stats.enabled.
When off, no workload gets ENABLE_METRICS=1 or a STATS_* variable, telegraf renders no statsd or
socket_listener input, and Service/telegraf is not created. Telegraf, its heplify scrape and the
Homer output keep running.
Do not use `default` on these booleans: it treats false as empty. `dig` keeps an explicit false.
*/}}
{{- define "vg.fedramp.statsEnabled" -}}
{{- $enabled := .Values.stats.enabled -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- $enabled = dig "fedramp" "statsEnabled" false .Values.global -}}
{{- end -}}
{{- if $enabled -}}true{{- end -}}
{{- end -}}

{{/*
vg-api-ban hardening (CSA-100695, SI-4, SI-10, SC-8). Renders the four API_BAN_* env entries of the
update-api-ban-list CronJob; the caller indents them under `env:`.
  - Profile on: global.fedramp.apiBan* (strict ranges true, redirects 0, timeout 30000, batches 1000;
    each falls back to that value if the key is missing). apiBan.* is ignored.
  - Profile off: apiBan.* (strictRanges false, so a malformed range is logged and skipped; each falls
    back to the values.yaml default if the key is missing).
A key set to null in an overlay is dropped by Helm, so reading it directly would render an empty
strict flag (which vg-api-ban reads as strict) and "0" for the integers (which it rejects, failing
every run). Both branches therefore read through `dig` with the default as the fallback.
Redirects stay 0 in both: the API key is a path segment, so following a redirect hands it to the
redirect target. The feed allowance (maxBatches x 250) comes out of the 1,000,000 addresses drachtio
will load, so vg-api-ban derives the range limit from it and rejects a value that leaves no room.
Do not use `default` on these values: it treats false and 0 as empty. `dig` keeps them.
*/}}
{{- define "vg.fedramp.apiBanEnv" -}}
{{- $strict := dig "strictRanges" false .Values.apiBan -}}
{{- $redirects := dig "maxRedirects" 0 .Values.apiBan -}}
{{- $timeout := dig "timeoutMs" 30000 .Values.apiBan -}}
{{- $batches := dig "maxBatches" 1000 .Values.apiBan -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- $strict = dig "fedramp" "apiBanStrictRanges" true .Values.global -}}
{{- $redirects = dig "fedramp" "apiBanMaxRedirects" 0 .Values.global -}}
{{- $timeout = dig "fedramp" "apiBanTimeoutMs" 30000 .Values.global -}}
{{- $batches = dig "fedramp" "apiBanMaxBatches" 1000 .Values.global -}}
{{- end -}}
- name: API_BAN_STRICT_RANGES
  value: {{ $strict | quote }}
- name: API_BAN_MAX_REDIRECTS
  value: {{ $redirects | int | quote }}
- name: API_BAN_TIMEOUT_MS
  value: {{ $timeout | int | quote }}
- name: API_BAN_MAX_BATCHES
  value: {{ $batches | int | quote }}
{{- end -}}

{{/*
SESSION_KEY_DIGEST (vg-api-server; APIS-SC13-001 / CSA-101833, SC-13).
Takes (dict "override" <per-service value or nil> "root" $).
  - Profile on: global.fedramp.apiSessionKeyDigest ("sha256" in values.yaml, and "sha256" if the
    key is missing). The per-service override is ignored.
  - Profile off: the per-service override. When it is null, nothing is rendered and vg-api-server
    keeps its own default, md5.

The digest is the Redis key address, so a change relocates every stored session. On a running
cluster old and new pods then disagree about where a session lives, and a logout handled by an old
pod returns 204 without revoking anything for up to JWT_EXPIRES_IN. This chart renders no
strategy: block for api-server and has no api.strategy value, so turning the profile on where
sessions already exist needs a scale-to-zero cutover through api.replicaCount - and, where the
workload is KEDA-managed (hpa.enabled, hpa.removeReplicas and hpa.services.api.enabled all true),
the template omits replicas entirely, so hpa.services.api.enabled has to come off for the window
or the ScaledObject scales it straight back up. See the runbook at Cognigy/vg-api-server
docs/fedramp-remediation-1-upgrade.md. A new environment starts with an empty Redis and has
nothing to move.

vg-api-server reads this only from the image of Cognigy/vg-api-server#299 or later; an older image
ignores it and keeps using md5. It renders before api.extraEnvVars and Kubernetes keeps the last of
two equal names, so an extraEnvVars entry named SESSION_KEY_DIGEST overrides the profile. Do not set
one in a FedRAMP environment.
*/}}
{{- define "vg.fedramp.sessionKeyDigest" -}}
{{- $digest := "" -}}
{{- if include "vg.fedramp.enabled" .root -}}
{{- $digest = dig "fedramp" "apiSessionKeyDigest" "sha256" .root.Values.global -}}
{{- else -}}
{{- $digest = .override | default "" -}}
{{- end -}}
{{ $digest }}
{{- end -}}

{{/*
AUDIT_LOG_TTL_DAYS (vg-api-server, CSA-101837 / APIS-AU11-001, AU-11): days audit records are kept
before the nightly cleanup deletes them. Takes (dict "override" <auditLogging.cleanup.ttlDays> "root" $).
  - Profile on: global.fedramp.apiAuditLogTtlDays (90 in values.yaml, and 90 if the key is missing).
    The schema refuses less than 90. Unlike the other profile features, an api.extraEnvVars entry
    named AUDIT_LOG_TTL_DAYS fails the render instead of silently overriding the profile: it would
    render after this value, and Kubernetes keeps the last of two equal names, so it could shorten
    retention below the AU-11 minimum.
  - Profile off: auditLogging.cleanup.ttlDays (90 by default). When it is null, nothing is rendered
    and vg-api-server keeps its own default (90 from vg-api-server#255; 30 in older images).

A number from a values file is a float64, which renders 1000000 and above in exponent form ("1e+06").
vg-api-server images before #255 parse the variable with parseInt, which reads "1e+06" as 1 day, so
floats are printed as whole numbers ("%.0f"), not cast to int64: a cast overflows on values beyond
int64 (on amd64 to a negative number, a cut-off in the future that deletes every record). The schema
also caps both keys at 99999 days. Strings are passed through unchanged (the schema allows only digits).

The chart used to inject this as AUDIT_LOGGING_TTL_DAYS=30, a name vg-api-server never read, so
retention was 90 only because of the mismatch. The name and the 90 must change together: renaming
alone would have activated the 30.
*/}}
{{- define "vg.fedramp.auditLogTtlDays" -}}
{{- $days := "" -}}
{{- if include "vg.fedramp.enabled" .root -}}
{{- with .root.Values.api.extraEnvVars -}}
{{- range include "vg.common.tplvalues.render" (dict "value" . "context" $.root) | fromYamlArray -}}
{{- if and (kindIs "map" .) (eq (toString (get . "name")) "AUDIT_LOG_TTL_DAYS") -}}
{{- fail "api.extraEnvVars cannot set AUDIT_LOG_TTL_DAYS while global.fedramp.enabled is true: it would override the FedRAMP audit-log retention (AU-11). Set global.fedramp.apiAuditLogTtlDays instead (90 or more)." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $days = dig "fedramp" "apiAuditLogTtlDays" 90 .root.Values.global | default 90 -}}
{{- else if not (kindIs "invalid" .override) -}}
{{- $days = .override -}}
{{- end -}}
{{- if kindIs "float64" $days -}}
{{- $days = printf "%.0f" $days -}}
{{- end -}}
{{ $days }}
{{- end -}}

{{/*
Legacy feature-server (vg-feature-server-legacy; CGY-42548, CM-7, SC-13). Takes the root context and
renders nothing. The profile has no value to relax here: the legacy feature-server does not get the
signed-token verification of the /v1 routes (CSA-102459), and its crypto and dependencies are outside
the FIPS work, so the chart fails to render it while the profile is on. Included by the legacy
StatefulSet and Service, which render only when featureServerLegacy.enabled is true.
*/}}
{{- define "vg.fedramp.refuseLegacyFeatureServer" -}}
{{- if and (include "vg.fedramp.enabled" .) .Values.featureServerLegacy.enabled -}}
{{- fail "featureServerLegacy.enabled cannot be true while global.fedramp.enabled is true: the legacy feature-server lacks the /v1 token verification and is outside the FIPS boundary. Set featureServerLegacy.enabled to false (and move its applications to the feature-server), or do not use the FedRAMP profile in this environment." -}}
{{- end -}}
{{- end -}}
