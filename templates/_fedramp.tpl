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
A flow that only the profile turns off, and that every other environment keeps, needs no per-service key: its
helper returns "true" while the profile is off and gates the entry with `{{- if include ... }}`
(vg.fedramp.sbcSipSidecarAlerts).
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
sbc-sip-sidecar alerts (vg-time-series -> influxdb :8086; CGY-42786, SC-8). sbc-sip runs on the host
network, outside the mesh, so this plain-HTTP flow is refused under STRICT mTLS and is unencrypted. The
profile removes the flow instead of moving every InfluxDB client to TLS. Takes the root context. Returns
"true" when the sidecar gets JAMBONES_TIME_SERIES_HOST, empty when it does not.
  - Profile on: global.fedramp.sbcSipSidecarAlerts (false in values.yaml, and false if the key is
    missing).
  - Profile off: always "true". There is no per-service key.
Without the variable the sidecar writes no alerts (the account-device-limit and OPTIONS ping failure
alerts of the VG portal's Alerts page) and only logs the events. Images older than
Cognigy/vg-sbc-sip-sidecar CGY-42786 refuse to start without it.
Do not use `default` on this boolean: it treats false as empty. `dig` keeps an explicit false.
*/}}
{{- define "vg.fedramp.sbcSipSidecarAlerts" -}}
{{- $enabled := true -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- $enabled = dig "fedramp" "sbcSipSidecarAlerts" false .Values.global -}}
{{- end -}}
{{- if $enabled -}}true{{- end -}}
{{- end -}}

{{/*
sbc-sip-sidecar runtime regbots (sidecar -> vg-resource-resolver :4000; CGY-44772, SC-8, SC-7). The
sidecar polls the resolver every 60 s for the carriers configured in Cognigy.AI that require REGISTER.
sbc-sip runs on the host network, outside the mesh, so the poll is plain HTTP that STRICT mTLS refuses,
and vg-resource-resolver's NetworkPolicy (vg.fedramp.networkPolicyEnabled) admits a
host-networked caller only by node CIDR, which is empty by default. Takes the root context. Returns "true" when the
regbots run (vg.sbcSip.runtimeRegbots.enabled), empty when they do not.
  - Profile on: global.fedramp.sbcSipRuntimeRegbots (false in values.yaml, and false if the key is
    missing). sbcSipSidecar.runtimeRegbots.enabled is ignored.
  - Profile off: sbcSipSidecar.runtimeRegbots.enabled (true in values.yaml).
With it off, AI-side carriers are not registered. A FedRAMP deployment is VG-in-AI only and has no
carriers in MySQL, so no carrier is registered at all (TODO CGY-45358). Turning it
back on under the profile also needs a resolver ingress rule that matches this cluster's node
addresses (resourceResolver.networkPolicy.ingressFromHostNetwork), or the poll times out.
Do not use `default` on these booleans: it treats false as empty. `dig` keeps an explicit false.
*/}}
{{- define "vg.fedramp.sbcSipRuntimeRegbots" -}}
{{- $enabled := dig "runtimeRegbots" "enabled" false .Values.sbcSipSidecar -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- $enabled = dig "fedramp" "sbcSipRuntimeRegbots" false .Values.global -}}
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
FEATURE_STRICT_REGISTRATION_HOOK_VALIDATION_ENABLED (vg-api-server; SSIP-AC4-001 / CSA-102746, AC-4):
the SSRF guard on registration_hook / queue_event_hook, checked when a record is saved.
Takes (dict "override" <per-service value or nil> "root" $).
  - Profile on: global.fedramp.apiStrictRegistrationHookValidation (true in values.yaml, and true if
    the key is missing). The per-service override is ignored.
  - Profile off: the per-service override. When it is null, nothing is rendered and vg-api-server
    keeps its own default.

Read with dig/kindIs rather than `default`, which would treat an explicit false as unset.
Only images with Cognigy/vg-api-server#289 or later read the variable; an older image ignores it.
The dial-time check in vg-digest-utils (sbc-inbound / sbc-sip) is not wired by this chart.
*/}}
{{- define "vg.fedramp.strictRegistrationHookValidation" -}}
{{- if include "vg.fedramp.enabled" .root -}}
{{- dig "fedramp" "apiStrictRegistrationHookValidation" true .root.Values.global -}}
{{- else if not (kindIs "invalid" .override) -}}
{{- .override -}}
{{- end -}}
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
Traefik entrypoint trust boundary (VHC-SC7-002, SC-7). Takes the root context and renders nothing.
`traefik.ports.{web,websecure}.{proxyProtocol,forwardedHeaders}.insecure` default to true (trusting
a PROXY-protocol preamble or X-Forwarded-For from any caller, not only the real upstream
proxy/load balancer) because that default applies to every install, FedRAMP or not, and flipping it
for everyone risked an outage for any environment whose load balancer sends a PROXY preamble or
relies on X-Forwarded-For without yet having trustedIPs configured to match (a chart-wide default
cannot know each environment's load-balancer topology). So instead of changing the default, the
profile demands each entry point be moved off it explicitly: while the profile is on, every
environment's own values/Flux overlay must set insecure: false (both ports, both settings) and the
matching trustedIPs for its real topology — see docs/009-fedramp-profile.md for which setting
depends on which topology, and the ipWhiteListMiddleware ipStrategy.depth it requires. Included from
NOTES.txt so it is evaluated on every render regardless of which resources are enabled.

insecure: false alone is not the real control — it only says Traefik will look at trustedIPs rather
than trusting every caller. The real control is trustedIPs itself: a value here can reintroduce the
exact same bypass. Once past the insecure check, trustedIPs on both ports/both settings is rejected
by vg.fedramp.rejectUnsafeCidrs below (so trustedIPs: [0.0.0.0/0] fails the same way an ingress
allow-list's sourceRange: [0.0.0.0/0] does). Separately, traefik.additionalArguments can set
--entryPoints.<port>.<proxyProtocol|forwardedHeaders>.insecure directly on the Traefik CLI, bypassing
the traefik.ports.* values this check reads entirely (Traefik does not document which of the two
wins when both set the same entry point, so this is rejected outright rather than assumed to lose).

`traefik.ports.*` only configures this chart's own Traefik subchart (Chart.yaml's `condition:
traefik.enabled`), so none of this applies when `traefik.enabled` is false — an external or shared
Traefik serves the install instead, and this chart cannot inspect or configure its entry points.
Checking the same values anyway would fail every such install on settings that configure nothing,
and fixing that by setting them would make the render pass while leaving the real entry point's
trust boundary unchecked — the "looks protected but isn't" failure this whole template exists to
prevent. So with traefik.enabled: false, the chart instead requires a human acknowledgement,
global.fedramp.externalTraefikEntrypointsVerified: true, recorded as a deviation row in
docs/009-fedramp-profile.md: someone with access to the external controller's config has checked by
hand that it does not trust an unauthenticated PROXY-protocol preamble or X-Forwarded-For header on
its web/websecure entry points.
*/}}
{{- define "vg.fedramp.refuseInsecureTraefikEntrypoints" -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- if $.Values.traefik.enabled -}}
{{- range $port := list "web" "websecure" -}}
{{- range $setting := list "proxyProtocol" "forwardedHeaders" -}}
{{- if dig $port $setting "insecure" true $.Values.traefik.ports -}}
{{- fail (printf "global.fedramp.enabled is true, but traefik.ports.%s.%s.insecure is still true (the chart-wide default): the FedRAMP profile does not change this chart-wide, since it isn't safe to flip for every environment without knowing its load-balancer topology. Set traefik.ports.%s.%s.insecure: false and the matching trustedIPs for this environment's real topology in its own values/Flux overlay (docs/009-fedramp-profile.md)." $port $setting $port $setting) -}}
{{- end -}}
{{- include "vg.fedramp.rejectUnsafeCidrs" (dict "range" (dig $port $setting "trustedIPs" list $.Values.traefik.ports) "subject" (printf "global.fedramp.enabled is true, but traefik.ports.%s.%s.trustedIPs includes" $port $setting)) -}}
{{- $flagPrefix := printf "--entrypoints.%s.%s.insecure" (lower $port) (lower $setting) -}}
{{- range $arg := $.Values.traefik.additionalArguments -}}
{{- if regexMatch (printf "(?i)^%s(=(true|1))?$" (regexQuoteMeta $flagPrefix)) $arg -}}
{{- fail (printf "global.fedramp.enabled is true, but traefik.additionalArguments sets %s: this bypasses the traefik.ports.%s.%s.insecure check above entirely by setting the same entry point directly on the Traefik CLI. Remove it, or achieve the same trust boundary through traefik.ports.%s.%s instead (docs/009-fedramp-profile.md)." $arg $port $setting $port $setting) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- else if not (dig "fedramp" "externalTraefikEntrypointsVerified" false $.Values.global) -}}
{{- fail "global.fedramp.enabled is true and traefik.enabled is false, so this install uses an external or shared Traefik: traefik.ports.* only configures this chart's own (disabled) Traefik subchart and cannot check that external controller's entry-point trust boundary. Verify by hand that it does not trust an unauthenticated PROXY-protocol preamble or X-Forwarded-For header on its web/websecure entry points, then set global.fedramp.externalTraefikEntrypointsVerified: true in this environment's values/Flux overlay to acknowledge that check was done (docs/009-fedramp-profile.md)." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
CIDR floor + mapped-address rejection, shared by the ingress IP allow-list and the Traefik
entrypoint trustedIPs check below (VHC-SC7-002, SC-7). Takes (dict "range" <list of CIDR strings,
nil-safe> "subject" <string already naming what's being validated, used verbatim at the start of
every error message here, e.g. "ingress.api.ipWhiteListMiddleware would be enabled, but
ipWhiteList.sourceRange includes">). Renders nothing; fails the whole render on the first unsafe
entry found.
  - Must not contain an IPv4-mapped IPv6 address (::ffff:a.b.c.d, or any of its many equivalent
    IPv6 "::" compression spellings) at any prefix length: Go's net.ParseCIDR can normalize a
    mapped address to a far broader effective network than its written prefix suggests once the
    embedded IPv4 address's bits fall on the host side of the mask (::ffff:0:0/96 becomes "every
    IPv4 address in mapped form"; shorter or longer prefixes shift how much of the address space
    that covers, and the "::" compression alone has multiple valid spellings for the same bits).
    Rather than re-deriving the effective network for every spelling, mapped notation is rejected
    outright: Traefik accepts plain IPv4 CIDR notation directly (10.0.0.0/8, ...), so there is no
    reason to write an IPv4 range in its IPv6-mapped form here.
  - Must not contain a prefix shorter than /8 for IPv4, or shorter than /32 for IPv6 (0.0.0.0/0,
    10.0.0.0/4, ::/0, 2001:db8::/16, ...; multiple entries that only look narrow but jointly cover
    the same prefix shorter than the floor — e.g. both 0.0.0.0/1 and 128.0.0.0/1 — are still each
    individually rejected): a prefix that short admits a large enough fraction of that address
    family's space to be, in practice, the same as no allow-list at all.
*/}}
{{- define "vg.fedramp.rejectUnsafeCidrs" -}}
{{- $range := .range | default list -}}
{{- $mappedHost := "(?:[0-9a-f]{1,4}:[0-9a-f]{1,4}|[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})" -}}
{{- range $cidr := $range -}}
{{- $parts := splitList "/" (lower $cidr) -}}
{{- if eq (len $parts) 2 -}}
{{- $addr := index $parts 0 -}}
{{- $prefixLen := atoi (index $parts 1) -}}
{{/* Any valid IPv6 "::" compression of the fixed 0:0:0:0:0:ffff prefix: the leading zero groups
fully spelled out or "::" standing for any contiguous split of them, or, with the leading groups
fully spelled out, "::" instead compressing one or both of the two embedded-IPv4 host groups (the
remaining explicit host group, if any, can be any value — see the comment above this template). */}}
{{- if or (regexMatch (printf "^(?:0{1,4}:){5}ffff:%s$" $mappedHost) $addr) (regexMatch (printf "^(?:0{1,4}(?::0{1,4})*)?::(?:0{1,4}:)*ffff:%s$" $mappedHost) $addr) (regexMatch "^(?:0{1,4}:){5}ffff(?::[0-9a-f]{1,4}::|::[0-9a-f]{1,4}|::)$" $addr) -}}
{{- fail (printf "%s %s, an IPv4-mapped IPv6 address: use plain IPv4 CIDR notation for IPv4 ranges instead (Traefik accepts it directly), since Go's CIDR matching can normalize IPv6-mapped notation to a broader effective network than its written prefix suggests." $.subject $cidr) -}}
{{- else if contains ":" $addr -}}
{{- if lt $prefixLen 32 -}}
{{- fail (printf "%s %s, an IPv6 prefix shorter than /32: that admits enough of the IPv6 address space to be, in practice, the same as no allow-list. List only this environment's real allow-listed ranges." $.subject $cidr) -}}
{{- end -}}
{{- else if lt $prefixLen 8 -}}
{{- fail (printf "%s %s, an IPv4 prefix shorter than /8: that admits enough of the IPv4 address space to be, in practice, the same as no allow-list. List only this environment's real allow-listed ranges." $.subject $cidr) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Ingress IP allow-list (ipWhiteListMiddleware) on the 9 externally-exposed ingresses — api, homer,
jaeger, testCallManager, webapp, vgConnector, vgConsole, vgPagerdutyAgent, realtimeBridge (VHC-SC7-002, SC-7).
Takes (dict "service" "<ingress.<key> name, for the error message>" "override" <the
ingress.<service>.ipWhiteListMiddleware.enabled this service would use with the profile off>
"sourceRange" <ingress.<service>.ipWhiteListMiddleware.ipWhiteList.sourceRange>
"extraAnnotations" <ingress.<service>.extraAnnotations, omit where the service has none>
"skipIngressClassCheck" <true for a service enforced through a Traefik IngressRoute CRD rather
than a standard Ingress — currently only vgConnector; IngressRoute specifies entryPoints directly
and is not affected by ingress.ingressClassName, so the check below would wrongly fail its render
in a cluster that uses a non-Traefik ingressClassName for its (unrelated) standard Ingresses>
"root" $). Returns "true" when the middleware should be enabled, empty otherwise.
  - Profile on: global.fedramp.ingressIpAllowListEnabled (true in values.yaml, and true if the key
    is missing). The per-service override is ignored.
  - Profile off: the per-service override.
Whenever the middleware would be enabled, the chart also fails the render rather than publishing a
route that looks protected but is not:
  - Unless skipIngressClassCheck is set, ingress.ingressClassName must be "traefik": the allow-list
    is enforced through a Traefik Middleware referenced from a standard Ingress's annotations, which
    a different ingress class does not honor, so the annotations are simply ignored and the route
    publishes unrestricted (templates/feature-server/v2-api-ingress.yaml fails the same way for its
    own Traefik-only controls).
  - sourceRange is rejected by vg.fedramp.rejectUnsafeCidrs above (mapped addresses, prefixes
    shorter than the floor).
  - extraAnnotations must not set the generated router.middlewares annotation: that annotation
    already carries the enforced allow-list, and extraAnnotations renders after it, so a value set
    there would silently replace it — the same bug this chart fixes for jaeger's own middlewares.
    extraAnnotations is rendered the same way the ingress itself renders it
    (vg.common.tplvalues.render, templates/_helpers.tpl, which also accepts a plain YAML string)
    before checking for the key, so a harmless string-valued extraAnnotations does not fail here
    just because hasKey needs a map.
*/}}
{{- define "vg.fedramp.ingressIpAllowListEnabled" -}}
{{- $enabled := .override -}}
{{- if include "vg.fedramp.enabled" .root -}}
{{- $enabled = dig "fedramp" "ingressIpAllowListEnabled" true .root.Values.global -}}
{{- end -}}
{{- if $enabled -}}
{{- if and (not .skipIngressClassCheck) (ne .root.Values.ingress.ingressClassName "traefik") -}}
{{- fail (printf "ingress.%s.ipWhiteListMiddleware would be enabled, but ingress.ingressClassName is %q: the allow-list is a Traefik Middleware referenced from this service's standard Ingress annotations, which that ingress class would not honor, publishing the route with no IP restriction at all. Set ingress.ingressClassName to traefik, or turn the allow-list off for this service (global.fedramp.ingressIpAllowListEnabled: false is a documented deviation while the profile is on)." .service .root.Values.ingress.ingressClassName) -}}
{{- end -}}
{{/* An empty sourceRange is rejected outright rather than relying on how Traefik's ipAllowList
happens to behave with zero entries (fail closed or fail open — not documented, and not checked
here): either way an operator who meant to list ranges and left this empty should see a clear error,
not a route that silently does something undocumented. */}}
{{- if not (.sourceRange | default list) -}}
{{- fail (printf "ingress.%s.ipWhiteListMiddleware would be enabled, but ipWhiteList.sourceRange is empty: a Traefik ipAllowList with no entries is not a documented behaviour this chart relies on. List this environment's real allow-listed ranges, or turn the allow-list off for this service (global.fedramp.ingressIpAllowListEnabled: false is a documented deviation while the profile is on)." .service) -}}
{{- end -}}
{{- include "vg.fedramp.rejectUnsafeCidrs" (dict "range" .sourceRange "subject" (printf "ingress.%s.ipWhiteListMiddleware would be enabled, but ipWhiteList.sourceRange includes" .service)) -}}
{{- if .extraAnnotations -}}
{{- $annotations := include "vg.common.tplvalues.render" (dict "value" .extraAnnotations "context" .root) | fromYaml -}}
{{- if hasKey $annotations "traefik.ingress.kubernetes.io/router.middlewares" -}}
{{- fail (printf "ingress.%s.extraAnnotations sets traefik.ingress.kubernetes.io/router.middlewares while the IP allow-list is enforced: a value set there renders after the generated annotation and silently discards it. Add any other middleware this route needs to the chart's own generated chain instead, or turn the allow-list off for this service." .service) -}}
{{- end -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{/*
VG_TLS_KEYLOG_FEDRAMP_LOCKED (CSA-110113 / VDCL-SC13-001; SC-8(1), SC-13, SC-28(1)). TLS keylog
capture writes TLS session keys to a file on the pod, and anyone holding that file can decrypt the
captured traffic. vg-speech-utils' enableTlsKeylog() refuses to start capture while this variable
is "true", and every enable path (dev-config reconciler, signal toggle, direct call) goes through
that function. So the lock sits where keys would be written, not on one of the config paths.
Takes (dict "extraEnvVars" <the pod's own extraEnvVars> "root" $). Returns "true" or empty.
  - Profile on: global.fedramp.tlsKeylogLocked (true in values.yaml, and true if the key is missing).
  - Profile off: empty. There is no per-service key: capture has no chart-level setting to tune.
Rendered on every pod whose image ships vg-speech-utils: feature-server, feature-server-nightly and
api-server. Only images with a vg-speech-utils release that reads the variable honour it; capture
is not wired in any service yet, so an older image has nothing to lock.
An extraEnvVars entry with this name fails the render instead of silently overriding the profile:
it renders after this value, and Kubernetes keeps the last of two equal names.
Do not use `default` on the boolean: it treats false as empty. `dig` keeps an explicit false.
*/}}
{{- define "vg.fedramp.tlsKeylogLocked" -}}
{{- if include "vg.fedramp.enabled" .root -}}
{{- with .extraEnvVars -}}
{{- range include "vg.common.tplvalues.render" (dict "value" . "context" $.root) | fromYamlArray -}}
{{- if and (kindIs "map" .) (eq (toString (get . "name")) "VG_TLS_KEYLOG_FEDRAMP_LOCKED") -}}
{{- fail "extraEnvVars cannot set VG_TLS_KEYLOG_FEDRAMP_LOCKED while global.fedramp.enabled is true: it would override the FedRAMP TLS keylog lock. Set global.fedramp.tlsKeylogLocked instead (docs/009-fedramp-profile.md)." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if dig "fedramp" "tlsKeylogLocked" true .root.Values.global -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
REQUIRE_EXPLICIT_ENCRYPTION_KEYS on the daily-billing-reporting CronJob (KR-68 / CSA-103928; IA-5(7)).
"true" makes vg-api-server refuse its built-in billing signing key. Takes the root context.
Returns "true", "false" or empty.
  - Profile on: global.fedramp.requireExplicitEncryptionKeys (true if the key is missing).
  - Profile off: billing.sendToCentral.requireExplicitEncryptionKeys; null renders nothing, a non-boolean fails.
`dig` keeps an explicit false, `default` would not.
*/}}
{{- define "vg.fedramp.requireExplicitEncryptionKeys" -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- dig "fedramp" "requireExplicitEncryptionKeys" true .Values.global -}}
{{- else -}}
{{- $required := ((.Values.billing).sendToCentral).requireExplicitEncryptionKeys -}}
{{- if kindIs "bool" $required -}}{{ $required }}
{{- else if not (kindIs "invalid" $required) -}}
{{- fail (printf "billing.sendToCentral.requireExplicitEncryptionKeys must be true, false or null, got %v (%s)" $required (kindOf $required)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
