# FedRAMP profile

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
| StatsD (vg-stats-collector) | `global.fedramp.statsEnabled` | `false` (off) | `stats.enabled` | `true` (on) | `ENABLE_METRICS`, `STATS_*`, telegraf statsd input and Service | SC-8, SC-8(1), SC-13 (STAT-SC8-001) | CGY-40434 |
| vg-api-ban strict ranges | `global.fedramp.apiBanStrictRanges` | `true` | `apiBan.strictRanges` | `false` (a malformed entry is logged and skipped) | `API_BAN_STRICT_RANGES` | SI-10 (APBN-SI10-002) | vg-api-ban#24 (CSA-100695) |
| vg-api-ban redirects | `global.fedramp.apiBanMaxRedirects` | `0` | `apiBan.maxRedirects` | `0` | `API_BAN_MAX_REDIRECTS` | SC-8 (APBN-SC8-001) | vg-api-ban#24 |
| vg-api-ban timeout | `global.fedramp.apiBanTimeoutMs` | `30000` | `apiBan.timeoutMs` | `30000` | `API_BAN_TIMEOUT_MS` | SI-10 | vg-api-ban#24 |
| vg-api-ban feed batches | `global.fedramp.apiBanMaxBatches` | `1000` | `apiBan.maxBatches` | `1000` | `API_BAN_MAX_BATCHES` | SI-10 | vg-api-ban#24 |
| sbc-sip-sidecar alerts (vg-time-series -> InfluxDB) | `global.fedramp.sbcSipSidecarAlerts` | `false` (off) | none | on (`JAMBONES_TIME_SERIES_HOST` rendered) | `JAMBONES_TIME_SERIES_HOST` on the `sbc-sip-sidecar` container | SC-8 | CGY-42786 |
| sbc-sip-sidecar runtime regbots (AI-side carriers, via vg-resource-resolver) | `global.fedramp.sbcSipRuntimeRegbots` | `false` (off) | `sbcSipSidecar.runtimeRegbots.enabled` | `true` | `REGBOT_RUNTIME_TARGETS_ENABLED`, `RESOURCE_RESOLVER_URL` on the `sbc-sip-sidecar` container | SC-8, SC-7 | CGY-42786 |
| vg-api-server session-key digest | `global.fedramp.apiSessionKeyDigest` | `sha256` | `api.sessionKeyDigest` | not set (service default `md5`) | `SESSION_KEY_DIGEST` | SC-13 (APIS-SC13-001) | vg-api-server#299 (CSA-101833) |
| vg-api-server strict registration-hook validation | `global.fedramp.apiStrictRegistrationHookValidation` | `true` | `api.strictRegistrationHookValidationEnabled` | not set (service default) | `FEATURE_STRICT_REGISTRATION_HOOK_VALIDATION_ENABLED` | AC-4 (SSIP-AC4-001) | vg-api-server#289 (CSA-102746) |
| Redis authentication (redis-ha) | `global.fedramp.redisAuth` | `true` (needs `redisHa.enabled`, `redisHa.auth.enabled` and `redisHa.auth.existingSecret: redis-ha-auth`; the render fails otherwise) | `redisHa.vgAuth.enabled` | `false` | `REDIS_PASSWORD`, `JAMBONES_REDIS_PASSWORD`, `REDIS_USERNAME` (api-ban), drachtio `--blacklist-redis-password`; see docs/013-redis-auth.md | SC-28, AC-3 (APBN-SC28-001) | CSA-100703 |
| vg-api-server audit-log retention | `global.fedramp.apiAuditLogTtlDays` | `90` (the schema accepts 90 to 99999; an `api.extraEnvVars` entry named `AUDIT_LOG_TTL_DAYS` fails the render) | `auditLogging.cleanup.ttlDays` | `90` | `AUDIT_LOG_TTL_DAYS` | AU-11 (APIS-AU11-001) | vg-api-server#255 (CSA-101837) |
| Default-deny NetworkPolicy (stage 1: silero-vad, feature-server v2-api, vg-resource-resolver; plus update-api-ban-list) | `global.fedramp.networkPolicyEnabled` | `true` | each workload's own `networkPolicy.enabled` | `false` (opt-in), except silero-vad's own default of `true` | n/a (Kubernetes `NetworkPolicy` objects, not env vars) | SC-7, AC-4 | CSA-110265, CSA-110267 — see docs/014-network-policy.md; update-api-ban-list: APBN-SC7-001, CSA-100704 |
| Ingress IP allow-list (9 externally-exposed ingresses: api, homer, jaeger, testCallManager, webapp, vgConnector, vgConsole, vgPagerdutyAgent, realtimeBridge; api, webapp, vgConnector and realtimeBridge are on by default, so each needs a real `sourceRange`, or turn the bridge route off with `ingress.realtimeBridge.enabled: false`) | `global.fedramp.ingressIpAllowListEnabled` | `true` (the render fails if `ingress.ingressClassName` is not `traefik` for a standard-Ingress service, `ipWhiteList.sourceRange` contains an IPv4-mapped IPv6 address or a prefix shorter than `/8` (IPv4) or `/32` (IPv6), or `extraAnnotations` sets `router.middlewares`) | `ingress.<service>.ipWhiteListMiddleware.enabled` | `false` | Traefik `Middleware` `ipwhitelist<service>` + the ingress's `router.middlewares` annotation | SC-7 (VHC-SC7-002) | CSA-110266 |
| Traefik entrypoint trust boundary | none (not relaxable; environment-specific) | `traefik.ports.{web,websecure}.{proxyProtocol,forwardedHeaders}.insecure` must be `false` in this environment's own values/Flux overlay — only checked while `traefik.enabled` is `true` (this chart's own Traefik subchart); see the next row for `traefik.enabled: false` | `traefik.ports.*` (same keys; this chart does not change the default for any environment) | `true` (trusts a PROXY-protocol preamble or `X-Forwarded-For` from any caller) | none: the render fails | SC-7 (VHC-SC7-002) | CSA-110266 |
| Traefik entrypoint trust boundary, external Traefik (`traefik.enabled: false`) | `global.fedramp.externalTraefikEntrypointsVerified` | `true`, set only after verifying by hand that the external/shared Traefik does not trust an unauthenticated PROXY-protocol preamble or `X-Forwarded-For` on its web/websecure entry points — `traefik.ports.*` configures only this chart's own (disabled) Traefik subchart, so the chart cannot check the real one itself | none; this key only exists under the profile | not set (the render fails) | none: the render fails | SC-7 (VHC-SC7-002) | CSA-110266 |
| TLS keylog capture (feature-server, feature-server-nightly, api-server) | `global.fedramp.tlsKeylogLocked` | `true` (locked; an `extraEnvVars` entry named `VG_TLS_KEYLOG_FEDRAMP_LOCKED` fails the render) | none | not set (capture follows its callers: dev-config with approval, or the signal toggle) | `VG_TLS_KEYLOG_FEDRAMP_LOCKED` | SC-8(1), SC-13, SC-28(1) (VDCL-SC13-001) | vg-speech-utils (CSA-110113) |
| Built-in billing signing key refused (daily-billing-reporting CronJob) | `global.fedramp.requireExplicitEncryptionKeys` | `true` (the job fails unless `billing.sendToCentral.privateKeySecret` mounts a key that isn't the built-in one) | `billing.sendToCentral.requireExplicitEncryptionKeys` | not set (the built-in key is the fallback) | `REQUIRE_EXPLICIT_ENCRYPTION_KEYS` on the `daily-billing-reporting` container | IA-5(7) (KR-68) | CSA-103928 |

`enforce` assumes the sidecar's DTMF datagrams arrive from the address `sbc.rtp` resolves to. That holds with
`sbc.rtp.useStatefulSet: true`. With `useStatefulSet: false`, the replies come from a node IP and `enforce`
would drop every digit. The chart therefore fails to render `enforce` when `sbc.rtp.useStatefulSet` is `false`.
With the profile on, that topology needs `global.fedramp.dtmfSourceValidation` set to `warn` or `off`, which is a
deviation from FedRAMP.

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
only by node CIDR (`resourceResolver.networkPolicy.ingressFromHostNetwork`, empty by default), so the poll would time out. Until the flow is redesigned, the profile
turns the runtime regbots off: the sidecar gets no `REGBOT_RUNTIME_TARGETS_ENABLED` or `RESOURCE_RESOLVER_URL`, and
register events are not reported to vg-resources-api. **AI-side carriers that require REGISTER are then not registered.**
A FedRAMP deployment is VG-in-AI only and has no carriers in MySQL, so the MySQL regbots find nothing either: no carrier
is registered. TODO (CGY-45358): FedRAMP will most likely need the feature, which needs an encrypted poll that the resolver
NetworkPolicy admits; the impact is tracked in vg-resources `docs/concepts/039-fedramp-feature-impact.md`. To turn it
on in one environment, set `global.fedramp.sbcSipRuntimeRegbots: true` there, and list the
SIP nodes' CIDR in `resourceResolver.networkPolicy.ingressFromHostNetwork` (or set
`global.fedramp.networkPolicyEnabled: false`, a second deviation that also drops the
default-deny NetworkPolicy from `silero-vad` and `feature-server` v2-api — see
docs/014-network-policy.md). `sbcSipSidecar.runtimeRegbots.enabled` has no effect while the profile is on.
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

The image must contain a vg-rtpengine-utils release that reads the variable. Older images ignore it.

vg-api-server reads `REQUIRE_EXPLICIT_ENCRYPTION_KEYS` only from an image with Cognigy/vg-api-server#419 or later. An older image ignores it and, without a mounted key, signs with the built-in one. Before turning the profile on, seal a fresh key for the environment and set `billing.sendToCentral.privateKeySecret.existingSecret`, otherwise the billing job fails.

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
   `sbcSipSidecar`. Only `AUDIT_LOG_TTL_DAYS` on `api` is refused at
   render time. Also check for a `cognigyEnv.JAMBONES_TIME_SERIES_HOST` key (see above).
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
   in place. That deviation removes every policy under the shared switch (silero-vad, feature-server v2-api,
   vg-resource-resolver and update-api-ban-list), not only the one that needs the entry.
