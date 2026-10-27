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
| Legacy feature-server refused | none (not relaxable) | `featureServerLegacy.enabled` must be `false` | `featureServerLegacy.enabled` | `false` | none: the render fails | CM-7, SC-13 | CGY-42548 |
| vg-api-server session-key digest | `global.fedramp.apiSessionKeyDigest` | `sha256` | `api.sessionKeyDigest` | not set (service default `md5`) | `SESSION_KEY_DIGEST` | SC-13 (APIS-SC13-001) | vg-api-server#299 (CSA-101833) |
| Redis authentication (redis-ha) | `global.fedramp.redisAuth` | `true` (needs `redisHa.enabled`, `redisHa.auth.enabled` and `redisHa.auth.existingSecret: redis-ha-auth`; the render fails otherwise) | `redisHa.vgAuth.enabled` | `false` | `REDIS_PASSWORD`, `JAMBONES_REDIS_PASSWORD`, `REDIS_USERNAME` (api-ban), drachtio `--blacklist-redis-password`; see docs/013-redis-auth.md | SC-28, AC-3 (APBN-SC28-001) | CSA-100703 |
| vg-api-server audit-log retention | `global.fedramp.apiAuditLogTtlDays` | `90` (the schema accepts 90 to 99999; an `api.extraEnvVars` entry named `AUDIT_LOG_TTL_DAYS` fails the render) | `auditLogging.cleanup.ttlDays` | `90` | `AUDIT_LOG_TTL_DAYS` | AU-11 (APIS-AU11-001) | vg-api-server#255 (CSA-101837) |

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

The legacy feature-server (`vg-feature-server-legacy`) cannot run in a FedRAMP environment. It does not get the
signed-token verification of the `/v1` routes (CSA-102459), and its crypto and dependencies are outside the FIPS work.
With the profile on, the chart therefore fails to render when `featureServerLegacy.enabled` is `true`. Unlike the other
features, this one has no `global.fedramp.*` key to relax it: disable the legacy feature-server (and move its
applications to the feature-server), or do not use the profile. `ci/render-tests/fedramp-legacy-feature-server.test.sh`
asserts all three combinations.

vg-api-server audit-log retention (`AUDIT_LOG_TTL_DAYS`) cannot be shortened below the AU-11 minimum of 90 days while
the profile is on. The schema accepts a `global.fedramp.apiAuditLogTtlDays` of 90 to 99999, and, unlike the other features,
an `api.extraEnvVars` entry named `AUDIT_LOG_TTL_DAYS` fails the render rather than overriding the profile. To keep
records longer, raise `global.fedramp.apiAuditLogTtlDays`. Before CSA-101837 the chart rendered this setting as
`AUDIT_LOGGING_TTL_DAYS=30`, which vg-api-server never read. `ci/render-tests/fedramp-api-audit-log-ttl.test.sh` asserts
both modes.

The image must contain a vg-rtpengine-utils release that reads the variable. Older images ignore it.

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
3. Render it in the service template with `{{- with include ... }}`, before `extraEnvVars`.
4. If the feature needs a per-service key for non-FedRAMP environments, add it to `values.yaml` (default `null`)
   and to `values.schema.json`.
5. Add a row to the table above, with the control ID and the PR that introduced the feature.
6. Check the rendered output with `global.fedramp.enabled` set to `true` and `false`, and with an overridden
   `global.fedramp.<feature>`.

## Enabling it in an environment

Set `global.fedramp.enabled: true` in that environment's Flux values, together with the redis-ha settings
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
