# TLS for redis-ha

redis-ha serves TLS listeners next to its plaintext ports, so clients that run on the host network can reach
it encrypted. Both such clients are in the sbc-sip pod: sbc-sip-sidecar and drachtio (CGY-45825). This is option A of the in-cluster encryption work
for FedRAMP SC-8 (CGY-31303), scoped to Redis (CGY-42571).

## Why separate TLS ports

The Istio mesh encrypts traffic between meshed pods, but it cannot enroll host-network pods. sbc-sip and
sbc-rtp run on the host network, so their sidecars' Redis traffic is plaintext, and STRICT mTLS would
reject it. Those clients therefore encrypt it themselves.

Turning on TLS on the existing ports is not an option with Sentinel:

- The Bitnami chart's own `tls.enabled` replaces the plaintext port with TLS (`--port 0`), for Redis and
  Sentinel alike. Every client in the namespace would have to switch at the same time, including the meshed
  ones, which the mesh already encrypts.
- Sentinel announces one port per node. A client cannot ask Sentinel for "the TLS port".

So the chart adds a second listener (`tls-port`) and leaves the plaintext one alone:

| | Plaintext (meshed clients) | TLS (host-network clients) |
|---|---|---|
| Redis | 6379 | `redisHa.vgTls.port` (6380) |
| Sentinel | 26379 | `redisHa.vgTls.sentinelPort` (26380) |

A TLS client asks Sentinel on 26380, gets the master as `<pod>.redis-ha-headless.<ns>.svc.<domain>:6379`,
and connects to the same host on 6380. vg-redis does that mapping (`REDIS_TLS_PORT`).

## Values

```yaml
redisHa:
  vgTls:
    enabled: false           # TLS listeners on redis-ha and the certificate Secret
    port: 6380
    sentinelPort: 26380
    secretName: redis-ha-tls
    certValidityDays: 3650
    clients:
      sbcSipSidecar: true    # sbc-sip-sidecar connects over TLS
      drachtio: true         # drachtio in sbc-sip reads its ban lists over TLS
    drachtioMinVersion: "1.3.23"  # older semver drachtio images are refused while drachtio is a TLS client
```

With the FedRAMP profile on (`global.fedramp.enabled`), `global.fedramp.redisTls` decides instead and the
`vgTls.enabled` and `vgTls.clients.*` keys are ignored (docs/009-fedramp-profile.md). The profile also refuses to
render without redis-ha and Sentinel mode, rather than leaving the sidecar on plaintext.

`vgTls` is off by default; the FedRAMP profile turns it on. It only has an effect when `redisHa.enabled` is `true`. A client switches only in
Sentinel mode (`cognigyEnv.FEATURE_REDIS_SENTINEL_MODE_ENABLED: "true"`). Standalone `redis` (the
non-HA Deployment) is unchanged.

The Redis side is set in `redisHa.commonConfiguration`, `redisHa.sentinel.configuration` and the
`extraVolumes`/`extraVolumeMounts` of both containers. The redis subchart renders these through `tpl`,
which lets them follow `vgTls.enabled`. Environments override `redisHa.replica.configuration` for
`maxmemory`, so the TLS lines are kept out of it. An environment that overrides `commonConfiguration`,
`sentinel.configuration` or the volume lists has to keep the TLS part.

## Certificates

The chart creates the CA and the certificates itself (`vg.redisTls.material` in `templates/_redis-tls.tpl`,
the Secrets in `templates/redis/redis-ha-tls-secret.yaml`), following the idiom of
`templates/test-harness/mock-speech-certs.yaml`. Sprig's `genCA` / `genSignedCert` (RSA 2048, SHA-256):

| Secret | Keys | Mounted into |
|---|---|---|
| `redis-ha-tls` | `tls.crt`, `tls.key`, `ca.crt` (the layout cert-manager produces) | redis and sentinel containers of redis-ha |
| `redis-ha-tls-ca` | `ca.crt`, `ca.key` | nothing: the chart signs certificates with it on later renders |
| `redis-ha-tls-client-sbc-sip` | `tls.crt`, `tls.key`, `ca.crt`; CN `sbc-sip` | the sbc-sip pod (sbc-sip-sidecar and drachtio) |

- Every render reads the Secrets back through `lookup`. With the stored CA it rebuilds the CA and reuses the
  certificates it signed, so upgrades and Flux reconciles change nothing. A certificate Secret that is
  missing, lacks `tls.crt` or `tls.key`, or carries a different `ca.crt` is signed anew with the stored CA.
  Only the `ca.crt` text is compared: Helm templates cannot parse a certificate.
- Without the stored CA (first install, a rotation, or a namespace from before client certificates, whose
  CA key was never kept) the chart mints a new CA and both certificates.
- The render caches the result, so the Secrets and the checksums below agree even in the render that
  mints. `helm template` and `--dry-run` have no cluster access and mint on every render; that is a render
  artefact, not a rotation.
- An existing `redis-ha-tls` without `ca.crt` is refused rather than overwritten (an external issuer). The
  chart owns these Secrets; pointing `secretName` at certificates from another issuer is not supported.
- The three Secrets carry `helm.sh/resource-policy: keep`, as `redis-ha-auth` does. An uninstall, a rollback or
  turning TLS off leaves them in place, so turning it on again reuses the CA instead of rolling every client.
  Delete them by hand to clean up.
- DNS names of the server certificate: `redis-ha` and `redis-ha-headless` (short, `.<ns>`, `.<ns>.svc` and
  fully qualified), and `*.redis-ha-headless.<ns>.svc.<domain>` for the node names Sentinel announces. No IP
  addresses and no `localhost`: pod IPs change on every restart, nothing dials redis-ha by IP, and the
  probes use the plaintext ports. The names come from the cluster's Services.
- `redis-ha-tls` carries a hash of those names (annotation `cognigy.com/dns-names-sha256`). When the names
  change (`redisHa.fullnameOverride`, `redisHa.clusterDomain`) the server certificate is signed anew with the
  stored CA and redis-ha rolls; the clients keep theirs. A `redis-ha-tls` from before the annotation is
  re-signed once, on the upgrade that brings it. A `helm rollback` to a revision from before the annotation
  removes it again, so the next upgrade re-signs once more (redis-ha only).

Clients trust only the chart's CA (`REDIS_TLS_CA_FILE`), not the system store.

**Rotation is automatic once a Secret is deleted.** Both sides read their certificates only at start, so
the pods carry checksums of them:

- redis-ha: `checksum/redis-tls` (server certificate and CA), set through `redisHa.replica.podAnnotations`.
  Helm merges an environment's own `podAnnotations` into it; only a `null` or non-map value drops the key.
- sbc-sip: `checksum/redis-tls-client` (client certificate and CA).

| Delete | Effect on the next reconcile |
|---|---|
| `redis-ha-tls-ca` | new CA and both certificates; redis-ha and sbc-sip roll |
| `redis-ha-tls` | new server certificate from the same CA; redis-ha rolls |
| `redis-ha-tls-client-sbc-sip` | new client certificate from the same CA; sbc-sip rolls |

While a new CA rolls out, sidecars on the new CA and Redis nodes still on the old one fail the handshake until
both have restarted (minutes). A namespace that has `redis-ha-tls` from before client certificates goes
through the same re-mint on the upgrade that brings them.

Expiry is not watched: nothing alerts before a certificate expires. All certificates get `certValidityDays`
(10 years by default) from the day they are signed, so a certificate re-signed in year N outlives its CA by N
years and fails with it. Read the CA's end date after the first rollout (see Verify) and set a reminder to
rotate the CA (delete `redis-ha-tls-ca`) well before it. cert-manager would add rotation before expiry.

## TLS parameters

`tls-auth-clients yes`: a client must present a certificate signed by the chart's CA. The TLS ports are a
mesh exception, so this is their own access control next to the Redis password (docs/013-redis-auth.md).
Sentinel has no password, so the certificate is its only client check (CGY-45820, SC-8 work map X8).
Replication and Sentinel's own monitoring stay on the plaintext ports between meshed pods
(`tls-replication no`).

Protocols TLS 1.2 and 1.3, ECDHE with AES-GCM only (NIST SP 800-52r2). OpenSSL's default list also offers
ChaCha20-Poly1305, which is not FIPS-approved.

## Client: sbc-sip-sidecar

With `clients.sbcSipSidecar` on, the sidecar container gets:

| Variable | Value |
|---|---|
| `REDIS_USE_TLS` | `true` |
| `REDIS_TLS_PORT` | `vgTls.port` |
| `REDIS_SENTINEL_USE_TLS` | `true` |
| `REDIS_SENTINEL_PORT` | `vgTls.sentinelPort` (overrides the `cognigy-env` value) |
| `REDIS_TLS_CA_FILE` | `/etc/redis-tls/ca.crt` |
| `REDIS_TLS_CERT_FILE` | `/etc/redis-tls/tls.crt` |
| `REDIS_TLS_KEY_FILE` | `/etc/redis-tls/tls.key` |

`/etc/redis-tls` is the Secret `redis-ha-tls-client-sbc-sip`, mode 0440 and owned by root. The sidecar image runs
as root (a FedRAMP gap; CGY-47520 moves it to a non-root user); with a non-root `runAsUser` in `sbc.sip.podSecurityContext`
it reads the files only through `fsGroup` (any value) or `runAsGroup: 0`. While drachtio is a TLS client too, the chart
adds `fsGroup: 1000` itself (see Client: drachtio); when the sidecar is the only TLS client, the render fails when both
are missing. These need a sidecar image whose
vg-redis supports them: TLS from 2.0.32 (Cognigy/vg-redis#49), the client certificate from 2.0.34
(Cognigy/vg-redis#52; sidecar 2026.24.0-43 and later). An older vg-redis presents no certificate and is refused,
or dials the TLS Sentinel port in plaintext. Ship the chart with a matching image. Outside the profile `clients.sbcSipSidecar: false` keeps the sidecar on plaintext;
under the profile that key is ignored and `global.fedramp.redisTls: false` (a documented deviation) is the only off switch.

vg-redis takes Sentinel mode from `FEATURE_REDIS_SENTINEL_MODE_ENABLED` and `REDIS_SENTINEL_HOST` / `REDIS_SENTINEL_PORT`.
The sidecar's `JAMBONES_REDIS_SENTINELS` and `JAMBONES_REDIS_HOST` / `PORT` only feed its own startup checks and do not
open a connection in Sentinel mode. With the TLS port remapped, vg-redis turns Sentinel discovery off, so it never
follows the plaintext 26379 that Sentinel announces for its peers.

## Client: drachtio

drachtio in sbc-sip reads the ban lists from Redis: the API-ban set, the tmpbans that sbc-inbound and
sbc-sip-sidecar write, the REGISTER-spam counter and the carrier allowlist. drachtio is the only component that
enforces tmpbans, so turning the connection off is not an option (the SIP equivalents of AC-7 and SC-5). With
`clients.drachtio` on, the drachtio container gets:

| Option | Value |
|---|---|
| `--blacklist-redis-sentinels` | `<REDIS_SENTINEL_HOST>:<vgTls.sentinelPort>` |
| `--blacklist-redis-tls` | |
| `--blacklist-redis-tls-ca-file` | `/etc/redis-tls/ca.crt` |
| `--blacklist-redis-tls-cert-file` | `/etc/redis-tls/tls.crt`, the sbc-sip pod's client certificate (CN `sbc-sip`) |
| `--blacklist-redis-tls-key-file` | `/etc/redis-tls/tls.key` |
| `--blacklist-redis-tls-port` | `vgTls.port`, dialed instead of the port Sentinel announces |

The files come from the same `redis-ha-tls-client-sbc-sip` mount as the sidecar's: both containers are the sbc-sip
pod, and redis-ha asks every TLS client for a certificate (`tls-auth-clients yes`), Sentinel included.

The vg-drachtio image runs as uid/gid 1000 (`USER drachtio`, since 1.3.16), and the files are 0440 and owned by
root. With drachtio on TLS the chart therefore gives the sbc-sip pod `fsGroup: 1000` unless
`sbc.sip.podSecurityContext` already sets an `fsGroup` (`vg.sbc.sip.podSecurityContext`): kubelet gives the Secret
files that group, and every container gets it as a supplementary group. That applies to every Secret, ConfigMap
and emptyDir of the pod: the cluster signing key (docs/008) becomes root:1000 0400 as well, which changes nothing
in practice because only sbc-sip-sidecar mounts it and group read stays off.

drachtio verifies the name it dials (`redis-ha-headless`, then the node names Sentinel announces), allows TLS 1.2
and 1.3 with ECDHE and AES-GCM only, and keeps one TLS connection to the master for the calls it makes on every
REGISTER. It refuses to start when the CA, the certificate or the key cannot be loaded and never falls back to plaintext (vg-drachtio
`docs/redis-tls.md`). The password it already sends (docs/013-redis-auth.md) now travels inside TLS.

These options need vg-drachtio 1.3.23 or newer. An older drachtio reports them as unrecognised, keeps running
and dials the TLS Sentinel port in plaintext, so every ban-list read fails and tmpbans stop being enforced. The
chart therefore refuses a semver `drachtio.image` below `vgTls.drachtioMinVersion` while drachtio is a TLS
client. A non-semver tag (a branch build) is left alone.

drachtio's Redis options no longer depend on `apiBan.enabled`. That key switches the update-api-ban-list
CronJob, which fills the API-ban set from APIBAN. Tying drachtio's connection to it also switched off tmpban
enforcement, the REGISTER-spam ban and `--reject-register-with-no-realm` whenever the feed was off.

## Rollout

- **Image first.** The sidecar image must carry a vg-redis with client certificates (2.0.34, Cognigy/vg-redis#52) before an
  environment turns TLS on; with the profile on, that is any environment taking this chart with redis-ha in Sentinel
  mode. The chart's default `sbcSipSidecar.image` has it from 2026.24.0-43. Chart preview 2026.24.0-42 already requires
  client certificates but still defaults to an older sidecar: do not deploy it with Redis TLS on unless
  `sbcSipSidecar.image` is pinned to 2026.24.0-43 or later. The same holds for drachtio: `drachtio.image` must be
  vg-drachtio 1.3.23 or newer, which the chart enforces (`vgTls.drachtioMinVersion`).
- **Non-root sbc-sip.** While drachtio is a TLS client (the default, and always under the profile) the chart adds
  `fsGroup: 1000` unless `sbc.sip.podSecurityContext` sets one. With the sidecar as the only TLS client, check the
  environment's `sbc.sip.podSecurityContext` for a non-root `runAsUser` and add `fsGroup` before the upgrade; without
  it (or `runAsGroup: 0`) the render fails (see above). Prefer `fsGroup`: it also covers the other root-owned files
  mounted into the pod. Charts with only the CA mount (2026.24.0-20 to -41)
  rendered such an environment.
- **Server and client in the same upgrade.** redis-ha gets its listeners and sbc-sip switches over in one release, and
  both roll. While a redis-ha node restarts, a sidecar can fail to reach it for a few seconds (seen on a developer
  namespace: 7 s); it reconnects by itself. redis-ha also rolls once on this upgrade even with TLS off: Bitnami renders
  the non-empty `sentinel.configuration` as an extra blank line, and the pods get the (empty) `checksum/redis-tls`
  annotation.
- **Refused renders.** The chart fails the render instead of running a TLS client against ports that do not exist:
  the profile without redis-ha in Sentinel mode; `vgTls` on without them; redis-ha without Sentinel, with
  `architecture: standalone` (the master would get the TLS lines but no certificate), or without `fullnameOverride`;
  and an override of `commonConfiguration`, `sentinel.configuration` or the volume lists that dropped the TLS part.
- **`lookup` is required.** The certificate is reused through `lookup`, which Flux and `helm upgrade` provide. A tool that
  renders without cluster access (`helm template` piped to `kubectl apply`, Argo CD) would mint a new CA on every sync,
  and both checksums would change with it: redis-ha and sbc-sip would roll on every sync, and every sbc-sip restart
  drops its calls. Such renderers are not supported with Redis TLS.
- **Upgrade effects of CGY-45825.** Four are intended but visible:
  - Installs with `apiBan.enabled: false` now give drachtio its Redis options too, so the sbc-sip pods open
    Redis connections from the host network, enforce tmpbans and the REGISTER-spam ban, and reject
    realm-less REGISTERs (`drachtio.rejectRegisterWithNoRealm`, default `true`; set it to `false` to keep
    accepting them). While the sbc-sip pods roll, old and new pods disagree on realm-less REGISTERs.
  - `drachtio.image` is shared by sbc-sip, feature-server (main and nightly) and vg-connector, so raising it
    to 1.3.23 restarts all of them, feature-server with its call-draining grace period. The tag must be
    published before the upgrade.
  - A listener-only setup (`vgTls.enabled: true`, `clients.sbcSipSidecar: false`, no Sentinel mode) no longer
    renders, because `clients.drachtio` defaults to `true`. Set `redisHa.vgTls.clients.drachtio: false` too.
  - The image guards judge suffixed and digest-pinned release tags by their X.Y.Z core: `apiBan.image` (with Redis
    auth) and `drachtio.image` (with drachtio on TLS) pinned below the minimum as `1.3.0-fips` or `…@sha256:…` now
    fail the render, where they passed before. Raise the image, or, for a build known to carry the support, set
    `redisHa.vgAuth.apiBanMinVersion` / `redisHa.vgTls.drachtioMinVersion` to `""`.
- **Rollback trigger.** No alert fires when the sidecar cannot reach Redis over TLS: its liveness does not depend on
  Redis and the exporter scrapes 6379. Watch the sidecar log for `All sentinels are unreachable` lasting more than
  two minutes after the roll, and turn TLS off (`global.fedramp.redisTls: false`) if it persists. For drachtio,
  `drachtio_blacklist_last_refresh_timestamp_seconds{source="tmpban"}` advances every 60 s (drachtio's default tmpban
  refresh, which the chart does not override); older than 180 s after the roll means drachtio cannot read the bans. It
  is exported as 0 from start-up, so a pod that never reaches Redis shows up too. `drachtio_blacklist_redis_errors_total`
  rising means the REGISTER-spam ban cannot reach the master. The drachtio log names the reason
  (`Redis TLS to <host> failed: ...`). Both metrics are scraped only with `podMonitors.enabled`; the chart ships no
  alert for them yet, and the drachtio container has no probe that would fail on it.
- **TLS off.** The three Secrets stay (`resource-policy: keep`), so a present `redis-ha-tls` does not mean TLS is
  on. TLS is off when the redis-ha pods carry `checksum/redis-tls: ''` and `client list` shows no connection on
  6380 (see Verify).

## Verify

```bash
# Server: plaintext and TLS listeners
# (the server certificate also serves as a client certificate here: same CA, client auth allowed)
kubectl -n <ns> exec redis-ha-node-0 -c redis -- bash -c '
  T="--tls --cacert /opt/bitnami/redis/certs-tls/ca.crt --cert /opt/bitnami/redis/certs-tls/tls.crt --key /opt/bitnami/redis/certs-tls/tls.key"
  REDISCLI_AUTH=$REDIS_PASSWORD redis-cli -p 6379 ping
  REDISCLI_AUTH=$REDIS_PASSWORD redis-cli $T -h redis-ha-headless -p 6380 ping
  redis-cli $T -h redis-ha-headless -p 26380 sentinel get-master-addr-by-name mymaster
  redis-cli --tls --cacert /opt/bitnami/redis/certs-tls/ca.crt -h redis-ha-headless -p 26380 ping   # refused: no client certificate'

# Clients: the established connections of the sidecar and of drachtio go to 6380 on the master
kubectl -n <ns> exec redis-ha-node-0 -c redis -- bash -c 'REDISCLI_AUTH=$REDIS_PASSWORD redis-cli -p 6379 client list' | grep 6380

# Expiry: end dates of the CA and both certificates (note the CA's for a rotation reminder)
for s in redis-ha-tls-ca:ca.crt redis-ha-tls:tls.crt redis-ha-tls-client-sbc-sip:tls.crt; do
  k=${s#*:}
  printf '%s ' "${s%%:*}"
  kubectl -n <ns> get secret "${s%%:*}" -o jsonpath="{.data.${k//./\\.}}" | base64 -d | openssl x509 -noout -enddate
done

# drachtio (host network, metrics on --prometheus-scrape-port 8088): the tmpban refresh timestamp advances every
# 60 s and the Redis error counter stays at 0
kubectl -n <ns> port-forward sbc-sip-0 8088 &
curl -s localhost:8088/metrics | grep -E 'drachtio_blacklist_(last_refresh_timestamp_seconds\{source="tmpban"|redis_errors_total)'
# A drachtio that refuses its TLS material restarts: read the reason from the previous container
kubectl -n <ns> logs sbc-sip-0 -c drachtio --previous | grep -i 'tls'
```

Handshake failures show up in the Sentinel and Redis logs as `Error accepting a client connection`. On the
client, ioredis reports them only as "All sentinels are unreachable"; `DEBUG=ioredis:*` shows the TLS
error (for example `self-signed certificate in certificate chain` or `ERR_TLS_CERT_ALTNAME_INVALID`).
drachtio logs the OpenSSL reason itself (`Blacklist::… Redis TLS to <host> failed: … (certificate verify failed)`),
and refuses to start when it cannot read the CA, the certificate or the key.

## Not covered yet

- FIPS: the encryption counts for SC-8(1) only if a FIPS 140-3 validated module performs it, on both ends
  (Node's OpenSSL in the sidecar, drachtio's OpenSSL 3, OpenSSL in the Redis image), and the certificate's key is generated in
  one. Helm's Go crypto is not running in FIPS mode.
- The mesh exception: under STRICT mTLS, a `PeerAuthentication` must accept non-mesh traffic on 6380 and
  26380 only.
- Other host-network clients: none. rtp-engine-sidecar no longer connects to Redis (CGY-42736).
