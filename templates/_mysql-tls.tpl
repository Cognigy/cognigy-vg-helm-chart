{{/*
TLS for MySQL (CGY-47155, docs/012-mysql-tls.md).

MySQL negotiates TLS inside its own protocol on 3306, so plaintext and TLS clients share the port and
nothing changes for the meshed clients, which do not ask for TLS. The chart replaces MySQL's
auto-generated certificate (per instance, unknown to any client) with one from a chart-minted CA
(templates/mysql/mysql-tls-secret.yaml), and the clients on the host network require TLS against that CA.
The server does not enforce TLS (require_secure_transport stays off): the client refuses plaintext.
The MySQL side lives in mysql.primary values (configuration, extraVolumes, extraVolumeMounts), the
client side in the client's own template.
*/}}

{{/*
my.cnf [mysqld] lines for the chart's certificate. Rendered from mysql.primary.configuration, which the
mysql subchart passes through tpl. With explicit ssl_* settings MySQL no longer uses its
auto-generated certificate.
- Only AES-GCM suites with ECDHE, TLS 1.2 and 1.3 (NIST SP 800-52r2), as on redis-ha; OpenSSL's
  default list also offers ChaCha20-Poly1305, which is not FIPS-approved.
*/}}
{{- define "vg.mysqlTls.serverConfig" -}}
ssl_ca=/opt/bitnami/mysql/certs-tls/ca.crt
ssl_cert=/opt/bitnami/mysql/certs-tls/tls.crt
ssl_key=/opt/bitnami/mysql/certs-tls/tls.key
tls_version=TLSv1.2,TLSv1.3
ssl_cipher=ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
tls_ciphersuites=TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256
{{- end -}}

{{/*
"true" when MySQL serves the chart's certificate, for the mysql subchart's tpl-rendered values
(primary.configuration, primary.extraVolumes, primary.extraVolumeMounts): there `.` is the subchart,
so .Values.vgTls is mysql.vgTls. Follows the FedRAMP profile (vg.fedramp.mysqlTlsServer).
*/}}
{{- define "vg.mysqlTls.listener" -}}
{{- include "vg.fedramp.mysqlTlsServer" (dict "vgTls" .Values.vgTls "global" .Values.global) -}}
{{- end -}}

{{/* "true" when the in-cluster MySQL serves the chart's certificate. Takes the root context. */}}
{{- define "vg.mysqlTls.enabled" -}}
{{- if and .Values.mysql.enabled (include "vg.fedramp.mysqlTlsServer" (dict "vgTls" .Values.mysql.vgTls "global" .Values.global)) -}}true{{- end -}}
{{- end -}}

{{/*
"true" when the sbc-sip pod requires TLS to MySQL: sbc-sip-sidecar and the db-create-wait init
container. Needs the in-cluster MySQL: the chart can mint a certificate only for a server it deploys.
A topology that cannot carry the TLS connection fails the render instead of leaving the pod on
plaintext: under the FedRAMP profile (global.fedramp.mysqlTls) and when an environment turns on
mysql.vgTls itself, as for redisHa.vgTls.
*/}}
{{- define "vg.mysqlTls.sbcSipSidecar.enabled" -}}
{{- $client := include "vg.fedramp.mysqlTlsClient" (dict "vgTls" .Values.mysql.vgTls "global" .Values.global "client" "sbcSipSidecar") -}}
{{- if and $client (not .Values.mysql.enabled) -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- fail "global.fedramp.mysqlTls needs mysql.enabled: true: the chart mints the MySQL certificate only for the MySQL it deploys. Enable it, or set global.fedramp.mysqlTls: false as a documented deviation and secure the external database's connection separately (docs/012-mysql-tls.md)." -}}
{{- end -}}
{{- fail "mysql.vgTls.enabled needs mysql.enabled: true: the chart mints the MySQL certificate only for the MySQL it deploys. Enable it, or set mysql.vgTls.enabled (or mysql.vgTls.clients.sbcSipSidecar) to false (docs/012-mysql-tls.md)." -}}
{{- end -}}
{{- if $client -}}
{{- /* The server checks first: the certificate names below depend on them. */ -}}
{{- include "vg.mysqlTls.validateServer" . -}}
{{- $names := include "vg.mysqlTls.dnsNames" . | fromYamlArray -}}
{{- if not (has (toString .Values.mysql.host) $names) -}}
{{- fail (printf "MySQL TLS is on, but mysql.host %q is not a name on the MySQL certificate (%s), so the host-name check of sbc-sip would fail. Point mysql.host at the mysql Service (docs/012-mysql-tls.md)." (toString .Values.mysql.host) (join ", " $names)) -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{/*
Refuses a render in which MySQL would not serve the chart's certificate, or serve it under names no
client dials. Takes the root context; included by the TLS Secret, which renders exactly when the
certificate is configured.
- architecture replication renames the Services (mysql-primary, mysql-secondary), and the secondary
  has its own configuration without the certificate.
- primary.existingConfigmap replaces the chart's my.cnf; an override of primary.configuration or the
  volume lists without the TLS part leaves MySQL on its auto-generated certificate, which no client
  trusts, so the clients would fail the handshake.
- Without fullnameOverride the Services get release-derived names that the certificate
  (vg.mysqlTls.dnsNames) does not carry.
- The certificate is mounted 0440 and readable for mysqld only through the subchart's fsGroup. Without
  primary.podSecurityContext (or its fsGroup) mysqld cannot read the key, logs "Failed to set up SSL"
  and starts without TLS, and the clients that require TLS wait forever.
*/}}
{{- define "vg.mysqlTls.validateServer" -}}
{{- $m := .Values.mysql -}}
{{- if eq (toString (dig "architecture" "standalone" $m)) "replication" -}}
{{- fail "MySQL TLS is on, so mysql must keep architecture: standalone: replication renames the Services and the secondary does not load the certificate (docs/012-mysql-tls.md)." -}}
{{- end -}}
{{- if not $m.fullnameOverride -}}
{{- fail "MySQL TLS is on, so mysql.fullnameOverride must be set (mysql): the certificate names and mysql.host use it, and the release-derived names would fail host-name verification (docs/012-mysql-tls.md)." -}}
{{- end -}}
{{- if or (not (dig "primary" "podSecurityContext" "enabled" true $m)) (not (dig "primary" "podSecurityContext" "fsGroup" 1001 $m)) -}}
{{- fail "MySQL TLS is on, so mysql.primary.podSecurityContext must stay enabled with its fsGroup: the certificate Secret is mounted 0440 and mysqld reads it through that group; without it MySQL starts without TLS (docs/012-mysql-tls.md)." -}}
{{- end -}}
{{- if dig "primary" "existingConfigmap" "" $m -}}
{{- fail "MySQL TLS is on, so mysql.primary.existingConfigmap must be empty: it replaces the chart's my.cnf, which carries the certificate (docs/012-mysql-tls.md)." -}}
{{- end -}}
{{- $missing := list -}}
{{- if not (contains "vg.mysqlTls.serverConfig" (toString (dig "primary" "configuration" "" $m))) -}}
{{- $missing = append $missing "mysql.primary.configuration" -}}
{{- end -}}
{{- range $path := list "extraVolumes" "extraVolumeMounts" -}}
{{- if not (contains "mysql-tls" (toString (dig "primary" $path "" $m))) -}}
{{- $missing = append $missing (printf "mysql.primary.%s" $path) -}}
{{- end -}}
{{- end -}}
{{- with $missing -}}
{{- fail (printf "MySQL TLS is on, but %s no longer carries the chart's TLS part: an override replaced it, so MySQL would serve its auto-generated certificate, which no client trusts. Keep the TLS lines from values.yaml in the override (docs/012-mysql-tls.md)." (join ", " .)) -}}
{{- end -}}
{{- end -}}

{{/*
DNS names on the MySQL certificate, as a YAML list: the `mysql` Service (mysql.host; clients dial the
short name) and the headless Service, short and qualified, and the wildcard for the pod names.
No IP addresses: pod IPs change on every restart, and nothing dials MySQL by IP. No `localhost`
either: mysql2 sends no server name when it dials an IP, and Node then checks the certificate against
"localhost". With that name on the certificate, a client dialling any IP would pass the host-name check.
*/}}
{{- define "vg.mysqlTls.dnsNames" -}}
{{- $ns := .Release.Namespace -}}
{{- $domain := .Values.mysql.clusterDomain | default "cluster.local" -}}
{{- $names := list -}}
{{- range $svc := list .Values.mysql.fullnameOverride (printf "%s-headless" .Values.mysql.fullnameOverride) -}}
{{- $names = concat $names (list $svc (printf "%s.%s" $svc $ns) (printf "%s.%s.svc" $svc $ns) (printf "%s.%s.svc.%s" $svc $ns $domain)) -}}
{{- end -}}
{{- $names = append $names (printf "*.%s-headless.%s.svc.%s" .Values.mysql.fullnameOverride $ns $domain) -}}
{{- toYaml $names -}}
{{- end -}}

{{/*
The certificate material of MySQL, as JSON with the base64 values of tls.crt, tls.key and ca.crt.
Reuse before mint, cached in this render (mysql.vgTls._material), with the same reasons and limits as
vg.redisTls.material: the CA stays stable across upgrades, and the Secret and the clients' CA checksum
see the same CA even in the render that mints it.
*/}}
{{- define "vg.mysqlTls.material" -}}
{{- $cache := .Values.mysql.vgTls -}}
{{- if not (hasKey $cache "_material") -}}
{{- $secretName := .Values.mysql.vgTls.secretName -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- /*
  A Secret that exists without ca.crt is refused rather than replaced: that is what an external
  issuer produces, and overwriting it would swap the CA under every client.
*/ -}}
{{- if and $existing $existing.data (not (index $existing.data "ca.crt")) -}}
{{- fail (printf "Secret %q already exists in namespace %q but has no ca.crt, so this chart cannot reuse it and refuses to overwrite it. Delete it and let the chart mint its own pair." $secretName .Release.Namespace) -}}
{{- end -}}
{{- if and $existing $existing.data (index $existing.data "ca.crt") -}}
{{- $_ := set $cache "_material" (dict "tls.crt" (index $existing.data "tls.crt") "tls.key" (index $existing.data "tls.key") "ca.crt" (index $existing.data "ca.crt")) -}}
{{- else -}}
{{- $days := int .Values.mysql.vgTls.certValidityDays -}}
{{- $ca := genCA (printf "%s-ca" .Values.mysql.fullnameOverride) $days -}}
{{- $leaf := genSignedCert (printf "%s.%s.svc" .Values.mysql.fullnameOverride .Release.Namespace) nil (include "vg.mysqlTls.dnsNames" . | fromYamlArray) $days $ca -}}
{{- $_ := set $cache "_material" (dict "tls.crt" (b64enc $leaf.Cert) "tls.key" (b64enc $leaf.Key) "ca.crt" (b64enc $ca.Cert)) -}}
{{- end -}}
{{- end -}}
{{- get $cache "_material" | toJson -}}
{{- end -}}

{{/*
Checksum of the CA as a pod annotation, so a CA that changes rolls the clients that read it at
start. From vg.mysqlTls.material: the reused CA on every upgrade, the new one in the render that
mints it.
*/}}
{{- define "vg.mysqlTls.caChecksum" -}}
checksum/mysql-tls-ca: {{ get (include "vg.mysqlTls.material" . | fromJson) "ca.crt" | sha256sum }}
{{- end -}}

{{/*
Client env for vg-db-helpers (>= 2.1.0). Under the FedRAMP profile an sbcSipSidecar.extraEnvVars
entry named JAMBONES_MYSQL_TLS_CA_FILE, JAMBONES_MYSQL_HOST or JAMBONES_MYSQL_WRITE_HOST (vg-db-helpers'
separate write pool) fails the render: it renders after
this block and would override the profile's TLS, or dial a host that the mysql.host check above has
not seen, without a global.fedramp.* deviation (as for Redis TLS).
*/}}
{{- define "vg.mysqlTls.clientEnv" -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- with .Values.sbcSipSidecar.extraEnvVars -}}
{{- range include "vg.common.tplvalues.render" (dict "value" . "context" $) | fromYamlArray -}}
{{- if and (kindIs "map" .) (has (toString (get . "name")) (list "JAMBONES_MYSQL_TLS_CA_FILE" "JAMBONES_MYSQL_HOST" "JAMBONES_MYSQL_WRITE_HOST")) -}}
{{- fail (printf "sbcSipSidecar.extraEnvVars cannot set %s while global.fedramp.enabled is true: it would override the profile's MySQL TLS. Use global.fedramp.mysqlTls and mysql.host instead (docs/012-mysql-tls.md)." (get . "name")) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
- name: JAMBONES_MYSQL_TLS_CA_FILE
  value: /etc/mysql-tls/ca.crt
{{- end -}}

{{/*
mysql client options of the db-create-wait init container (MySQL 8.0 client): TLS required, the
chart's CA, and the host name checked against the certificate. Without them the client negotiates
TLS (ssl-mode PREFERRED) but verifies nothing.
*/}}
{{- define "vg.mysqlTls.initArgs" -}}
--ssl-mode=VERIFY_IDENTITY --ssl-ca=/etc/mysql-tls/ca.crt --tls-version=TLSv1.2,TLSv1.3
{{- end -}}

{{- define "vg.mysqlTls.clientVolumeMount" -}}
- name: mysql-tls-ca
  mountPath: /etc/mysql-tls
  readOnly: true
{{- end -}}

{{/* Only the CA reaches the clients, never the server key. */}}
{{- define "vg.mysqlTls.clientVolume" -}}
- name: mysql-tls-ca
  secret:
    secretName: {{ .Values.mysql.vgTls.secretName }}
    items:
      - key: ca.crt
        path: ca.crt
{{- end -}}
