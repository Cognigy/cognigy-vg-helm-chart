{{/*
TLS listeners on redis-ha (CGY-42571, CGY-45820, docs/011-redis-tls.md).

redis-ha keeps its plaintext ports (6379 redis, 26379 sentinel) for the meshed clients and
adds TLS listeners next to them (redisHa.vgTls.port / sentinelPort) for the clients that run
on the host network, where the mesh cannot encrypt. The Redis side lives in redisHa values
(commonConfiguration, sentinel.configuration, extraVolumes), the certificate in
templates/redis/redis-ha-tls-secret.yaml, the client side in the client's own template.
*/}}

{{/*
redis.conf / sentinel.conf lines for one TLS listener. Rendered from redisHa values
(commonConfiguration, sentinel.configuration), which the redis subchart passes through tpl.
Takes (dict "port" <port> "dir" <mount path of the certificate Secret>).

- tls-auth-clients yes: a client must present a certificate from the chart's CA (vg.redisTls.material).
  The TLS ports are a mesh exception, so this is their own access control next to the Redis
  password (CGY-45820, X8); Sentinel has no password, so it is Sentinel's only client check.
- tls-replication stays off: replication and Sentinel's own monitoring use the plaintext ports
  between meshed pods.
- Only AES-GCM suites with ECDHE, TLS 1.2 and 1.3 (NIST SP 800-52r2); OpenSSL's default list
  also offers ChaCha20-Poly1305, which is not FIPS-approved.
*/}}
{{- define "vg.redisTls.serverConfig" -}}
tls-port {{ .port }}
tls-cert-file {{ .dir }}/tls.crt
tls-key-file {{ .dir }}/tls.key
tls-ca-cert-file {{ .dir }}/ca.crt
tls-auth-clients yes
tls-protocols "TLSv1.2 TLSv1.3"
tls-ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256
tls-prefer-server-ciphers yes
{{- end -}}

{{/*
"true" when redis-ha serves the TLS listeners, for the redis subchart's tpl-rendered values
(commonConfiguration, sentinel.configuration, extraVolumes): there `.` is the subchart, so
.Values.vgTls is redisHa.vgTls. Follows the FedRAMP profile (vg.fedramp.redisTlsServer).
*/}}
{{- define "vg.redisTls.listener" -}}
{{- include "vg.fedramp.redisTlsServer" (dict "vgTls" .Values.vgTls "global" .Values.global) -}}
{{- end -}}

{{/* "true" when redis-ha serves the TLS listeners. Takes the root context. */}}
{{- define "vg.redisTls.enabled" -}}
{{- if and .Values.redisHa.enabled (include "vg.fedramp.redisTlsServer" (dict "vgTls" .Values.redisHa.vgTls "global" .Values.global)) -}}true{{- end -}}
{{- end -}}

{{/*
"true" when a client in the sbc-sip pod connects to redis-ha over TLS. Takes (dict "root" $ "client"
<key under redisHa.vgTls.clients>). Needs Sentinel mode: without it the client addresses
`redis.host`, a Service redis-ha does not create.
A topology that cannot carry the TLS connection fails the render instead of leaving the client
on plaintext: under the FedRAMP profile (global.fedramp.redisTls) and when an environment turns
on redisHa.vgTls itself, as Redis auth does for redisHa.vgAuth.
*/}}
{{- define "vg.redisTls.client.enabled" -}}
{{- $root := .root -}}
{{- $client := include "vg.fedramp.redisTlsClient" (dict "vgTls" $root.Values.redisHa.vgTls "global" $root.Values.global "client" .client) -}}
{{- $sentinel := eq (toString $root.Values.cognigyEnv.FEATURE_REDIS_SENTINEL_MODE_ENABLED) "true" -}}
{{- if and $client (not (and $root.Values.redisHa.enabled $sentinel)) -}}
{{- if include "vg.fedramp.enabled" $root -}}
{{- fail "global.fedramp.redisTls needs redisHa.enabled: true and cognigyEnv.FEATURE_REDIS_SENTINEL_MODE_ENABLED: \"true\": the TLS listeners exist only on redis-ha, and the sbc-sip pod reaches them through Sentinel. Enable both, or set global.fedramp.redisTls: false as a documented deviation (docs/011-redis-tls.md)." -}}
{{- end -}}
{{- fail (printf "redisHa.vgTls.enabled needs redisHa.enabled: true and cognigyEnv.FEATURE_REDIS_SENTINEL_MODE_ENABLED: \"true\": the TLS listeners exist only on redis-ha, and the sbc-sip pod reaches them through Sentinel. Enable both, or set redisHa.vgTls.enabled (or redisHa.vgTls.clients.%s) to false (docs/011-redis-tls.md)." .client) -}}
{{- end -}}
{{- if $client -}}true{{- end -}}
{{- end -}}

{{/* "true" when sbc-sip-sidecar connects to redis-ha over TLS. Takes the root context. */}}
{{- define "vg.redisTls.sbcSipSidecar.enabled" -}}
{{- include "vg.redisTls.client.enabled" (dict "root" . "client" "sbcSipSidecar") -}}
{{- end -}}

{{/*
"true" when drachtio in sbc-sip reads its ban lists from redis-ha over TLS (CGY-45825). Takes the
root context. Refuses a drachtio image that predates the TLS options (vg.redisTls.validateDrachtioImage).
*/}}
{{- define "vg.redisTls.drachtio.enabled" -}}
{{- if include "vg.redisTls.client.enabled" (dict "root" . "client" "drachtio") -}}
{{- include "vg.redisTls.validateDrachtioImage" . -}}
true
{{- end -}}
{{- end -}}

{{/*
"true" when any container of the sbc-sip pod connects over TLS, so the pod mounts the client
certificate and the CA. Takes the root context.
*/}}
{{- define "vg.redisTls.sbcSip.enabled" -}}
{{- if or (include "vg.redisTls.sbcSipSidecar.enabled" .) (include "vg.redisTls.drachtio.enabled" .) -}}true{{- end -}}
{{- end -}}

{{/*
Refuses a drachtio image that predates --blacklist-redis-tls (vg-drachtio, CGY-45825). An older
drachtio reports the options as unrecognised, keeps running, and dials the TLS Sentinel port in
plaintext, so every ban-list read fails and tmpbans stop being enforced. The version comes from
vg.common.imageVersion, as for vg.redisAuth.validateApiBanImage: it judges release tags
(X.Y.Z, with an optional suffix or digest) and leaves other tags to the operator. Takes the root context.
*/}}
{{- define "vg.redisTls.validateDrachtioImage" -}}
{{- $min := .Values.redisHa.vgTls.drachtioMinVersion -}}
{{- $version := include "vg.common.imageVersion" .Values.drachtio.image -}}
{{- if and $min $version (semverCompare (printf "<%s" $min) $version) -}}
{{- fail (printf "Redis TLS switches drachtio in sbc-sip to the TLS ports, which needs vg-drachtio %s or newer (--blacklist-redis-tls). drachtio.image is %s, which ignores the options and dials the TLS port in plaintext, so tmpbans would stop being enforced. Set drachtio.image to a build that carries them, set redisHa.vgTls.clients.drachtio: false outside the FedRAMP profile, or, for a build you know carries them, set redisHa.vgTls.drachtioMinVersion: \"\" (docs/011-redis-tls.md)." $min .Values.drachtio.image) -}}
{{- end -}}
{{- end -}}

{{/*
drachtio's TLS options for the ban lists: the chart CA, the sbc-sip pod's client certificate
(redis-ha requires one, tls-auth-clients yes; the same as sbc-sip-sidecar's, vg.redisTls.clientVolume)
and the Redis TLS port that replaces the plaintext port Sentinel announces. The Sentinel TLS port
is in vg.sbc.sip.drachtioRedisArgs.
*/}}
{{- define "vg.redisTls.drachtioArgs" -}}
- --blacklist-redis-tls
- --blacklist-redis-tls-ca-file
- /etc/redis-tls/ca.crt
- --blacklist-redis-tls-cert-file
- /etc/redis-tls/tls.crt
- --blacklist-redis-tls-key-file
- /etc/redis-tls/tls.key
- --blacklist-redis-tls-port
- {{ .Values.redisHa.vgTls.port | quote }}
{{- end -}}

{{/*
Refuses a render in which redis-ha would load the TLS lines without being able to serve them, or
serve a certificate no client can verify. Takes the root context; included by the TLS Secret,
which renders exactly when the listeners do.
- Without Sentinel, or with architecture standalone, the master loads commonConfiguration too but
  mounts no certificate (the volumes are on the replicas), so it would not start.
- An environment that overrides commonConfiguration, sentinel.configuration or the volume lists
  without the TLS part would leave a client switched to ports that do not exist.
- Without fullnameOverride the Services and pods get release-derived names that the certificate
  (vg.redisTls.dnsNames) does not carry, and the clients dial redis-ha-headless anyway.
*/}}
{{- define "vg.redisTls.validateServer" -}}
{{- $r := .Values.redisHa -}}
{{- if or (not (dig "sentinel" "enabled" true $r)) (eq (toString (dig "architecture" "replication" $r)) "standalone") -}}
{{- fail "Redis TLS is on, so redis-ha must keep Sentinel (redisHa.sentinel.enabled: true) and the replication architecture: the certificate is mounted on the replicas only, and the master of another topology would not start without it (docs/011-redis-tls.md)." -}}
{{- end -}}
{{- if not $r.fullnameOverride -}}
{{- fail "Redis TLS is on, so redisHa.fullnameOverride must be set (redis-ha): the certificate names and the clients' REDIS_SENTINEL_HOST use it, and the release-derived names would fail host-name verification (docs/011-redis-tls.md)." -}}
{{- end -}}
{{- $missing := list -}}
{{- range $path := list "commonConfiguration" "sentinel.configuration" -}}
{{- if not (contains "vg.redisTls.serverConfig" (toString (index (dict "commonConfiguration" $r.commonConfiguration "sentinel.configuration" (dig "sentinel" "configuration" "" $r)) $path))) -}}
{{- $missing = append $missing (printf "redisHa.%s" $path) -}}
{{- end -}}
{{- end -}}
{{- range $path := list "replica.extraVolumes" "replica.extraVolumeMounts" "sentinel.extraVolumeMounts" -}}
{{- if not (contains "redis-tls" (toString (index (dict "replica.extraVolumes" (dig "replica" "extraVolumes" "" $r) "replica.extraVolumeMounts" (dig "replica" "extraVolumeMounts" "" $r) "sentinel.extraVolumeMounts" (dig "sentinel" "extraVolumeMounts" "" $r)) $path))) -}}
{{- $missing = append $missing (printf "redisHa.%s" $path) -}}
{{- end -}}
{{- end -}}
{{- with $missing -}}
{{- fail (printf "Redis TLS is on, but %s no longer carries the chart's TLS part: an override replaced it, so redis-ha would not serve the TLS listeners the clients are switched to. Keep the TLS lines from values.yaml in the override (docs/011-redis-tls.md)." (join ", " .)) -}}
{{- end -}}
{{- end -}}

{{/*
DNS names on the redis-ha certificate, as a YAML list. Clients verify the name they dialled:
- the Service names, short and qualified, because REDIS_SENTINEL_HOST is usually the short
  `redis-ha-headless`;
- the wildcard for the pod names, because Sentinel announces every node as
  `<pod>.redis-ha-headless.<ns>.svc.<clusterDomain>` (announce-hostnames yes);
No IP addresses: pod IPs change on every restart, and nothing dials redis-ha by IP. No `localhost`
either: the chart's own probes use the plaintext ports, and Node checks a client that dials an IP
without a server name against "localhost", so that name would let any IP pass.
Takes (dict "ns" <namespace> "fullname" <redis-ha fullname> "domain" <cluster domain>).
*/}}
{{- define "vg.redisTls.dnsNames" -}}
{{- $names := list -}}
{{- range $svc := list .fullname (printf "%s-headless" .fullname) -}}
{{- $names = concat $names (list $svc (printf "%s.%s" $svc $.ns) (printf "%s.%s.svc" $svc $.ns) (printf "%s.%s.svc.%s" $svc $.ns $.domain)) -}}
{{- end -}}
{{- $names = append $names (printf "*.%s-headless.%s.svc.%s" .fullname .ns .domain) -}}
{{- toYaml $names -}}
{{- end -}}

{{/*
Certificate material of the redis-ha TLS listeners and their clients, as JSON with base64 values:
ca.crt / ca.key (Secret <secretName>-ca, never mounted), tls.crt / tls.key (the server, Secret
<secretName>), client.crt / client.key (the sbc-sip pod, Secret <secretName>-client-sbc-sip).

Reuse before mint, so the CA is stable across upgrades: a fresh one on every reconcile would swap
the certificate under running Redis nodes and invalidate the CA every client holds.
- With the stored CA (<secretName>-ca with ca.crt and ca.key) the chart rebuilds it and reuses the
  server and client certificates it signed. A certificate Secret that is missing, lacks tls.crt
  or tls.key, or carries a different ca.crt is signed anew. Only the ca.crt text is compared;
  Helm templates cannot parse a certificate, so expiry is not checked either (docs/011).
- The server Secret also carries a hash of its DNS names (annotation cognigy.com/dns-names-sha256).
  When the names change (namespace, fullnameOverride, clusterDomain), or the annotation is missing
  (a Secret from before it), the server certificate is signed anew.
- Without it (first install; a rotation that deleted <secretName>-ca; or a namespace from before
  client certificates, whose CA key was never kept) the chart mints a new CA and both
  certificates. The checksums below then roll redis-ha (vg.redisTls.serverChecksum) and sbc-sip
  (vg.redisTls.clientChecksum) in the same reconcile.

A server Secret without ca.crt is refused rather than replaced: that is what an external issuer
produces, and overwriting it would swap the CA under every client.

The result is cached in this render (vgTls._material), so the Secrets and the checksums see the
same certificates even in the render that mints them; the redis subchart's tpl-rendered values
read the same map as the parent chart. lookup returns nothing under `helm template` and
--dry-run, so a local render mints every time; Flux and `helm upgrade` run against the API
server.

Takes (dict "ns" <namespace> "vgTls" <redisHa.vgTls> "global" <global values> "fullname" <redis-ha fullname>
"domain" <cluster domain>). Use vg.redisTls.material from the parent chart.
*/}}
{{- define "vg.redisTls.materialFor" -}}
{{- $cache := .vgTls -}}
{{- if not (hasKey $cache "_material") -}}
{{- $sn := .vgTls.secretName -}}
{{- $days := int .vgTls.certValidityDays -}}
{{- $get := dict "ns" .ns "vgTls" .vgTls "global" .global -}}
{{- $server := include "vg.redisTls.lookupSecret" (merge (dict "name" $sn) $get) | fromJson -}}
{{- $stored := include "vg.redisTls.lookupSecret" (merge (dict "name" (printf "%s-ca" $sn)) $get) | fromJson -}}
{{- $client := include "vg.redisTls.lookupSecret" (merge (dict "name" (printf "%s-client-sbc-sip" $sn)) $get) | fromJson -}}
{{- /* Hash of the names themselves, not of toYaml's text, which a Helm upgrade could format differently. */ -}}
{{- $dnsSum := include "vg.redisTls.dnsNames" . | fromYamlArray | join "," | sha256sum -}}
{{- if and $server.data (not (index $server.data "ca.crt")) -}}
{{- fail (printf "Secret %q already exists in namespace %q but has no ca.crt, so this chart cannot reuse it and refuses to overwrite it. Delete it and let the chart mint its own certificates." $sn .ns) -}}
{{- end -}}
{{- $ca := dict -}}
{{- $m := dict -}}
{{- if and $stored.data (index $stored.data "ca.crt") (index $stored.data "ca.key") -}}
{{- $ca = buildCustomCert (index $stored.data "ca.crt") (index $stored.data "ca.key") -}}
{{- $_ := set $m "ca.crt" (index $stored.data "ca.crt") -}}
{{- $_ := set $m "ca.key" (index $stored.data "ca.key") -}}
{{- else -}}
{{- $ca = genCA (printf "%s-ca" .fullname) $days -}}
{{- $_ := set $m "ca.crt" (b64enc $ca.Cert) -}}
{{- $_ := set $m "ca.key" (b64enc $ca.Key) -}}
{{- end -}}
{{- $_ := set $m "dns-names-sha256" $dnsSum -}}
{{- if and (include "vg.redisTls.reusable" (dict "secret" $server "ca" (get $m "ca.crt"))) (eq (toString (dig "metadata" "annotations" "cognigy.com/dns-names-sha256" "" $server)) $dnsSum) -}}
{{- $_ := set $m "tls.crt" (index $server.data "tls.crt") -}}
{{- $_ := set $m "tls.key" (index $server.data "tls.key") -}}
{{- else -}}
{{- $leaf := genSignedCert (printf "%s.%s.svc" .fullname .ns) nil (include "vg.redisTls.dnsNames" . | fromYamlArray) $days $ca -}}
{{- $_ := set $m "tls.crt" (b64enc $leaf.Cert) -}}
{{- $_ := set $m "tls.key" (b64enc $leaf.Key) -}}
{{- end -}}
{{- if include "vg.redisTls.reusable" (dict "secret" $client "ca" (get $m "ca.crt")) -}}
{{- $_ := set $m "client.crt" (index $client.data "tls.crt") -}}
{{- $_ := set $m "client.key" (index $client.data "tls.key") -}}
{{- else -}}
{{- $leaf := genSignedCert "sbc-sip" nil nil $days $ca -}}
{{- $_ := set $m "client.crt" (b64enc $leaf.Cert) -}}
{{- $_ := set $m "client.key" (b64enc $leaf.Key) -}}
{{- end -}}
{{- $_ := set $cache "_material" $m -}}
{{- end -}}
{{- get $cache "_material" | toJson -}}
{{- end -}}

{{/*
Secret <name> in <ns> as JSON, {} when there is none. `helm template` cannot reach the reuse paths
(lookup returns nothing there), so ci/render-tests/redis-tls.test.sh hands in the Secrets of an
earlier render as vgTls._lookup (Secrets by name); with it set, lookup is not called. Test-only,
not part of the values contract, and refused under the FedRAMP profile: set by mistake it would
replace the stored CA with whatever it holds, or with nothing, and roll redis-ha and sbc-sip on
every reconcile. Takes (dict "ns" "vgTls" "global" "name").
*/}}
{{- define "vg.redisTls.lookupSecret" -}}
{{- if hasKey .vgTls "_lookup" -}}
{{- if include "vg.fedramp.enabled" (dict "Values" (dict "global" .global)) -}}
{{- fail "redisHa.vgTls._lookup is a hook for ci/render-tests/redis-tls.test.sh and cannot be set while global.fedramp.enabled is true: the chart would stop reading its certificate Secrets from the cluster. Remove it from the values." -}}
{{- end -}}
{{- get .vgTls._lookup .name | default dict | toJson -}}
{{- else -}}
{{- lookup "v1" "Secret" .ns .name | toJson -}}
{{- end -}}
{{- end -}}

{{/* "true" when certificate Secret .secret has tls.crt and tls.key and carries CA .ca (base64). */}}
{{- define "vg.redisTls.reusable" -}}
{{- $d := (.secret.data | default dict) -}}
{{- if and (index $d "tls.crt") (index $d "tls.key") (eq (toString (index $d "ca.crt")) .ca) -}}true{{- end -}}
{{- end -}}

{{/* vg.redisTls.materialFor from the parent chart. Takes the root context. */}}
{{- define "vg.redisTls.material" -}}
{{- include "vg.redisTls.materialFor" (dict "ns" .Release.Namespace "vgTls" .Values.redisHa.vgTls "global" .Values.global "fullname" .Values.redisHa.fullnameOverride "domain" (.Values.redisHa.clusterDomain | default "cluster.local")) -}}
{{- end -}}

{{/*
Value of the redis-ha pod annotation checksum/redis-tls (redisHa.replica.podAnnotations, rendered
through tpl by the redis subchart, where `.` is the subchart): a checksum of the server certificate
and its CA, so a certificate the chart signs anew restarts Redis and Sentinel, which read it only
at start. Empty while the TLS listeners are off.
*/}}
{{- define "vg.redisTls.serverChecksum" -}}
{{- if include "vg.redisTls.listener" . -}}
{{- $m := include "vg.redisTls.materialFor" (dict "ns" .Release.Namespace "vgTls" .Values.vgTls "global" .Values.global "fullname" .Values.fullnameOverride "domain" (.Values.clusterDomain | default "cluster.local")) | fromJson -}}
{{ printf "%s%s" (get $m "ca.crt") (get $m "tls.crt") | sha256sum }}
{{- end -}}
{{- end -}}

{{/*
Pod annotation of sbc-sip: a checksum of the client certificate and the CA, so a certificate the
chart signs anew rolls the clients, which read them only at start. Takes the root context.
*/}}
{{- define "vg.redisTls.clientChecksum" -}}
{{- $m := include "vg.redisTls.material" . | fromJson -}}
checksum/redis-tls-client: {{ printf "%s%s" (get $m "ca.crt") (get $m "client.crt") | sha256sum }}
{{- end -}}

{{/*
Client env for Sentinel over TLS with a client certificate (vg-redis >= the CGY-45820 release).
Under the FedRAMP profile an sbcSipSidecar.extraEnvVars entry with one of these names fails the
render: it renders after this block and would override the profile without a global.fedramp.*
deviation (as the keylog lock).
*/}}
{{- define "vg.redisTls.clientEnv" -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- with .Values.sbcSipSidecar.extraEnvVars -}}
{{- range include "vg.common.tplvalues.render" (dict "value" . "context" $) | fromYamlArray -}}
{{- if and (kindIs "map" .) (has (toString (get . "name")) (list "REDIS_USE_TLS" "REDIS_TLS_PORT" "REDIS_SENTINEL_USE_TLS" "REDIS_SENTINEL_PORT" "REDIS_TLS_CA_FILE" "REDIS_TLS_CERT_FILE" "REDIS_TLS_KEY_FILE")) -}}
{{- fail (printf "sbcSipSidecar.extraEnvVars cannot set %s while global.fedramp.enabled is true: it would override the profile's Redis TLS. Use global.fedramp.redisTls instead (docs/011-redis-tls.md)." (get . "name")) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
- name: REDIS_USE_TLS
  value: "true"
- name: REDIS_TLS_PORT
  value: {{ .Values.redisHa.vgTls.port | quote }}
- name: REDIS_SENTINEL_USE_TLS
  value: "true"
- name: REDIS_SENTINEL_PORT
  value: {{ .Values.redisHa.vgTls.sentinelPort | quote }}
- name: REDIS_TLS_CA_FILE
  value: /etc/redis-tls/ca.crt
- name: REDIS_TLS_CERT_FILE
  value: /etc/redis-tls/tls.crt
- name: REDIS_TLS_KEY_FILE
  value: /etc/redis-tls/tls.key
{{- end -}}

{{- define "vg.redisTls.clientVolumeMount" -}}
- name: redis-tls-client
  mountPath: /etc/redis-tls
  readOnly: true
{{- end -}}

{{/*
The sbc-sip pod's client certificate and the CA; never the server key or the CA key. 0440 and owned
by root: a non-root runAsUser reads them only through fsGroup (0 included) or runAsGroup 0. With
drachtio on TLS the chart adds fsGroup 1000 (vg.sbc.sip.podSecurityContext); otherwise a non-root
runAsUser without either is refused (the sidecar image runs as root by default).
*/}}
{{- define "vg.redisTls.clientVolume" -}}
{{- $psc := include "vg.sbc.sip.podSecurityContext" . | fromYaml | default dict -}}
{{- $runAsGroup := index $psc "runAsGroup" -}}
{{- /* Not a string: int reads an unparsable one as 0 (Kubernetes rejects a string there anyway). */ -}}
{{- $rootGroup := and (not (kindIs "invalid" $runAsGroup)) (not (kindIs "string" $runAsGroup)) (eq (int $runAsGroup) 0) -}}
{{- if and $psc.runAsUser (kindIs "invalid" (index $psc "fsGroup")) (not $rootGroup) -}}
{{- fail "sbc.sip.podSecurityContext sets a non-root runAsUser but neither fsGroup nor runAsGroup: 0 while sbc-sip connects to Redis over TLS: the client certificate and key are mounted 0440 and owned by root, so sbc-sip-sidecar could not read them and would fail to connect. Add fsGroup to sbc.sip.podSecurityContext (docs/011-redis-tls.md)." -}}
{{- end -}}
- name: redis-tls-client
  secret:
    secretName: {{ printf "%s-client-sbc-sip" .Values.redisHa.vgTls.secretName }}
    defaultMode: 0440
{{- end -}}
