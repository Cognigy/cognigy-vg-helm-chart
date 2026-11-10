{{/*
Separate InfluxDB retention for VG-in-AI call data (influxdb.aiRetention).
See docs/015-vg-events-api.md, "Retention of AI-path call data".

CDRs and alerts of calls admitted on the AI path (tagged organisationId /
projectId / endpointId, no account_sid) are written by @jambonz/time-series to
the NON-default retention policy named here, on the `cdrs` and `alerts`
databases. Legacy data stays in the default policy (`autogen`, infinite). The
library never creates policies, so the influxdb-ai-retention hook Job does.
*/}}

{{/*
Fails the render on an invalid policy name or duration. Renders nothing.
The name regex is the library's own (runtimeRetentionPolicy), so a name the
chart accepts is never rejected by the services at startup.
*/}}
{{- define "vg.influxdb.aiRetention.validate" -}}
{{- $r := .Values.influxdb.aiRetention | default dict -}}
{{- if $r.enabled -}}
{{- $name := toString ($r.policyName | default "") -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]{0,63}$" $name) -}}
{{- fail (printf "influxdb.aiRetention.policyName %q is invalid: it must match ^[A-Za-z_][A-Za-z0-9_]{0,63}$ (letters, digits, underscore; not starting with a digit; at most 64 characters)" $name) -}}
{{- end -}}
{{- if eq $name "autogen" -}}
{{- fail "influxdb.aiRetention.policyName must not be \"autogen\": that is the default policy legacy data lives in, and the AI policy must be a separate, non-default one" -}}
{{- end -}}
{{- $d := toString ($r.duration | default "") -}}
{{- if not (regexMatch "^[1-9][0-9]*[hdw]$" $d) -}}
{{- fail (printf "influxdb.aiRetention.duration %q is invalid: use a positive whole number of hours, days or weeks, e.g. 720h, 30d or 4w (InfluxDB's minimum is 1h; 0/INF is not allowed)" $d) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The shard group duration InfluxDB itself picks for a policy of this duration
(< 2d -> 1h, < 180d -> 1d, else 7d). The Job sets it explicitly on CREATE
and on ALTER: an ALTER that only lowers DURATION below the existing shard
duration (e.g. 30d -> 12h, shards of 1d) is rejected by InfluxDB.
*/}}
{{- define "vg.influxdb.aiRetention.shardDuration" -}}
{{- $d := toString .Values.influxdb.aiRetention.duration -}}
{{- $n := trimSuffix "h" (trimSuffix "d" (trimSuffix "w" $d)) | int -}}
{{- $hours := ternary (mul $n 168) (ternary (mul $n 24) $n (hasSuffix "d" $d)) (hasSuffix "w" $d) -}}
{{- if lt $hours 48 -}}1h{{- else if lt $hours 4320 -}}1d{{- else -}}7d{{- end -}}
{{- end -}}

{{/*
The env that points a writer/reader at the AI policy. Renders nothing while
influxdb.aiRetention.enabled is false, so the service keeps everything in the
default policy. Takes the root context; used by sbc-inbound, sbc-outbound,
feature-server (both workloads) and vg-events-api.
*/}}
{{- define "vg.influxdb.aiRetention.env" -}}
{{- include "vg.influxdb.aiRetention.validate" . -}}
{{- $r := .Values.influxdb.aiRetention | default dict -}}
{{- if $r.enabled -}}
- name: JAMBONES_TIME_SERIES_RUNTIME_RETENTION_POLICY
  value: {{ $r.policyName | quote }}
{{- end -}}
{{- end -}}
