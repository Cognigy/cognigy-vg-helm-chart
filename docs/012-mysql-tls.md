# TLS for MySQL

MySQL serves a certificate from a chart-minted CA, and the clients that run on the host network require TLS
against it. Those clients are in the sbc-sip pod: sbc-sip-sidecar and its `db-create-wait` init container. This
is option A of the in-cluster encryption work for FedRAMP SC-8 (CGY-31303), for MySQL (PoC CGY-42571, shipped in
CGY-47155; work map items A2 and A7). The same approach for Redis is in docs/011-redis-tls.md.

## How it differs from Redis

MySQL negotiates TLS inside its own protocol: the client connects to 3306 in plaintext and upgrades the
connection (an `SSLRequest` before authentication). Plaintext and TLS clients therefore share 3306, and no
second port is needed. The meshed clients do not ask for TLS and are unaffected.

MySQL 8 already serves TLS by default, with a certificate it generates on first start
(`MySQL_Server_<version>_Auto_Generated_CA_Certificate`, in the data directory). No client knows that CA, so a
client could only use TLS without verifying the server; that is what the init container did until now. The
chart replaces it with a certificate from its own CA, which it hands to the clients.

## Values

```yaml
mysql:
  vgTls:
    enabled: false           # chart-minted certificate on MySQL, and the Secret
    secretName: mysql-tls
    certValidityDays: 3650
    clients:
      sbcSipSidecar: true    # the sbc-sip pod requires TLS (sidecar and init container)
```

Off by default. With the FedRAMP profile on, `global.fedramp.mysqlTls` (`true`) decides instead and
`mysql.vgTls.*` is ignored (docs/009-fedramp-profile.md).

Only the in-cluster MySQL (`mysql.enabled: true`) is covered; the chart cannot mint a certificate for an external
database. No VG environment uses one today.

The server side is `mysql.primary.configuration` (the subchart's default `my.cnf` plus `ssl_ca`, `ssl_cert`,
`ssl_key`, `tls_version` and the ciphers) and `mysql.primary.extraVolumes` / `extraVolumeMounts`. The subchart
renders them through `tpl`. Because `configuration` replaces the subchart's whole default `my.cnf`, the chart
carries a copy of it; with TLS off it renders byte for byte as the default, which
`ci/render-tests/mysql-tls.test.sh` checks against the packaged subchart. Keep it in step when the mysql subchart
is upgraded.

## Certificate

Minted once and reused, like the Redis one (`vg.mysqlTls.material` in `templates/_mysql-tls.tpl`,
`templates/mysql/mysql-tls-secret.yaml`): RSA 2048, SHA-256, Secret `mysql-tls` with `tls.crt`, `tls.key`,
`ca.crt`. An existing Secret without `ca.crt` is refused rather than overwritten. The Secret carries
`helm.sh/resource-policy: keep`, so an uninstall or turning TLS off leaves it, and a later enable reuses the same CA.
`helm template` and `--dry-run` mint a new pair on every render; that is a render artefact, not a rotation.

DNS names: `mysql` and `mysql-headless` (short, `.<ns>`, `.<ns>.svc`, fully qualified) and
`*.mysql-headless.<ns>.svc.<domain>`. No IP addresses and no `localhost`: mysql2 sends no server name when it
dials an IP, and Node then checks the certificate against `localhost`, so that name would let any IP pass.

The names are fixed when the certificate is minted. A reused Secret keeps them, while the render checks
`mysql.host` against the names computed now. After a change of the namespace, `mysql.fullnameOverride` or
`mysql.clusterDomain`, rotate the certificate as below, or the sbc-sip pods fail the host-name check.

**Rotation.** MySQL does not roll by itself on a new certificate: its configuration does not change. The sbc-sip pods
do roll, through their `checksum/mysql-tls-ca` annotation, and until MySQL serves the new certificate they wait in
the `db-create-wait` init container. Two things follow, both seen on a developer namespace:

- A plain `flux reconcile` does not upgrade an unchanged release, so the deleted Secret is not re-created. Force it.
- The forced upgrade waits for sbc-sip to become ready, and sbc-sip waits for MySQL. Do not wait for the upgrade
  before reloading MySQL, or the upgrade runs into its timeout and the release is marked failed.

```bash
kubectl -n <ns> delete secret mysql-tls
# Forced upgrade, without waiting for it (same as `flux reconcile hr --force`, which blocks)
now=$(date +%s); kubectl -n <ns> annotate --overwrite helmrelease voicegateway \
  reconcile.fluxcd.io/requestedAt="$now" reconcile.fluxcd.io/forceAt="$now"

# Wait until the kubelet has refreshed the mounted Secret (about 10 s after the Secret exists)
kubectl -n <ns> get secret mysql-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial
kubectl -n <ns> exec mysql-0 -c mysql -- openssl x509 -noout -serial -in /opt/bitnami/mysql/certs-tls/tls.crt
# Same serial: load the new certificate without a restart (MySQL 8.0), or restart the mysql-0 pod instead
kubectl -n <ns> exec mysql-0 -c mysql -- bash -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "ALTER INSTANCE RELOAD TLS"'
```

Every roll of sbc-sip, here and on the first rollout, drops the calls on the node being replaced.

## TLS parameters

TLS 1.2 and 1.3, ECDHE with AES-GCM only (NIST SP 800-52r2), as on redis-ha. OpenSSL's default list also offers
ChaCha20-Poly1305, which is not FIPS-approved.

## Clients: the sbc-sip pod

With `clients.sbcSipSidecar` on:

- **sbc-sip-sidecar** gets `JAMBONES_MYSQL_TLS_CA_FILE=/etc/mysql-tls/ca.crt` and only the CA mounted.
  vg-db-helpers >= 2.1.0 (Cognigy/vg-db-helpers#47, in the sidecar from Cognigy/vg-sbc-sip-sidecar#89) then sets
  on its read and write pools:

  ```js
  ssl: { ca, rejectUnauthorized: true, verifyIdentity: true, minVersion: "TLSv1.2" }
  ```

  `verifyIdentity` matters: mysql2 checks the host name against the certificate only with it, and it is off by
  default. With `ssl` set, mysql2 never falls back to plaintext; a server without TLS fails the handshake with
  `HANDSHAKE_NO_SSL_SUPPORT`. A missing or empty CA file fails the sidecar at start.
- **db-create-wait** (init container, MySQL 8.0 client) connects with
  `--ssl-mode=VERIFY_IDENTITY --ssl-ca=/etc/mysql-tls/ca.crt --tls-version=TLSv1.2,TLSv1.3` (item A7).

Both dial `mysql.host`, so the chart refuses a render in which that is not a name on the certificate (an IP, or
another host). Under the profile an `sbcSipSidecar.extraEnvVars` entry named `JAMBONES_MYSQL_TLS_CA_FILE` or
`JAMBONES_MYSQL_HOST` (or `JAMBONES_MYSQL_WRITE_HOST`, vg-db-helpers' write pool) fails the render, because it would
override the profile or bypass that host check.

The meshed clients (sbc-inbound, api-server, feature-server, and their init containers) are unchanged.

## Rollout

- **MySQL restarts once.** Turning TLS on changes `my.cnf`, so the MySQL primary rolls (`checksum/configuration`).
  With the standalone architecture that is a short outage of the database for every VG service; plan it like any
  MySQL restart.
- **Image.** An sbc-sip-sidecar image with vg-db-helpers older than 2.1.0 ignores the variable and stays on
  plaintext, so the chart can ship before the image. The init container needs no new image.
- **Refused renders.** The chart fails the render instead of running a TLS client against a server that does not
  serve the chart's certificate: the profile or `vgTls` with an external MySQL; `architecture: replication` (the
  Services are renamed and the secondary has no certificate); no `fullnameOverride`; `primary.existingConfigmap`
  set; `primary.podSecurityContext` disabled; an override of `primary.configuration` or the volume lists that
  dropped the TLS part; `mysql.host` not on the certificate. Under the profile also an `sbcSipSidecar.extraEnvVars`
  entry named `JAMBONES_MYSQL_TLS_CA_FILE`, `JAMBONES_MYSQL_HOST` or `JAMBONES_MYSQL_WRITE_HOST`.
- **`lookup` is required**, as for Redis: a tool that renders without cluster access would mint a new CA on every
  sync.
- **Overrides of `mysql.primary.*`.** The chart's defaults for `primary.configuration`, `primary.extraVolumes` and
  `primary.extraVolumeMounts` now carry the TLS part, and the two volume keys are strings (tpl-rendered by the
  subchart), no longer lists. An environment that overrides one of them must keep the `vg.mysqlTls.*` lines from
  `values.yaml` and add its own entries inside the string; a list override replaces the string and fails the render
  while TLS is on. `primary.podSecurityContext` must stay enabled with its `fsGroup`: the certificate is mounted
  0440, and without the group mysqld cannot read the key and starts without TLS.

## Verify

```bash
# Server: TLS is up (Enabled Yes) with the chart's certificate; MySQL starts without TLS if it cannot load it
kubectl -n <ns> exec mysql-0 -c mysql -- bash -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e \
  "SELECT PROPERTY, VALUE FROM performance_schema.tls_channel_status WHERE CHANNEL = \"mysql_main\"
     AND PROPERTY IN (\"Enabled\", \"Current_tls_cert\"); SHOW STATUS LIKE \"Ssl_server_not_after\";"'

# Clients: the sbc-sip connections use TLS (sbc-sip runs on the node, so PROCESSLIST_HOST is a node IP)
kubectl -n <ns> exec mysql-0 -c mysql -- bash -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
  "SELECT t.PROCESSLIST_HOST, s.VARIABLE_VALUE AS cipher FROM performance_schema.threads t
   JOIN performance_schema.status_by_thread s USING (THREAD_ID)
   WHERE s.VARIABLE_NAME = \"Ssl_cipher\" AND t.PROCESSLIST_USER = \"jambones\";"'
```

## Not covered yet

- **Server-side enforcement** (work map X8). The server does not enforce TLS (`require_secure_transport` stays off),
  because every meshed client would then have to switch at once; the client refuses plaintext instead. Under STRICT
  mTLS, non-mesh traffic to MySQL has to be allowed on 3306 itself, the port the meshed clients use too, so only a
  server-side rule makes MySQL reject a plaintext client from outside the mesh. Options: a dedicated MySQL account
  for the host-network clients with `REQUIRE SSL`, or `require_secure_transport=ON` with every client on TLS.
- **FIPS** (X13): the MySQL image's OpenSSL and Node's OpenSSL in the sidecar must run as FIPS 140-3 validated
  modules for the connection to count under SC-8(1). MySQL 8.0 is end of life; the image decision covers 8.4.
- **Mesh exception** (X4): a `PeerAuthentication` must accept non-mesh traffic on 3306.
