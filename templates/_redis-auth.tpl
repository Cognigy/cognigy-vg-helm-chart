{{/*
Authentication on redis-ha (CSA-100703 / APBN-SC28-001, SC-28 / AC-3; docs/013-redis-auth.md).

Without it, anything that can reach redis-ha can rewrite the IP blocklist (apiban:ips) that drachtio
enforces. With it:
  - every connection must log in; the `default` user's password is redis-password;
  - update-api-ban-list logs in as its own ACL user `apiban`, limited to the apiban:* keys;
  - every Redis client in this chart receives its password from the Secret, never from values.

Switch: global.fedramp.redisAuth while the FedRAMP profile is on, redisHa.vgAuth.enabled otherwise.

The Bitnami subchart (17.4.1) reads redisHa.auth.* as plain values, not through tpl, so they cannot
follow the switch. The environment sets them, and the chart fails the render when they do not match
(vg.redisAuth.validate) instead of running clients with a password against a server without one.
*/}}

{{/*
"true" when Redis auth is on, empty otherwise. Takes (dict "vgAuth" <redisHa.vgAuth> "global" <global values>).
Shared by the parent chart and the redis subchart's tpl-rendered values, where `.` is the subchart.
Do not use `default` on these booleans: it treats false as empty. `dig` keeps an explicit false.
*/}}
{{- define "vg.redisAuth.on" -}}
{{- $on := dig "enabled" false (.vgAuth | default dict) -}}
{{- if dig "fedramp" "enabled" false (.global | default dict) -}}
{{- $on = dig "fedramp" "redisAuth" true .global -}}
{{- end -}}
{{- if $on -}}true{{- end -}}
{{- end -}}

{{/* "true" when Redis auth is on. Takes the root context. */}}
{{- define "vg.redisAuth.enabled" -}}
{{- if .Values.redisHa.enabled -}}
{{- include "vg.redisAuth.on" (dict "vgAuth" .Values.redisHa.vgAuth "global" .Values.global) -}}
{{- end -}}
{{- end -}}

{{/*
Same, for the redis subchart's tpl-rendered values (commonConfiguration, replica.extraVolumes,
replica.extraVolumeMounts). There `.` is the subchart, so .Values.vgAuth is redisHa.vgAuth.
*/}}
{{- define "vg.redisAuth.server" -}}
{{- include "vg.redisAuth.on" (dict "vgAuth" .Values.vgAuth "global" .Values.global) -}}
{{- end -}}

{{/*
Refuses a render that would leave clients and server disagreeing about the password:
  - the profile's switch without redis-ha (the standalone `redis` Deployment has no auth support);
  - redisHa.vgAuth.enabled without redis-ha, outside the profile (the switch would render nothing);
  - the switch off while redis-ha still points at the chart's Secret: redis-ha would keep asking for
    a password no client sends (the kept Secret survives switch-off);
  - the switch on but redis-ha not asking for the password, so clients send one nobody checks;
  - the switch on with Sentinel auth, or without Sentinel (the ACL file is mounted on replicas only).
Takes the root context. Included by every template that renders a Redis client.
*/}}
{{- define "vg.redisAuth.validate" -}}
{{- if and (include "vg.fedramp.enabled" .) (dig "fedramp" "redisAuth" true .Values.global) (not .Values.redisHa.enabled) -}}
{{- fail "global.fedramp.redisAuth needs redisHa.enabled: true: only redis-ha supports authentication. Enable redis-ha, or set global.fedramp.redisAuth: false as a documented deviation (docs/013-redis-auth.md)." -}}
{{- end -}}
{{- if and (not (include "vg.fedramp.enabled" .)) (dig "enabled" false .Values.redisHa.vgAuth) (not .Values.redisHa.enabled) -}}
{{- fail "redisHa.vgAuth.enabled needs redisHa.enabled: true: the standalone redis Deployment has no authentication, so the switch would render nothing (docs/013-redis-auth.md)." -}}
{{- end -}}
{{- if and .Values.redisHa.enabled (not (include "vg.redisAuth.enabled" .)) .Values.redisHa.auth.enabled (eq (toString .Values.redisHa.auth.existingSecret) .Values.redisHa.vgAuth.secretName) -}}
{{- fail (printf "Redis auth is off, but redisHa.auth.existingSecret is still %s: redis-ha would keep asking for that password and no client would send it. Set redisHa.auth.enabled: false in the same change. A Secret of your own with that name: set redisHa.vgAuth.secretName to something else (docs/013-redis-auth.md)." .Values.redisHa.vgAuth.secretName) -}}
{{- end -}}
{{- if include "vg.redisAuth.enabled" . -}}
{{- $auth := .Values.redisHa.auth -}}
{{- if not (dig "sentinel" "enabled" true .Values.redisHa) -}}
{{- fail "Redis auth is on, so redisHa.sentinel.enabled must stay true: the ACL file is mounted on the replicas only, and the master of a non-Sentinel redis-ha would not start without it (docs/013-redis-auth.md)." -}}
{{- end -}}
{{- if $auth.sentinel -}}
{{- fail "Redis auth is on, so redisHa.auth.sentinel must stay false: drachtio never sends a Sentinel password and media-processor sets none, so the clients would fail to reach the master (docs/013-redis-auth.md)." -}}
{{- end -}}
{{- if not (and $auth.enabled (eq (toString $auth.existingSecret) .Values.redisHa.vgAuth.secretName) (eq (toString $auth.existingSecretPasswordKey) "redis-password")) -}}
{{- fail (printf "Redis auth is on, so redis-ha must ask for the password: set redisHa.auth.enabled: true, redisHa.auth.existingSecret: %s and redisHa.auth.existingSecretPasswordKey: redis-password (docs/013-redis-auth.md)." .Values.redisHa.vgAuth.secretName) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Password env for a Redis client that logs in as the `default` user. Both names are set: vg-redis reads
JAMBONES_REDIS_PASSWORD (then REDIS_PASSWORD), media-processor and ioredis-based services read
REDIS_PASSWORD. Renders nothing while auth is off, so the manifest is unchanged. Takes the root context.
*/}}
{{- define "vg.redisAuth.clientEnv" -}}
{{- include "vg.redisAuth.validate" . -}}
{{- if include "vg.redisAuth.enabled" . -}}
- name: JAMBONES_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.redisHa.vgAuth.secretName }}
      key: redis-password
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.redisHa.vgAuth.secretName }}
      key: redis-password
{{- end -}}
{{- end -}}

{{/*
Login of update-api-ban-list: its own ACL user (vg-api-ban >= REDIS_USERNAME support, CSA-100703),
not `default`. Renders nothing while auth is off. Takes the root context.
*/}}
{{- define "vg.redisAuth.apiBanEnv" -}}
{{- include "vg.redisAuth.validate" . -}}
{{- if include "vg.redisAuth.enabled" . -}}
{{- include "vg.redisAuth.validateApiBanImage" . -}}
- name: REDIS_USERNAME
  value: apiban
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.redisHa.vgAuth.secretName }}
      key: apiban-password
{{- end -}}
{{- end -}}

{{/*
Refuses a render that would hand the `apiban` ACL user to a client that predates REDIS_USERNAME
support: it ignores the variable, logs in as `default` with the apiban password, and fails
WRONGPASS on every hourly run. The tag is all the chart can see, so this catches the releases
known to predate the support and leaves a non-semver tag alone - choosing an image that carries
it stays the operator's responsibility. Takes the root context.
*/}}
{{- define "vg.redisAuth.validateApiBanImage" -}}
{{- $min := .Values.redisHa.vgAuth.apiBanMinVersion -}}
{{- $tag := last (splitList ":" .Values.apiBan.image) -}}
{{- if and $min (regexMatch "^v?[0-9]+\\.[0-9]+\\.[0-9]+$" $tag) (semverCompare (printf "<%s" $min) $tag) -}}
{{- fail (printf "Redis auth logs update-api-ban-list in as the ACL user `apiban`, which needs vg-api-ban %s or newer (REDIS_USERNAME support). apiBan.image is %s, which ignores it, logs in as `default` with the apiban password and fails WRONGPASS on every run. Set apiBan.image to a build that carries it (docs/013-redis-auth.md)." $min .Values.apiBan.image) -}}
{{- end -}}
{{- end -}}

{{/*
ACL users, rendered into the Secret as users.acl and loaded by redis-ha through `aclfile`.
- default: full access, same password as requirepass (Bitnami passes --requirepass; the file is
  loaded after it and must agree, or the file wins).
- apiban: only what vg-api-ban issues (SADD, EXPIRE, RENAME, PERSIST, DEL, MULTI/EXEC) plus what
  ioredis sends on connect (HELLO, CLIENT SETNAME/SETINFO, SELECT, PING, INFO, and ROLE in sentinel
  mode). Checked on Redis 7.4 with an empty ACL LOG after the job's full command sequence, direct and
  through Sentinel.
Takes (dict "default" <password> "apiban" <password>).
*/}}
{{- define "vg.redisAuth.aclFile" -}}
user default on >{{ .default }} ~* &* +@all
user apiban on >{{ .apiban }} ~apiban:* resetchannels -@all +sadd +expire +rename +persist +del +multi +exec +ping +info +role +hello +select +quit +client|setname +client|setinfo
{{- end -}}
