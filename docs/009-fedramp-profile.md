# FedRAMP profile

> **In movement (2026-11-03).** About 15 open PRs are changing the FedRAMP profile at the same time, and each
> one updates this document on its own. Until they have merged, this page describes `main` only. Check the open
> PRs (labelled or titled `fedramp`) before relying on it.
> [Pending changes](#pending-changes-open-prs) lists what they will require of an environment. The cluster
> prerequisites and the VG ↔ Cognigy.AI connectivity a FedRAMP environment needs are in vg-resources
> [`docs/concepts/041-fedramp-environment-setup.md`](https://github.com/Cognigy/vg-resources/blob/main/docs/concepts/041-fedramp-environment-setup.md).
> Remove this note when the Pending changes table is empty.

One value turns the FedRAMP-specific hardening on for a whole environment:

```yaml
global:
  fedramp:
    enabled: true
```

The values FedRAMP requires live next to that switch, under `global.fedramp`, in `values.yaml`.
`templates/_fedramp.tpl` turns them into each service's own setting. Services never read a "FedRAMP" variable.

## Design

The profile has two goals that pull in opposite directions:

1. **A FedRAMP environment must run with the FedRAMP values.** A value set somewhere else must not weaken a
   control without anyone noticing. A FedRAMP environment's values come from several layers: the chart's
   `values.yaml`, shared Flux values (for example `voicegateway-common-values`) and the environment's own Flux
   values. A per-service key set for an unrelated reason in a shared layer would otherwise reach the FedRAMP
   environment, and nothing in that environment's values would show it.
2. **Operators must be able to relax one control during an incident**, for example when `enforce` drops DTMF
   digits it should accept. They must not have to turn off the whole profile, which would relax every other
   control too.

The chart meets both as follows:

- While `global.fedramp.enabled` is `true`, each feature takes its value from `global.fedramp.<feature>`, and the
  per-service keys are **ignored**. A shared layer can no longer weaken a FedRAMP control by accident.
- The FedRAMP values are chart values, not literals in a template, so an environment's Flux values can still
  override them. Every deviation is then a change to `global.fedramp.*` in that environment's values, right
  next to `enabled: true`. Reviewers and auditors find it in one place, and it can be recorded as a FedRAMP
  deviation (for example in the POA&M).

## How it resolves

| `global.fedramp.enabled` | Value used | Per-service key |
|---|---|---|
| `true` | `global.fedramp.<feature>` (the FedRAMP value from `values.yaml`, unless an environment overrides it) | ignored |
| `false` | the per-service key, for example `sbcInbound.dtmfSourceValidation` | used; `null` renders nothing, so the service keeps its own default |

If `global.fedramp.<feature>` is missing (for example because an overlay set it to `null`), the helper falls back
to the FedRAMP value. A missing key never relaxes a control.

## Features in the profile

| Feature | FedRAMP key | FedRAMP value | Per-service key (profile off) | Default (profile off) | Env var | Control | Introduced by |
|---|---|---|---|---|---|---|---|
| DTMF source validation | `global.fedramp.dtmfSourceValidation` | `enforce` | `sbcInbound.dtmfSourceValidation`, `sbcOutbound.dtmfSourceValidation` | not set (library default `warn`) | `RTPENGINE_DTMF_SOURCE_VALIDATION` | AC-4, SI-10 | vg-rtpengine-utils#32 (CSA-104130) |
| SIPREC signalling TLS | `global.fedramp.siprecRequireTls` | `true` | `sbcInbound.siprecRequireTls`, `sbcOutbound.siprecRequireTls` | not set (library default: off, a non-TLS SRS URL logs a warning and is recorded) | `VG_SIPREC_REQUIRE_TLS` | SC-8 (VSCU-SC8-001) | vg-siprec-client-utils#20 (CSA-109432) |
| StatsD (vg-stats-collector) | `global.fedramp.statsEnabled` | `false` (off) | `stats.enabled` | `true` (on) | `ENABLE_METRICS`, `STATS_*`, telegraf statsd input and Service | SC-8, SC-8(1), SC-13 (STAT-SC8-001) | CGY-40434 |
| vg-api-ban strict ranges | `global.fedramp.apiBanStrictRanges` | `true` | `apiBan.strictRanges` | `false` (a malformed entry is logged and skipped) | `API_BAN_STRICT_RANGES` | SI-10 (APBN-SI10-002) | vg-api-ban#24 (CSA-100695) |
| vg-api-ban redirects | `global.fedramp.apiBanMaxRedirects` | `0` | `apiBan.maxRedirects` | `0` | `API_BAN_MAX_REDIRECTS` | SC-8 (APBN-SC8-001) | vg-api-ban#24 |
| vg-api-ban timeout | `global.fedramp.apiBanTimeoutMs` | `30000` | `apiBan.timeoutMs` | `30000` | `API_BAN_TIMEOUT_MS` | SI-10 | vg-api-ban#24 |
| vg-api-ban feed batches | `global.fedramp.apiBanMaxBatches` | `1000` | `apiBan.maxBatches` | `1000` | `API_BAN_MAX_BATCHES` | SI-10 | vg-api-ban#24 |
| Internal DTLS-SRTP (rtpengine <-> FreeSWITCH) | `global.fedramp.internalDtls` | `true` (an `extraEnvVars` entry named `INTERNAL_DTLS_ENABLED` on feature-server, feature-server-nightly, freeswitch or sbc-inbound fails the render) | `internalDtls.enabled` | `false` | `INTERNAL_DTLS_ENABLED` on feature-server, sbc-inbound and the freeswitch container | SC-8, SC-13 | CGY-41197 |
| rtpengine DTLS ciphers | `global.fedramp.internalDtlsCiphers` | `ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384` | `rtpEngine.dtlsCiphers` | empty (rtpengine default) | rtpengine `--dtls-ciphers` | SC-13 | CGY-41197 |
| sbc-sip-sidecar alerts (vg-time-series -> InfluxDB) | `global.fedramp.sbcSipSidecarAlerts` | `false` (off) | none | on (`JAMBONES_TIME_SERIES_HOST` rendered) | `JAMBONES_TIME_SERIES_HOST` on the `sbc-sip-sidecar` container | SC-8 | CGY-42786 |
| sbc-sip-sidecar runtime regbots (AI-side carriers, via vg-resource-resolver) | `global.fedramp.sbcSipRuntimeRegbots` | `false` (off) | `sbcSipSidecar.runtimeRegbots.enabled` | `true` | `REGBOT_RUNTIME_TARGETS_ENABLED`, `RESOURCE_RESOLVER_URL`, `SERVICE_AUTH_SIGNING_KEY_PATH` and the `vg-service-key-sbc-sip-sidecar` mount (plus `SERVICE_AUTH_REQUIRE_SIGNING_KEY` under the profile) on the `sbc-sip-sidecar` container. Turning it on under the profile needs a sidecar image with vg-sbc-sip-sidecar#90: the resolver enforces there and refuses an unsigned poll | SC-8, SC-7, AC-3 | CGY-42786, CGY-43686 |
| vg-api-server session-key digest | `global.fedramp.apiSessionKeyDigest` | `sha256` | `api.sessionKeyDigest` | not set (service default `md5`) | `SESSION_KEY_DIGEST` | SC-13 (APIS-SC13-001) | vg-api-server#299 (CSA-101833) |
| vg-api-server strict registration-hook validation | `global.fedramp.apiStrictRegistrationHookValidation` | `true` | `api.strictRegistrationHookValidationEnabled` | not set (service default) | `FEATURE_STRICT_REGISTRATION_HOOK_VALIDATION_ENABLED` | AC-4 (SSIP-AC4-001) | vg-api-server#289 (CSA-102746) |
| Registration-hook Basic-Auth only over HTTPS (sbc-inbound device INVITE, sbc-sip-sidecar REGISTER) | `global.fedramp.registrationHookBasicAuthHttpsOnly` | `true` (an account whose registration hook has Basic-Auth credentials on a non-HTTPS URL gets SIP 500, and the credentials are not sent) | `sbcInbound.registrationHookBasicAuthHttpsOnly`, `sbcSipSidecar.registrationHookBasicAuthHttpsOnly` | not set (vg-digest-utils default: the credentials are sent, with a warning per attempt) | `FEATURE_REGISTRATION_HOOK_BASIC_AUTH_HTTPS_ONLY_ENABLED` on the `sbc-inbound` and `sbc-sip-sidecar` containers | SC-8 (DGUT-SC8-001) | vg-digest-utils#45 (CSA-102450) |
| Redis authentication (redis-ha) | `global.fedramp.redisAuth` | `true` (needs `redisHa.enabled`, `redisHa.auth.enabled` and `redisHa.auth.existingSecret: redis-ha-auth`; the render fails otherwise) | `redisHa.vgAuth.enabled` | `false` | `REDIS_PASSWORD`, `JAMBONES_REDIS_PASSWORD`, `REDIS_USERNAME` (api-ban), drachtio `--blacklist-redis-password`; see docs/013-redis-auth.md | SC-28, AC-3 (APBN-SC28-001) | CSA-100703 |
| vg-api-server audit-log retention | `global.fedramp.apiAuditLogTtlDays` | `90` (the schema accepts 90 to 99999; an `api.extraEnvVars` entry named `AUDIT_LOG_TTL_DAYS` fails the render) | `auditLogging.cleanup.ttlDays` | `90` | `AUDIT_LOG_TTL_DAYS` | AU-11 (APIS-AU11-001) | vg-api-server#255 (CSA-101837) |
| feature-server `/v1` service-auth mode | `global.fedramp.serviceAuthFeatureServerV1Mode` | `enforce` (`report` is the deviation; `off` fails the render) | `serviceAuth.featureServerV1.mode` | not set: the readiness-marker default, `report` in 2026.23 | `SERVICE_AUTH_MODE` | IA-9 (CSA-102459) | CGY-43682 |
| resource-resolver service-auth mode | `global.fedramp.serviceAuthResolverMode` | `enforce` (`report` is the deviation; `off` fails the render) | `serviceAuth.resolver.mode` | not set: the readiness-marker default, `report` in 2026.23 | `SERVICE_AUTH_MODE` | IA-9 (CSA-102459) | CGY-43682 |
| sbc-call-router basic-auth mode | `global.fedramp.serviceAuthCallRouterMode` | `enforce` (`report` is the deviation; `off` fails the render) | `serviceAuth.callRouter.mode` | not set: `report` | `SERVICE_AUTH_MODE` (vg-sbc-call-router) | IA-9 (ADR-001 §2.8 exception) | CGY-43876 |
| Callers require their signing key | none (follows `global.fedramp.enabled`) | `true`: a missing or unreadable key makes the caller send nothing and keeps it from becoming ready. It fails its startup or readiness probe, and a failed startup probe restarts the container until the key is readable (api-server, sbc-inbound and sbc-outbound have no readiness probe). For sbc-sip-sidecar this applies only while runtime regbots run, and the impact is wider: the failed startup probe restarts the whole `sbc-sip-sidecar` container, which also handles SIP REGISTER, answers carrier OPTIONS and serves its `metrics` port. That sbc-sip pod then does none of these until the key is readable, not only its runtime regbots. The key Job creates every key before the pods roll, so this happens only on a broken install | none | not set: the caller sends unsigned and counts `vg_service_auth_unsigned_total` | `SERVICE_AUTH_REQUIRE_SIGNING_KEY` (api-server, feature-server, sbc-inbound, sbc-outbound, and sbc-sip-sidecar while runtime regbots run) | IA-9 (CSA-102459) | CGY-43682 |
| Password login | `global.fedramp.passwordLogin` | `false` (any other value fails the render) | `api.passwordLoginEnabled` | not set (service default: on) | `VG_PASSWORD_LOGIN_ENABLED` | IA-2(1) (CSA-101834) | CGY-43682; vg-api-server reads it from X1 |
| Admin-scope API keys | `global.fedramp.adminApiKeys` | `false` (any other value fails the render) | `api.adminApiKeysEnabled` | not set (service default: accepted) | `VG_ADMIN_API_KEYS_ENABLED` | IA-2(1) (CSA-101834) | CGY-43682; vg-api-server reads it from X1 |
| Privileged-user bootstrap | `global.fedramp.bootstrapPrivilegedUsers` | `false` (any other value fails the render) | `api.bootstrapPrivilegedUsers` | not set (service default: `admin` and `cognigy-ai` bootstrapped) | `VG_BOOTSTRAP_PRIVILEGED_USERS` | IA-2(1) (CSA-101834) | CGY-43682; vg-api-server reads it from X1 |
| api-migrator FedRAMP mode | `global.fedramp.migratorFedrampMode` | `true` (any other value fails the render) | `apiMigrator.fedrampMode` | not set (service default: off) | `VG_MIGRATOR_FEDRAMP_MODE` | IA-2(1) (CSA-101834) | CGY-43682; the migrator reads it from X5 |
| Default-deny NetworkPolicy (stages 1 to 3: every workload docs/014-network-policy.md lists, not sbc-sip or sbc-rtp; plus update-api-ban-list. Not vg-realtime-bridge: its vendor egress has no stable CIDR, so it keeps its own opt-in `realtimeBridge.networkPolicy`, see docs/014) | `global.fedramp.networkPolicyEnabled` | `true` | each workload's own `networkPolicy.enabled` | `false` (opt-in), except silero-vad's own default of `true` | n/a (Kubernetes `NetworkPolicy` objects, not env vars) | SC-7, AC-4 | CSA-110265, CSA-110267 — see docs/014-network-policy.md; update-api-ban-list: APBN-SC7-001, CSA-100704 |
| Ingress IP allow-list (9 externally-exposed ingresses: api, homer, jaeger, testCallManager, webapp, vgConnector, vgConsole, vgPagerdutyAgent, realtimeBridge; api, webapp, vgConnector and realtimeBridge are on by default, so each needs a real `sourceRange`, or turn the bridge route off with `ingress.realtimeBridge.enabled: false`) | `global.fedramp.ingressIpAllowListEnabled` | `true` (the render fails if `ingress.ingressClassName` is not `traefik` for a standard-Ingress service, `ipWhiteList.sourceRange` contains an IPv4-mapped IPv6 address or a prefix shorter than `/8` (IPv4) or `/32` (IPv6), or `extraAnnotations` sets `router.middlewares`) | `ingress.<service>.ipWhiteListMiddleware.enabled` | `false` | Traefik `Middleware` `ipwhitelist<service>` + the ingress's `router.middlewares` annotation | SC-7 (VHC-SC7-002) | CSA-110266 |
| Traefik entrypoint trust boundary | none (not relaxable; environment-specific) | `traefik.ports.{web,websecure}.{proxyProtocol,forwardedHeaders}.insecure` must be `false` in this environment's own values/Flux overlay — only checked while `traefik.enabled` is `true` (this chart's own Traefik subchart); see the next row for `traefik.enabled: false` | `traefik.ports.*` (same keys; this chart does not change the default for any environment) | `true` (trusts a PROXY-protocol preamble or `X-Forwarded-For` from any caller) | none: the render fails | SC-7 (VHC-SC7-002) | CSA-110266 |
| Traefik entrypoint trust boundary, external Traefik (`traefik.enabled: false`) | `global.fedramp.externalTraefikEntrypointsVerified` | `true`, set only after verifying by hand that the external/shared Traefik does not trust an unauthenticated PROXY-protocol preamble or `X-Forwarded-For` on its web/websecure entry points — `traefik.ports.*` configures only this chart's own (disabled) Traefik subchart, so the chart cannot check the real one itself | none; this key only exists under the profile | not set (the render fails) | none: the render fails | SC-7 (VHC-SC7-002) | CSA-110266 |
| TLS keylog capture (feature-server, feature-server-nightly, api-server) | `global.fedramp.tlsKeylogLocked` | `true` (locked; an `extraEnvVars` entry named `VG_TLS_KEYLOG_FEDRAMP_LOCKED` fails the render) | none | not set (capture follows its callers: dev-config with approval, or the signal toggle) | `VG_TLS_KEYLOG_FEDRAMP_LOCKED` | SC-8(1), SC-13, SC-28(1) (VDCL-SC13-001) | vg-speech-utils (CSA-110113) |
| Redis TLS for host-network clients (sbc-sip-sidecar and drachtio in the sbc-sip pod) | `global.fedramp.redisTls` | `true` (needs redis-ha in Sentinel mode, and drachtio.image >= `redisHa.vgTls.drachtioMinVersion`; the render fails otherwise) | `redisHa.vgTls.enabled`, `redisHa.vgTls.clients.sbcSipSidecar`, `redisHa.vgTls.clients.drachtio` | `false` | `REDIS_USE_TLS`, `REDIS_TLS_PORT`, `REDIS_SENTINEL_USE_TLS`, `REDIS_SENTINEL_PORT`, `REDIS_TLS_CA_FILE`, `REDIS_TLS_CERT_FILE`, `REDIS_TLS_KEY_FILE` on sbc-sip-sidecar; `--blacklist-redis-tls*` (with the pod's client certificate) and the TLS Sentinel port on drachtio; `tls-port` and `tls-auth-clients yes` (client certificate required) on redis-ha | SC-8, SC-8(1) | CGY-42571, CGY-45819, CGY-45820, CGY-45825 |
| MySQL TLS for host-network clients (sbc-sip-sidecar and the sbc-sip `db-create-wait` init container) | `global.fedramp.mysqlTls` | `true` (needs the in-cluster MySQL, `mysql.enabled`; the render fails otherwise) | `mysql.vgTls.enabled`, `mysql.vgTls.clients.sbcSipSidecar` | `false` | `JAMBONES_MYSQL_TLS_CA_FILE` on sbc-sip-sidecar; `--ssl-mode=VERIFY_IDENTITY --ssl-ca` on `db-create-wait`; `ssl_*` in MySQL's `my.cnf` | SC-8, SC-8(1) | CGY-47155 |
| TLS for the drachtio -> sbc-call-router hop (every inbound INVITE) | `global.fedramp.callRouterTls` | `true` (needs drachtio.image >= `sbcCallRouter.tls.drachtioMinVersion` and sbcCallRouter.image >= `sbcCallRouter.tls.minVersion`; the render fails otherwise) | `sbcCallRouter.tls.enabled` | `false` | `HTTP_TLS_CERT_FILE`, `HTTP_TLS_KEY_FILE` on sbc-call-router; `https://` and `ca-file` on drachtio's request-handler in sbc-sip | SC-8, SC-8(1) | CGY-47751 |
| TLS on the drachtio control hop (sbc-sip's drachtio to sbc-inbound / sbc-outbound, `DRACHTIO_PORT` 4000) | `global.fedramp.drachtioControlTls` | `true` (needs vg-drachtio >= `drachtioControlTls.drachtioMinVersion`, 1.3.28, and sbc-inbound, sbc-outbound and sbc-call-router images with CGY-46071 at or above `drachtioControlTls.minImageVersions`, which must be set; an older semver drachtio, an older SBC or call-router image, an empty minimum, or an image tag the chart cannot check fails the render unless `drachtioControlTls.allowUncheckedImages` records a deviation) | `drachtioControlTls.enabled` (`drachtioControlTls.prepare` stages the certificates in both modes) | `false` | `DRACHTIO_OUTBOUND_TLS_CA_FILE`, `_CERT_FILE`, `_KEY_FILE` on drachtio in sbc-sip; `DRACHTIO_LISTEN_TLS_CERT_FILE`, `_KEY_FILE`, `_CA_FILE` on sbc-inbound and sbc-outbound; `DRACHTIO_CONTROL_TRANSPORT=tls` on sbc-call-router; see docs/017-drachtio-control-tls.md | SC-8, SC-8(1); AC-3 (DSRF-AC3-002) | CGY-46071 |
| Built-in billing signing key refused (daily-billing-reporting CronJob) | `global.fedramp.requireExplicitEncryptionKeys` | `true` (the job fails unless `billing.sendToCentral.privateKeySecret` mounts a key that isn't the built-in one) | `billing.sendToCentral.requireExplicitEncryptionKeys` | not set (the built-in key is the fallback) | `REQUIRE_EXPLICIT_ENCRYPTION_KEYS` on the `daily-billing-reporting` container | IA-5(7) (KR-68) | CSA-103928 |

`enforce` assumes the sidecar's DTMF datagrams arrive from the address `sbc.rtp` resolves to. That holds with
`sbc.rtp.useStatefulSet: true`. With `useStatefulSet: false`, the replies come from a node IP and `enforce`
would drop every digit. The chart therefore fails to render `enforce` when `sbc.rtp.useStatefulSet` is `false`.
With the profile on, that topology needs `global.fedramp.dtmfSourceValidation` set to `warn` or `off`, which is a
deviation from FedRAMP.

With `VG_SIPREC_REQUIRE_TLS` on, sbc-inbound and sbc-outbound refuse a SIPREC recording unless the SRS URL (the
`siprecServerURL` of the record verb, sent as `X-Srs-Url`) is a single `sips:` URI, or a `sip:` URI with
`;transport=tls`. The refusal comes before any rtpengine subscription or INVITE: the SBC logs
`event: siprec_srs_url_rejected_not_tls`, answers the feature-server's `startCallRecording` INFO with 503, and the call
goes on unrecorded. A tenant whose recording server only speaks plain SIP therefore loses recording under the profile;
setting `global.fedramp.siprecRequireTls: false` for that environment is a deviation from FedRAMP. The chart always
renders `"true"` or `"false"`, because the library treats any other value as on. The recording media leg stays plain
RTP either way (VSCU-SC8-002). The variable is read only by images whose vg-siprec-client-utils includes
Cognigy/vg-siprec-client-utils#20; older images ignore it. An `extraEnvVars` entry named `VG_SIPREC_REQUIRE_TLS`
overrides the profile, so do not set one in a FedRAMP environment. `ci/render-tests/fedramp-siprec-require-tls.test.sh`
asserts both modes.

StatsD has no transport encryption, so with the profile on it is removed rather than encrypted. To re-enable it in one environment, set `global.fedramp.statsEnabled: true` there. `stats.enabled` is ignored while the profile is on. With the profile off, `stats.enabled` (default `true`) switches it. When StatsD is off: the SBC workloads get `ENABLE_METRICS=0` and no `STATS_*` variable, telegraf renders no `statsd` or `socket_listener` input, and `Service/telegraf` is not created. Telegraf keeps running, so Homer's statistics keep working. Prometheus is unaffected. `scripts/test-stats-flag.sh` asserts both states.

vg-api-ban reads these four variables only from the image of Cognigy/vg-api-ban#24 or later. An older image ignores them. The
CronJob renders them before `apiBan.extraEnvVars`, and Kubernetes keeps the last of two equal names, so an `extraEnvVars`
entry named `API_BAN_*` overrides the profile. Do not set one in a FedRAMP environment. Redirects stay `0` in both
modes because the API key is a path segment and a followed redirect hands it to the redirect target. The feed allowance
(`maxBatches` x 250 addresses) comes out of the 1,000,000 addresses drachtio loads. vg-api-ban therefore derives the range limit
from it and rejects a `maxBatches` above 3999. The chart schema allows 1 to 3999.

sbc-sip runs on the host network, outside the mesh, so the sidecar's plain-HTTP connection to `influxdb:8086` is
refused under STRICT mTLS and is unencrypted. The profile removes the flow instead of moving every InfluxDB client to
TLS. With the profile on, the `sbc-sip-sidecar` container gets no `JAMBONES_TIME_SERIES_HOST`, in both the StatefulSet
and the DaemonSet. The sidecar then writes no `account-device-limit` or OPTIONS ping failure alerts and only logs the
events. These alerts are shown only on the standalone VG portal's Alerts page, which a FedRAMP environment does not use.
To re-enable them in one environment, set `global.fedramp.sbcSipSidecarAlerts: true` there. With the profile off the
variable is always rendered. The sidecar starts without the variable only from the image of Cognigy/vg-sbc-sip-sidecar
CGY-42786 or later; an older image refuses to start, so do not turn the profile on with one. The chart renders
`sbcSipSidecar.extraEnvVars` after this variable, so an `extraEnvVars` entry named `JAMBONES_TIME_SERIES_HOST` restores the
flow without a `global.fedramp.*` deviation. The sidecar also reads the `cognigy-env` ConfigMap through `envFrom`, so a
`cognigyEnv.JAMBONES_TIME_SERIES_HOST` key restores it the same way once the profile drops the variable. Do not set
either in a FedRAMP environment.
`ci/render-tests/fedramp-sbc-sip-sidecar-alerts.test.sh` asserts both topologies.

The runtime regbots of `sbc-sip-sidecar` (`sbcSipSidecar.runtimeRegbots`, CGY-44772) register the carriers configured in
Cognigy.AI that require SIP REGISTER. The sidecar reads them from `vg-resource-resolver:4000` every 60 s. From the host
network that poll is plain HTTP outside the mesh, and the resolver NetworkPolicy below admits a host-networked caller
only by node CIDR, so the poll would time out without one. Until the flow is redesigned, the profile
turns the runtime regbots off: the sidecar gets no `REGBOT_RUNTIME_TARGETS_ENABLED`, `RESOURCE_RESOLVER_URL` or
service key (no `SERVICE_AUTH_*` variables, no `vg-service-key-sbc-sip-sidecar` mount), and register events are not
reported to vg-resources-api. **AI-side carriers that require REGISTER are then not registered.**
A FedRAMP deployment is VG-in-AI only and has no carriers in MySQL, so the MySQL regbots find nothing either: no carrier
is registered. TODO (CGY-45358): FedRAMP will most likely need the feature, which needs an encrypted poll that the resolver
NetworkPolicy admits; the impact is tracked in vg-resources `docs/concepts/039-fedramp-feature-impact.md`. To turn it
on in one environment, set `global.fedramp.sbcSipRuntimeRegbots: true` there. The resolver
policy then also admits `networkPolicy.hostNetworkPeers` (the SIP nodes' CIDR, which every
FedRAMP environment sets anyway for sbc-inbound/outbound); while the regbots are off it does
not, so the port stays closed to the SBC nodes. (`global.fedramp.networkPolicyEnabled: false`
also unblocks the poll, as a second deviation that drops every default-deny NetworkPolicy —
see docs/014-network-policy.md.) `sbcSipSidecar.runtimeRegbots.enabled` has no effect while
the profile is on.
`ci/render-tests/fedramp-sbc-sip-runtime-regbots.test.sh` asserts both topologies.

vg-api-server audit-log retention (`AUDIT_LOG_TTL_DAYS`) cannot be shortened below the AU-11 minimum of 90 days while
the profile is on. The schema accepts a `global.fedramp.apiAuditLogTtlDays` of 90 to 99999, and, unlike the other features,
an `api.extraEnvVars` entry named `AUDIT_LOG_TTL_DAYS` fails the render rather than overriding the profile. To keep
records longer, raise `global.fedramp.apiAuditLogTtlDays`. Before CSA-101837 the chart rendered this setting as
`AUDIT_LOGGING_TTL_DAYS=30`, which vg-api-server never read. `ci/render-tests/fedramp-api-audit-log-ttl.test.sh` asserts
both modes.

The vg-resource-resolver NetworkPolicy (`templates/resource-resolver/networkpolicy.yaml`) is a default-deny
ingress+egress policy under `global.fedramp.networkPolicyEnabled` (stage 1, CSA-110265/CSA-110267) — see
docs/014-network-policy.md for the full design, what it allows, and its known limits (for example: no special
carve-out for the health port, same as `silero-vad`'s pre-existing convention). It has an effect only where the
cluster's CNI enforces NetworkPolicy. Set `global.fedramp.networkPolicyEnabled: false` to deviate (see below).

The ingress IP allow-list forces each of the 8 services' Traefik `Middleware` on while the profile is on, regardless
of that service's own `ipWhiteListMiddleware.enabled`. Either way (profile on or off), enabling the middleware fails
the render instead of publishing a route that looks protected but is not:

- Unless the service is enforced through a Traefik `IngressRoute` rather than a standard `Ingress` (currently only
  `vgConnector`, whose `IngressRoute` specifies its own `entryPoints` and is unaffected by `ingressClassName`),
  `ingress.ingressClassName` must be `traefik`: the allow-list is a Traefik `Middleware` referenced from the
  standard Ingress's annotations, which a different ingress class simply ignores, so the route would publish with
  no IP restriction at all.
- `ipWhiteList.sourceRange` must not contain an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`, or any of its many
  equivalent IPv6 `::` compression spellings) at any prefix length: depending on where the embedded IPv4 address's
  bits land relative to the mask, Go's CIDR matching can normalize a mapped address to a far broader effective
  network than its written prefix suggests (for example `::ffff:0:0/96` becomes every IPv4 address in mapped
  form). Rather than re-deriving the effective network for every spelling and prefix length, mapped notation is
  rejected outright — Traefik accepts plain IPv4 CIDR notation directly (`10.0.0.0/8`, ...), so there is no reason
  to write an IPv4 range in its IPv6-mapped form here.
- `ipWhiteList.sourceRange` must not contain a prefix shorter than `/8` for IPv4, or shorter than `/32` for IPv6
  (`0.0.0.0/0`, `10.0.0.0/4`, `::/0`, `2001:db8::/16`, ...; this is checked per entry, so two entries that only
  look narrow but jointly cover the same prefix shorter than the floor — `0.0.0.0/1` and `128.0.0.0/1` together
  admit every IPv4 address — are each still individually rejected): a prefix that short admits a large enough
  fraction of that address family's space to be, in practice, the same as no allow-list at all.
- `ingress.<service>.extraAnnotations` must not set `traefik.ingress.kubernetes.io/router.middlewares`: that
  annotation is generated to carry the enforced allow-list, and `extraAnnotations` renders after it, so a value set
  there would silently replace it. `extraAnnotations` is rendered the same way the ingress itself renders it
  (`vg.common.tplvalues.render`, which also accepts a plain YAML string) before this check runs, so a harmless
  string-valued `extraAnnotations` does not fail here just because the check needs a map.

`homer` previously had no `Middleware` or ingress annotation at all, so its `ipWhiteListMiddleware.enabled` key did
nothing; both now exist, gated the same way as `templates/homer/ingress.yaml` (`ingress.enabled`, `ingress.homer.enabled`
and `homer.enabled` all required) so the profile does not demand a real CIDR for a Homer that is not even deployed.
`jaeger`'s ingress also used to write its IP allow-list and basic-auth middlewares to the same annotation key, so
whichever rendered second silently discarded the other — both are now combined into one comma-separated
`router.middlewares` value.

Getting the allow-list to actually filter by the real client IP depends on more than just enabling it, and the
right configuration is topology-specific. `traefik.ports.{web,websecure}.proxyProtocol.trustedIPs` and
`.forwardedHeaders.trustedIPs` (not `traefik.entryPoints.*` — `ports` is this chart's top-level key for Traefik's
entry points) both ship `insecure: true` by default, trusting a PROXY-protocol preamble or an `X-Forwarded-For`
header from *any* caller able to reach the entrypoint — not just the real proxy. With
`ipWhiteListMiddleware`'s default `ipStrategy.depth: 0` (the only value any service in this chart sets), only
`proxyProtocol.insecure: true` is an actual allow-list bypass: a trusted PROXY preamble directly supplies the
remote address that `depth: 0` reads, so a caller could forge one and claim an allow-listed address regardless of
`sourceRange`. `forwardedHeaders.insecure: true` has no effect on the allow-list by itself under that default,
since `depth: 0` does not read `X-Forwarded-For` at all — but it is still hardened here, both because a backend
or other middleware may use the header for other purposes (HTTPS redirects, absolute URLs, logging) and because
raising `depth` later without also tightening forwarded-header trust would silently reopen the same class of
bypass. This chart does not change either default for any environment (see the "Traefik entrypoint trust
boundary" row above) — while the profile is on, this environment's own values/Flux overlay must set
`insecure: false` for both ports and both settings. **This is not safe on its own if the load balancer
actually sends a PROXY preamble or `X-Forwarded-For`**: the vendored Traefik chart only emits each
`--entryPoints.<port>.<proxyProtocol|forwardedHeaders>.{insecure,trustedIPs}` CLI flag when its value is
truthy (`charts/traefik`'s `templates/_podtemplate.tpl`), so `insecure: false` with `trustedIPs: []` (the
empty default) passes neither flag — PROXY-protocol/forwarded-header parsing is not configured at all on
that entry point, and a real PROXY preamble or trusted forwarded header then fails to parse as a normal
request. Set `trustedIPs` to this environment's real proxy/load-balancer address **in the same overlay
change** as `insecure: false`, for whichever of the two topologies below actually applies — do not set
`insecure: false` alone and assume the render passing means the entry point is correctly configured. From
there, PROXY-protocol trust and forwarded-header trust are **not interchangeable** — each needs its own
`ipWhiteListMiddleware` `ipStrategy.depth` setting, and applying one topology's guidance to the other blocks
every real client:

- **Trusted PROXY protocol** (an L4 load balancer/proxy in front of Traefik that speaks the PROXY protocol): set
  `proxyProtocol.trustedIPs` to that proxy's own address. Traefik then takes the connection's remote address
  straight from the trusted PROXY preamble, which is exactly what `ipWhiteListMiddleware`'s default
  `ipStrategy.depth: 0` reads (a depth of 0 or less means "the connection's own remote address"). Leave `depth` at
  `0` — do not raise it, and do not also set `forwardedHeaders.trustedIPs` for this proxy: unless it also sends
  `X-Forwarded-For`, raising `depth` makes Traefik look for a header that never arrives and reject every real
  client.
- **Trusted forwarded headers** (an L7 proxy/load balancer that terminates the connection and adds
  `X-Forwarded-For`): set `forwardedHeaders.trustedIPs` to that proxy's own address. The connection's remote address
  is now the proxy's, not the client's, so `depth: 0` would allow-list the proxy instead of its clients; set that
  service's `ipWhiteList.ipStrategy.depth` above 0 to read the real client IP from `X-Forwarded-For` at the verified
  number of proxy hops in front of Traefik.
- **Neither trusted** (the default): needs no *values* change, but **does** need the environment's own network
  topology verified — this is not automatic. `depth: 0` reads the TCP connection's remote address, so this
  topology is only actually safe when that address is still the real client's by the time it reaches Traefik.
  `traefik.service.spec` ships `{}` (no `externalTrafficPolicy`), so the Traefik `Service` defaults to
  `externalTrafficPolicy: Cluster`: `kube-proxy` SNATs the connection to a node IP before Traefik ever sees it,
  and `depth: 0` then allow-lists *the node*, not the client — a `sourceRange` such as `10.0.0.0/8` (used in this
  chart's own test fixtures) silently admits every internet client whenever the node network falls inside that
  range. No render, test or runtime check here catches this: the chart cannot see the cluster's real network
  topology from values alone, and the render succeeds either way. Before relying on this topology, set
  `traefik.service.spec.externalTrafficPolicy: Local`, or confirm the LoadBalancer/ingress controller in front of
  Traefik already preserves the real client IP some other way (passthrough/IP mode, a provider whose LB forwards
  the original source address). Separately, make sure `sourceRange` in every allow-list does not overlap this
  cluster's node or pod CIDR — a range that does protects nothing under this topology even with
  `externalTrafficPolicy: Local` correctly set. Verify this with a request from an IP outside every configured
  `sourceRange` and confirm it gets a 403, as part of this environment's FedRAMP rollout check — not only once,
  since a cluster's node/pod CIDR can change.

The update-api-ban-list NetworkPolicy (`templates/api-ban/networkpolicy.yaml`) is on under `global.fedramp.networkPolicyEnabled`,
like the stage-1 policies (docs/014-network-policy.md). It blocks traffic, so check it when the profile is turned on, or when a
chart upgrade brings it to an environment that already has the profile on:

- It has an effect only where the cluster's CNI enforces NetworkPolicy.
- It denies all ingress, and allows egress only to CoreDNS (`kube-system`, `k8s-app: kube-dns`), the chart's Redis in the release namespace and TCP 443
  outside private, link-local and shared (100.64.0.0/10) space (the APIBAN feed). With `redisHa.enabled` the Redis rule selects the redis-ha pods on the
  Redis and Sentinel ports; otherwise the `redis` StatefulSet on `redis.port`.
- A Redis outside the chart, an egress proxy on a private address, a node-local DNS cache, or a Redis TLS port (6380/26380, if
  the chart adds them) needs an entry in `apiBan.networkPolicy.egressTo`.
- A blocked flow fails the hourly run, which the cognigy-monitoring-stack alert `VGApiBanListStale` reports. After the rollout, trigger one run
  (`kubectl create job --from=cronjob/update-api-ban-list apiban-check`) and confirm it completes.
- To remove it in one environment, set `global.fedramp.networkPolicyEnabled: false` there (a deviation, see below). That
  removes every policy under that switch, not only this one.

`redisTls` turns on the TLS listeners of redis-ha and switches sbc-sip-sidecar and drachtio, whose Redis traffic the
mesh cannot encrypt because the sbc-sip pod runs on the host network, to them (docs/011-redis-tls.md). The listeners
require a client certificate (`tls-auth-clients yes`); the chart signs one for the sbc-sip pod from its own CA and mounts
it there, so the sidecar image must present it (vg-redis 2.0.34, sidecar 2026.24.0-43 and later). The listeners exist
only on redis-ha and both clients reach them through Sentinel, so with the profile on the chart fails to render `redisTls: true` unless
`redisHa.enabled` is `true` and `cognigyEnv.FEATURE_REDIS_SENTINEL_MODE_ENABLED` is `"true"`. `false` is a deviation:
the sbc-sip pod's Redis traffic is then plaintext. Under the profile `redisHa.vgTls.*` is ignored (and the render-test hook
`redisHa.vgTls._lookup` is refused), so `global.fedramp.redisTls: false`
is the only way to turn it off, and an `sbcSipSidecar.extraEnvVars` entry with one of the client's TLS variables fails the
render. A drachtio image older than `redisHa.vgTls.drachtioMinVersion` fails the render too: it would ignore the TLS
options and dial the TLS port in plaintext. `ci/render-tests/redis-tls.test.sh` and `ci/render-tests/drachtio-redis-tls.test.sh`
assert the combinations.

`mysqlTls` puts a chart-minted certificate on MySQL and makes the sbc-sip pod, whose MySQL traffic the mesh cannot
encrypt, require TLS against it with CA and host-name verification: sbc-sip-sidecar through vg-db-helpers and the
`db-create-wait` init container through the mysql client (docs/012-mysql-tls.md). The chart can mint it only for the
MySQL it deploys, so with the profile on it fails to render `mysqlTls: true` unless `mysql.enabled` is `true`. TLS
shares 3306 and the server does not enforce it, so the meshed clients are unchanged; the client refuses plaintext.
Turning it on restarts MySQL once (`my.cnf` changes). `false` is a deviation: the sbc-sip pod's MySQL traffic is then
plaintext. Under the profile `mysql.vgTls.*` is ignored, and an `sbcSipSidecar.extraEnvVars` entry named
`JAMBONES_MYSQL_TLS_CA_FILE` fails the render. `ci/render-tests/mysql-tls.test.sh` asserts the combinations.

`callRouterTls` makes sbc-call-router serve HTTPS with a chart-minted certificate and points drachtio's INVITE
request-handler in sbc-sip, which the mesh cannot encrypt, at it with the chart's CA as its only trust anchor
(docs/016-call-router-tls.md). The port serves HTTPS only, so the key covers both ends, and switching it fails inbound
calls until sbc-call-router and sbc-sip have both restarted. Older images of either side would fail every inbound
INVITE rather than fall back to plaintext, so an older release tag of either fails the render
(`sbcCallRouter.tls.drachtioMinVersion`, `sbcCallRouter.tls.minVersion`). `false` is a deviation: every INVITE, SDP included, then crosses the node in
plaintext. Under the profile `sbcCallRouter.tls.enabled` is ignored, and an `sbcCallRouter.extraEnvVars` entry named
`HTTP_TLS_CERT_FILE` or `HTTP_TLS_KEY_FILE` fails the render. `ci/render-tests/call-router-tls.test.sh` asserts the
combinations.

`drachtioControlTls` puts mutual TLS on the connection drachtio in sbc-sip opens to sbc-inbound or sbc-outbound for
every new SIP request, which carries every SIP message and SDP of the call from the host network
(docs/017-drachtio-control-tls.md). The chart mints a CA dedicated to the hop, server certificates for sbc-inbound
and sbc-outbound and a client certificate for drachtio; the SBCs check the client certificate before they send the
drachtio secret. The one key switches sbc-sip, sbc-inbound, sbc-outbound and sbc-call-router together, because any
mix fails every call (closed, never plaintext). Turning it on in a running environment, including by upgrading one
that runs the profile from a chart before this default, therefore needs a maintenance window, the certificates staged
first with `drachtioControlTls.prepare: true`, and the new images in all four: vg-drachtio 1.3.28
or newer (the render fails on an older semver `drachtio.image`) and the sbc-inbound, sbc-outbound and sbc-call-router
releases with CGY-46071. Under the profile with the hop on, `drachtioControlTls.drachtioMinVersion` and
`drachtioControlTls.minImageVersions.sbcInbound`, `.sbcOutbound` and `.sbcCallRouter` must be set (an empty one
fails the render), an older image fails the render, and so does an image whose tag cannot be checked (a digest-only
reference, `latest`, no tag, a branch build, another suffix; for drachtio anything but `X.Y.Z` or `X.Y.Z-fips`, so
a pre-release such as `1.3.28-rc1` too; docs/017 lists the shapes). Pin release tags, with the
digest after the tag if needed (`:2026.25.0-12@sha256:…`). `drachtioControlTls.allowUncheckedImages: true` lets
such an image pass: that is a deviation, to record in the POA&M like a `global.fedramp.*` override, in the
environment's own values with the ticket in a comment. The chart's defaults meet the minimums (`drachtioMinVersion`
1.3.28, `minImageVersions` 2026.24.0-95), and so do the `2026.24.0-rc1` images the release cut writes: the release
line of a train counts as newer than its main builds (docs/017). `false` is a deviation: every SIP message and SDP
of a call then crosses the node in plaintext. While it is on, a `DRACHTIO_OUTBOUND_TLS_VERIFY` that
drachtio reads as off, in `drachtio.extraEnvVars` or `cognigyEnv`, fails the render, and under the profile so does an
`extraEnvVars` entry named after one of the hop's variables. `ci/render-tests/drachtio-control-tls.test.sh` asserts
the combinations.

The image must contain a vg-rtpengine-utils release that reads the variable. Older images ignore it.

Internal DTLS-SRTP replaces plain RTP between rtpengine and FreeSWITCH (REQ-FIPSTRANSPORT-010..020). Feature-server
and sbc-inbound read `INTERNAL_DTLS_ENABLED` and send DTLS offers; sbc-outbound has no setting and answers FreeSWITCH
in the form it offered; FreeSWITCH reads it too and answers without waiting for the handshake,
because its answer must reach rtpengine first. It is an environment variable, not an argument: an older
FreeSWITCH image exits on an unknown argument. A receiver accepts DTLS and plain RTP whatever
its own setting says, so restarting feature-server and the SBCs in any order keeps media. sbc-rtp is different: the cipher list changes its pod template, so turning the profile (or `rtpEngine.dtlsCiphers`) on or off rolls every rtpengine pod and drops the calls it carries. Drain sbc-rtp first (vg-sbc-rtpengine-sidecar traffic gate, `scripts/test-traffic-gate.sh`). Turning the profile on for a running environment needs images that
read the variable: an older feature-server, SBC or FreeSWITCH ignores it and offers plain RTP, which is what a receiver
with the setting on still accepts. rtpengine has one cipher list for every DTLS handshake, so `internalDtlsCiphers` also
applies to WebRTC browsers; the list is ECDHE with AES-GCM for ECDSA and RSA certificates, because rtpengine's certificate is ECDSA and FreeSWITCH's is RSA, and the DTLS server's certificate decides which suites are usable.
Under the profile an `extraEnvVars` entry named `INTERNAL_DTLS_ENABLED` fails the render, the deviation included: it renders
after the chart's value and Kubernetes keeps the last of two equal names, so it would turn DTLS off without an error.
`ci/render-tests/fedramp-internal-dtls.test.sh` asserts both modes, the deviations, the `extraEnvVars` guard and both rtpengine workload shapes.

vg-api-server reads `REQUIRE_EXPLICIT_ENCRYPTION_KEYS` only from an image with Cognigy/vg-api-server#419 or later. An older image ignores it and, without a mounted key, signs with the built-in one. Before turning the profile on, seal a fresh key for the environment and set `billing.sendToCentral.privateKeySecret.existingSecret`, otherwise the billing job fails.

## Signed service-to-service auth (ADR-001)

vg-resources `docs/work/CGY-46075-signed-service-to-service-auth/concept.md` defines the mechanism. The chart side lives in
`templates/_service-auth.tpl`, the mode and identity helpers at the end of `templates/_fedramp.tpl`, and
`ci/render-tests/service-auth-*.test.sh` plus `ci/render-tests/fedramp-identity-settings.test.sh`.

**Keys.** A `pre-install,pre-upgrade` hook Job (`templates/common-secrets/vg-service-keys-job.yaml`) creates one Secret
per key: `vg-service-key-internal`, `-sbc-inbound`, `-sbc-outbound`, `-feature-server`, `-sbc-sip-sidecar`, `-ops`. Each holds P-256 pairs
`key-<slot>.pem` (PKCS #8) and `key-<slot>.pub.pem` (SPKI) for the slots in `serviceAuth.keys.<name>.slots`. The Job
never overwrites: it creates a missing Secret and adds a missing slot, and its Role has no update or delete verb. It
does not depend on `vgCluster.signingKey.existingSecret`. `serviceAuth.keys.generatorImage` selects its image (empty:
`vgCluster.signingKey.generatorImage`). A FedRAMP environment sets an image whose openssl runs with the FIPS provider;
the Job logs `openssl list -providers` as evidence.

**Mounts.** A caller (api-server, feature-server, sbc-inbound, sbc-outbound, sbc-sip-sidecar while runtime regbots run) mounts only its own active private key at
`/etc/vg-service-auth/signing/`. A receiver mounts both public halves of every caller it trusts at
`/etc/vg-service-auth/trust/<name>/`. Mounts use `items` and never `subPath`, so kubelet updates the files in place.
Every volume is optional, so a missing key never blocks the pod from being scheduled and its container from being
created. Under FedRAMP `SERVICE_AUTH_REQUIRE_SIGNING_KEY=true` then keeps such a caller from becoming ready, and a
failed startup probe restarts it until the key is readable (see the table above). Nothing is sent unsigned.

**Rotation** (`serviceAuth.keys.<name>.active`, CGY-43688): add slot `b` (`slots: [a, b]`), wait until every receiver
reads it, set `active: b`, then remove the `key-a` files and set `slots: [b]`. The chart refuses an `active` slot that
is not in `slots`, and on an upgrade (where `lookup` sees the Secret) an `active` slot whose private key is not in the
Secret yet, so the slot cannot be added and used in the same upgrade. The vg-resources runbook `docs/operations/sops/rotate-vg-service-signing-key.md` has the commands, checks and
rollback.

**Receiver modes outside FedRAMP.** `serviceAuth.featureServerV1.mode` and `serviceAuth.resolver.mode` take `off`,
`report` or `enforce` and always win when set. When they are `null`, the chart picks the default from the readiness
marker, ConfigMap `vg-service-auth-state`, which every release renders with `callersSign: "true"`. Before rendering its
own, the chart reads the running release's marker and each trusted caller's key Secret with `lookup`. The default is
`enforce` only when the chart release turns on enforce-by-default (E1, 2026.24), the marker has `callersSign`, and
every caller's key Secret exists. Otherwise it is `report`. 2026.23 renders the marker but never defaults to
`enforce`. NOTES prints each receiver's mode and the reason.

An offline render (`helm template`, or a tool without cluster access) gets an empty `lookup` and therefore always
renders `report`. Such installs set the per-service keys to `enforce` themselves once their callers sign.

**sbc-inbound Dev Config** (CGY-43873). sbc-inbound reads Dev Config through api-server's signed
`GET /svc/v1/dev-config`, in-cluster (`VG_API_BASE_URL=http://api-server:<api.port>`), and gets no admin credentials.
One exception outside FedRAMP: on an upgrade (`.Release.IsUpgrade`) whose running release's marker lacks
`svcV1DevConfig` (its api-server has no `/svc/v1`, i.e. every release before the one that ships vg-api-server#377),
old api-server pods answer 404 on `/svc/v1` for a while. Only then does the chart render
`VG_API_ADMIN_USERNAME/PASSWORD` from `vg-api-admin-creds`, and sbc-inbound logs in only after such a 404. This chart
renders `svcV1DevConfig: "true"`, so the next upgrade drops them. `callersSign` is not the signal: releases render it
before their api-server serves `/svc/v1`. Fresh installs, normal upgrades and
offline renders get none; the FedRAMP profile never does.

The loader builds `${VG_API_BASE_URL}/svc/v1/dev-config` and, on that one fallback, `${VG_API_BASE_URL}/v1/login`, so
the base URL has no `/v1`. It falls back only on a 404, never on a 418 (the Ingress `/svc/` block) or a refused
connection, and every refresh tries the signed read first. Windows where sbc-inbound uses env values and defaults until
every api-server pod serves `/svc/v1`:
- a skip-release upgrade under the FedRAMP profile (no fallback by design);
- a skip-release upgrade rendered offline (`helm template | kubectl apply`, Argo CD): `.Release.IsUpgrade` is false,
  so no credentials are rendered;
- a retry after a failed upgrade without `--atomic`: the marker is a release object, so the failed attempt may already
  have written `svcV1DevConfig` and the retry drops the credentials while old pods still answer 404.
The release that ships this must carry api-server with Cognigy/vg-api-server#377 and sbc-inbound with
Cognigy/vg-sbc-inbound#155: the marker states what the chart expects, not what the image does.

**Ops minter** (`opsMinter.enabled`, default `false`, CGY-43874). People read call data (vg-support-tool) without an
admin password: a person mints a `vg-ops` token, valid up to 15 minutes and naming the person in `sub`, and uses it on
the read-only ops routes of api-server `/svc/v1`:

    kubectl exec vg-ops-minter-0 -- node build/lib/ops-mint.js --sub <user> --ttl 15m

The StatefulSet `vg-ops-minter` (templates `templates/ops-minter/`) runs api-server's image and mounts only the
`ops` key's active private half. Its ServiceAccount has no token. The Role `vg-ops-minter-exec` grants `pods/exec` and
`get` on the pod `vg-ops-minter-0` only, and the RoleBinding gives it only to the group `opsMinter.execGroup` (required
when enabled; per cloud: the Entra ID group object ID on AKS, the access-entry group on EKS, the Google group on GKE).
A StatefulSet is used because its pod name is fixed, so RBAC can name that one pod. Cluster admins can still exec, as
for every pod; the cloud IdP's MFA gates both. The render fails when `vgTrafficSniffer.enabled` is also true: the
sniffer's Role may exec into, and attach ephemeral containers to, every pod in the namespace. Under the profile a
deny-all NetworkPolicy isolates the pod, which needs no network (it follows `global.fedramp.networkPolicyEnabled`, like
every workload's policy).

What the RBAC does not control. The Role limits which pod, not which command, so a member of `execGroup` can read the
mounted key (`kubectl exec vg-ops-minter-0 -- cat /etc/vg-service-auth/signing/key-a.pem`). With the key, they can mint
tokens offline, for any `sub`, until the key is rotated. Even through `ops-mint`, `--sub` is what the person types. So:
- The authoritative record of who minted is the Kubernetes audit log of the exec (user, pod, time, command), not the
  token's `sub`. Enable control-plane audit logging at `Request` level for `pods/exec` (it is off by default on EKS).
- Alert on any `exec`, `attach` or `ephemeralcontainers` request (`objectRef.subresource`) on `vg-ops-minter-0`
  whose first two command arguments are not `node` and `build/lib/ops-mint.js` (matching `node` alone lets
  `node -e …` through). The team that owns the cluster's audit pipeline owns this alert.
- Alert when `vg-ops-minter-0` is NotReady or restarting: a missing key or an api-server image without `ops-mint`
  shows up there, not when someone tries to mint during an incident.
- api-server refuses a vg-ops token older than 15 minutes (`maxTokenAgeSeconds`, ADR-001 §2.3), so a token, once
  issued, expires; a copied key does not.
- Rotate the `ops` key (`serviceAuth.keys.ops`, slots `a`/`b`) whenever someone leaves `execGroup`, then retire the
  old slot: drop it from `slots` and delete `key-<old>.pem` and `key-<old>.pub.pem` from the `vg-service-key-ops`
  Secret. Rotation alone does not revoke a copied key: receivers trust every listed slot, and the keys Job never
  removes one (`templates/common-secrets/vg-service-keys-job.yaml`), so the old key would become active again on
  the next rotation back to it.
A broker that binds `sub` to the caller's authenticated identity and never exposes the key would close this; that is a
separate design (CGY-43874 follow-up), not this chart change.

**Why the identity settings fail the render.** The rest of the profile lets an operator relax one control during an
incident. Password login, admin-scope API keys, privileged-user bootstrap and the migrator's FedRAMP mode do not:
each brings back a password or admin-key path, which the interim emergency procedure forbids, and the bootstrap
creates users and Secrets that outlive a reverted deviation. A rollout mode may be relaxed to `report`, never to
`off`. For the same reason, under the profile a workload's `extraEnvVars` cannot name one of the identity variables
or `SERVICE_AUTH_MODE`, `SERVICE_AUTH_TRUSTED_KEYS`, `SERVICE_AUTH_SIGNING_KEY_PATH` or
`SERVICE_AUTH_REQUIRE_SIGNING_KEY` on a workload that renders it: the entry would render after the chart's value and
win, so the render fails instead.

The identity variables are read by vg-api-server and the api-migrator from the X1 and X5 releases (wave 3). Older
images ignore them, so until then the chart renders the variables only.

## Deviating during an incident

To relax one control in a FedRAMP environment, override its `global.fedramp.<feature>` key in that environment's
Flux values (for example `voicegateway-values.yaml` in flux-fleet-prod). Leave `enabled: true` in place:

```yaml
global:
  fedramp:
    enabled: true
    # DEVIATION <ticket>: enforce dropped valid DTMF digits, see <incident>. Revert after the fix.
    dtmfSourceValidation: warn
```

- Put the override in the **environment's own** values, never in a shared values file, so that it reaches
  only the affected environment.
- Reference the incident or ticket in a comment, and record the deviation where the environment's FedRAMP
  deviations are tracked.
- Changing a per-service key such as `sbcInbound.dtmfSourceValidation` has **no effect** while the profile is on.
- To revert, remove the override. The chart's FedRAMP value applies again.

One deviation sits outside `global.fedramp.*`: `drachtioControlTls.allowUncheckedImages: true`, which lets SBC,
call-router or drachtio images whose tag the chart cannot check (digest only, `latest`, a branch build) pass while
the drachtio control hop is on. Record it in the POA&M the same way, with the environment and the images it covers.

## Adding a feature

1. Add `global.fedramp.<feature>` with its FedRAMP value to `values.yaml`, and to `values.schema.json`.
2. Add a helper to `templates/_fedramp.tpl`. With the profile on, it returns `global.fedramp.<feature>`, falling
   back to the FedRAMP value when the key is missing. With the profile off, it returns the per-service key.
3. Render it in the service template with `{{- with include ... }}`, before `extraEnvVars`. A flow the profile
   only turns off, with no per-service key, returns `true` while the profile is off and is gated with
   `{{- if include ... }}` instead (see `vg.fedramp.sbcSipSidecarAlerts`).
4. If the feature needs a per-service key for non-FedRAMP environments, add it to `values.yaml` (default `null`)
   and to `values.schema.json`.
5. Add a row to the table above, with the control ID and the PR that introduced the feature.
6. Check the rendered output with `global.fedramp.enabled` set to `true` and `false`, and with an overridden
   `global.fedramp.<feature>`.
7. If the feature needs anything from the environment (a value without a safe default, a minimum image, a cluster
   setting or a network path), add it to [Enabling it in an environment](#enabling-it-in-an-environment). Add cluster
   settings and network paths to vg-resources `docs/concepts/041-fedramp-environment-setup.md` too. While the PR is
   open, keep its row in [Pending changes](#pending-changes-open-prs) up to date, and remove the row when it merges.

## Enabling it in an environment

1. Make sure the environment runs images that support the profile. `sbcSipSidecar.image` must contain
   Cognigy/vg-sbc-sip-sidecar CGY-42786 (#70) or later; an older sidecar refuses to start without
   `JAMBONES_TIME_SERIES_HOST` and the sbc-sip pods crash-loop. `api.image` must contain Cognigy/vg-api-server#299
   or later; an older api-server ignores `SESSION_KEY_DIGEST` and keeps using md5. Older vg-api-ban and
   vg-rtpengine-utils images also ignore their variables (see above). `api.image` must also contain
   Cognigy/vg-api-server#419 or later for the billing key check, and `billing.sendToCentral.privateKeySecret` must
   mount a freshly sealed key; without it the daily billing job fails on every run. None of these failures shows up at
   render time.
2. Check that the environment's values set no `extraEnvVars` entry named after a variable in the table's *Env var*
   column. The profile renders its variables before `extraEnvVars`, and Kubernetes keeps the last of two equal names,
   so such an entry overrides the profile without a `global.fedramp.*` deviation. This covers, among others,
   `RTPENGINE_DTMF_SOURCE_VALIDATION` on `sbcInbound` and `sbcOutbound`, `SESSION_KEY_DIGEST` on `api`, `API_BAN_*`
   on `apiBan`, and `JAMBONES_TIME_SERIES_HOST`, `REGBOT_RUNTIME_TARGETS_ENABLED` and `RESOURCE_RESOLVER_URL` on
   `sbcSipSidecar`. Refused at render time are only `AUDIT_LOG_TTL_DAYS` on `api`, `VG_TLS_KEYLOG_FEDRAMP_LOCKED`
   on feature-server, feature-server-nightly and `api`, and on `sbcSipSidecar` the Redis TLS variables (docs/011-redis-tls.md)
   and `JAMBONES_MYSQL_TLS_CA_FILE`, `JAMBONES_MYSQL_HOST` and `JAMBONES_MYSQL_WRITE_HOST` (docs/012-mysql-tls.md).
   With `global.fedramp.drachtioControlTls` on, the drachtio control TLS variables on `drachtio`, `sbcInbound`,
   `sbcOutbound` and `sbcCallRouter` are refused too, and so are an empty `drachtioControlTls.drachtioMinVersion` or
   `drachtioControlTls.minImageVersions` entry, an image older than its minimum, and an image whose tag cannot be
   checked unless `drachtioControlTls.allowUncheckedImages` records a deviation (docs/017-drachtio-control-tls.md).
   Also check for a `cognigyEnv.JAMBONES_TIME_SERIES_HOST` key (see above). The chart adds `fsGroup: 1000` to
   `sbc.sip.podSecurityContext` unless it sets one: the Redis client certificate is mounted 0440 and owned by root, and
   drachtio (uid 1000) reads it through that group (docs/011-redis-tls.md).
3. Set `global.fedramp.enabled: true` in that environment's Flux values, together with the redis-ha settings
   Redis authentication needs (docs/013-redis-auth.md):

   ```yaml
   global:
     fedramp:
       enabled: true
   redisHa:
     enabled: true
     auth:
       enabled: true
       existingSecret: redis-ha-auth
   ```

   Before a chart upgrade brings new NetworkPolicies to an environment that already has the profile on, check what
   they would cut off: a Redis outside the chart or in another namespace, a node-local DNS cache, an egress proxy.
   Add the `egressTo` entries in the same change, or set `global.fedramp.networkPolicyEnabled: false` until they are
   in place. That deviation removes every policy under the shared switch (every workload in
   docs/014-network-policy.md, and update-api-ban-list), not only the one that needs the entry.
4. Provide what the values alone cannot. The chart cannot check these at render time, and each one fails silently:
   - The cluster's CNI must enforce `NetworkPolicy`. Otherwise the policies are accepted and block nothing.
   - sbc-sip and sbc-rtp run on the host network, so a `podSelector` rule does not match them. List the SIP and RTP
     node CIDRs in `networkPolicy.ingressFromHostNetwork` of `sbcInbound`, `sbcOutbound`, `telegraf`, `influxdb`,
     `heplifyServer` and (with runtime regbots) `resourceResolver`, and in `networkPolicy.egressToHostNetwork` of
     `sbcInbound`, `sbcOutbound` and `vgConnector`. All of them are empty by default, so traffic between these workloads
     and sbc-sip or sbc-rtp is dropped until they are set.
   - A cluster with NodeLocal DNSCache needs an `ipBlock` for its listener (typically `169.254.20.10`, TCP and UDP
     53) in `networkPolicy.egressTo` of every egress-isolated workload, not only one of them.
   - Each exposed service's `ingress.<service>.ipWhiteListMiddleware.ipWhiteList.sourceRange` must include the
     egress addresses of every linked Cognigy.AI cluster, or the AI side can no longer reach VG (JWKS, `/v2`,
     `/v1`, test calls).

   vg-resources `docs/concepts/041-fedramp-environment-setup.md` lists the cluster prerequisites and the VG ↔ AI
   network paths in full.

### Pending changes (open PRs)

What the open FedRAMP PRs will add to the checklist above, as of 2026-11-03. Each PR documents its own feature in
the table further up when it merges; remove its row here at the same time. "Stacked on" means the PR targets
another PR's branch and merges after it.

| PR | Adds to the profile | What the environment must provide |
|---|---|---|
| #1044 (CGY-42571, draft) | TLS from host-network clients to MySQL (`global.fedramp.mysqlTls`). #1243 re-lands its Redis part | `mysql.enabled: true` (an external MySQL fails the render); an sbc-sip-sidecar image with Cognigy/vg-db-helpers#47; a STRICT-mTLS exception for host-network traffic to MySQL 3306 |
| #1103 (CGY-43474) | Per-workload ServiceAccounts (`global.fedramp.perWorkloadServiceAccounts`) | nothing; every workload rolls once |
| #1104 (CGY-43475) | audit-logs-cleanup in `db` mode (`global.fedramp.auditCleanupMode`) | nothing; `api` mode fails the render under the profile, so there is no deviation |
| #1109 (CGY-43682) | Service-auth receiver modes, identity settings (no password login, admin API keys or privileged bootstrap), the `vg-service-key-*` Secrets | `serviceAuth.keys.generatorImage` with a FIPS openssl (it falls back to `vgCluster.signingKey.generatorImage`); vg-api-server and api-migrator images that read the identity settings (not released yet; older ones ignore them); the six Secrets themselves with `serviceAuth.keys.autoGenerate: false` |
| #1113 (CGY-43478, draft, stacked on #1109) | vg-test-harness provisions with a signing key instead of an admin login. Test clusters only | nothing in production. On a test cluster: api-server with Cognigy/vg-api-server#380, vg-test-harness with Cognigy/vg-test-harness#160 |
| #1124 (CGY-43875, draft, stacked on #1109) | Service-auth `enforce` by default outside the profile from 2026.24 | rollback order: receivers before callers. Before a Helm rollback to a chart older than 2026.23, upgrade once with `serviceAuth.featureServerV1.mode` and `serviceAuth.resolver.mode` set to `report` |
| #1125 (CGY-43873) | sbc-inbound reads Dev Config through api-server's signed `/svc/v1/dev-config`, without admin credentials | api-server with Cognigy/vg-api-server#377, then sbc-inbound with Cognigy/vg-sbc-inbound#155 (with older images Dev Config silently falls back to env vars). sbc-inbound now calls `http://api-server:<api.port>` in-cluster, which `main`'s sbc-inbound and api-server NetworkPolicies block; the PR has to admit it when it rebases |
| #1128 (CGY-43874) | Ops minter (`opsMinter.enabled`, off by default; refused with `vgTrafficSniffer.enabled`) | `opsMinter.execGroup`: the IdP group allowed to exec into the minter (the render fails without it); `api.image` with Cognigy/vg-api-server#385 (without it the pod fails); the `vg-service-key-ops` Secret from #1109 |
| #1129 (CGY-43876) | sbc-call-router basic auth from drachtio | `global.fedramp.serviceAuthCallRouterMode: report` for the first upgrade, `enforce` once sbc-sip has rolled; sbc-call-router with Cognigy/vg-sbc-call-router#60; `drachtio.image` with Cognigy/vg-drachtio#54 (without it the credential is logged); create Secret `vg-call-router-credentials` (key `credentials`, `user:password` in letters, digits and `._~-`) yourself with `serviceAuth.callRouter.autoGenerate: false`. A hand-made Secret in any other format fails the upgrade's pre-upgrade hook. The router port's NetworkPolicy uses `networkPolicy.hostNetworkPeers` from #1235 |
| #1133 (CGY-41197) | Internal DTLS-SRTP, rtpengine DTLS ciphers | feature-server with Cognigy/vg-feature-server#804, sbc-inbound with Cognigy/vg-sbc-inbound#157, freeswitch with Cognigy/vg-freeswitch#346 (older images ignore it and keep plain RTP, which is still accepted, so media stays unencrypted without an error); drain sbc-rtp before turning it on, because every rtpengine pod restarts |
| #1166 (CSA-109432) | SIPREC signalling TLS on the SBCs | every recording URL (`siprecServerURL`) a `sips:` URI or `sip:…;transport=tls`, otherwise the call continues unrecorded; each recording server reachable over SIP TLS; SBC images with Cognigy/vg-siprec-client-utils#20 (1.0.14; the SBC images on `main` have it) |
| #1235 (CSA-110265, CSA-110267) | Host-network and ingress-controller peers for the default-deny NetworkPolicies, and render failures when they are missing | `networkPolicy.hostNetworkPeers`: the SIP and RTP node CIDRs, shared by every workload (the render fails while it and the workload's own list are both empty). With `traefik.enabled: false`, `networkPolicy.ingressControllerPeers`. On Cilium, `policy-cidr-match-mode=nodes`; with Calico IPIP/VXLAN, also the tunnel range |
| #1243 (CGY-45819) | TLS from sbc-sip-sidecar to redis-ha (`global.fedramp.redisTls`) | `redisHa.enabled` with Sentinel (`cognigyEnv.FEATURE_REDIS_SENTINEL_MODE_ENABLED: "true"`; the render fails otherwise); sbc-sip-sidecar with vg-redis 2.0.32 or later (the image on `main` has it). redis-ha fails over once on the upgrade |
| #1248 (CGY-45820) | Client certificates on the redis-ha TLS ports | sbc-sip-sidecar 2026.24.0-43 or later (vg-redis 2.0.34, Cognigy/vg-redis#52; an older one is refused). Chart preview 2026.24.0-42 defaults to an older sidecar, so pin the image there. With a non-root `sbc.sip.podSecurityContext.runAsUser`, also `fsGroup`. TLS clients fail for a few minutes during the upgrade from #1243 |
| #1279 (CSA-102450) | Registration-hook Basic-Auth only over HTTPS | every registration hook that uses Basic-Auth on HTTPS (otherwise REGISTER and INVITE get SIP 500); sbc-inbound and sbc-sip-sidecar images with Cognigy/vg-digest-utils#45 (not released yet; older images ignore the setting) |
| #1333 (CGY-43686, CSA-109611, stacked on #1109) | Service key `vg-service-key-sbc-sip-sidecar`: the runtime regbots sign their resolver poll with it, and the resolver trusts `vg-sbc-sip-sidecar` | nothing while runtime regbots stay off (the profile's default). With `global.fedramp.sbcSipRuntimeRegbots: true`: sbc-sip-sidecar with Cognigy/vg-sbc-sip-sidecar#90 (an older one polls unsigned, which the resolver in `enforce` refuses) and vg-resource-resolver with Cognigy/vg-resource-resolver#97 (the route list that admits the poll) |
| #1441 (CGY-46069) | feature-server `/v1` trusts feature-server's own key, so the signed cross-pod `/v2` command forward is accepted | feature-server with Cognigy/vg-feature-server#890, which signs the forward. Until both are deployed, keep `global.fedramp.serviceAuthFeatureServerV1Mode: report` where `/v2` commands are used: an unsigned forward is refused in `enforce` and the caller gets `503 feature_server_unavailable`. Drop the deviation once `/v1/calls/*/commands` audit lines read `accept … vg-feature-server` |

Not listed, because they require nothing of an environment: #1105, #1108 and #1132 (kind and CI tests), #983 (PoC).
PR #822 is superseded by #1196, which brought its api-ban NetworkPolicy to `main` under
`global.fedramp.networkPolicyEnabled`.
