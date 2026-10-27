# Authentication on redis-ha

redis-ha asks every client for a password, and the update-api-ban-list CronJob logs in as its own ACL user,
limited to its own keys. This closes FedRAMP finding APBN-SC28-001 (CSA-100703, SC-28 / AC-3).

## Why

Without it, anything that can reach redis-ha can rewrite or delete the IP blocklist (`apiban:ips`) that
drachtio enforces on inbound SIP. There is no login, and `protected-mode` is off.

The data at rest needs no change: redis-ha keeps nothing on disk (`persistence.enabled: false`,
`appendonly no`, `save ""`).

## Switch

| | Value used |
|---|---|
| FedRAMP profile on | `global.fedramp.redisAuth` (`true`) |
| FedRAMP profile off | `redisHa.vgAuth.enabled` (`false`) |

With the switch off, the chart renders exactly as before.

The Bitnami subchart (17.4.1) reads `redisHa.auth.*` as plain values, not through `tpl`, so they cannot
follow the switch. With the switch on, the environment sets them, and the render fails until it does:

```yaml
redisHa:
  enabled: true
  auth:
    enabled: true
    sentinel: false
    existingSecret: redis-ha-auth            # must be set; values.yaml leaves it empty
    existingSecretPasswordKey: redis-password # the default in values.yaml
```

`global.fedramp.redisAuth: false` is the documented deviation (docs/009-fedramp-profile.md).

## Refused renders

`vg.redisAuth.validate` (`templates/_redis-auth.tpl`) fails the render, rather than let clients and
server disagree about the password, when:

| Case | Why |
|---|---|
| Profile on, `global.fedramp.redisAuth` on, `redisHa.enabled: false` | The standalone `redis` Deployment has no authentication |
| Profile off, `redisHa.vgAuth.enabled: true`, `redisHa.enabled: false` | The switch would render nothing. Under the profile `vgAuth` is ignored, so a leftover `true` is not refused there |
| Switch on, `redisHa.auth` not set as above | Clients would send a password redis-ha never checks |
| Switch on, `redisHa.auth.sentinel: true` | drachtio and media-processor send no Sentinel password |
| Switch on, `redisHa.sentinel.enabled: false` | The ACL file is mounted on the replicas only; the master would not start |
| Switch off, `redisHa.auth.enabled: true` and `existingSecret` still `redis-ha-auth` | The kept Secret survives switch-off, so redis-ha keeps asking for a password no client sends (`NOAUTH`) |
| Switch on, `apiBan.image` older than `redisHa.vgAuth.apiBanMinVersion` | See Rollout |

## What the chart renders

**Secret `redis-ha-auth`** (`templates/redis/redis-ha-auth-secret.yaml`):

- Created once, by a pre-install/pre-upgrade hook, then kept (`helm.sh/resource-policy: keep`).
- It is never rotated underneath a running cluster. The idiom is that of `vg-api-admin-creds`.
- Keys:
  - `redis-password`: the `default` user.
  - `apiban-password`: the `apiban` user.
  - `users.acl`: both users, written in the same render as the passwords.

**redis-ha**:

- `aclfile /opt/bitnami/redis/acl/users.acl`, mounted from the Secret into the redis container only.
- `protected-mode yes`.
- Bitnami passes the same `default` password as `--requirepass`, and to replication and Sentinel's
  `auth-pass`.
- Sentinel itself takes no password (`auth.sentinel: false`).

**ACL users**:

| User | Keys | Commands |
|---|---|---|
| `default` | all | all |
| `apiban` | `apiban:*` | `SADD EXPIRE RENAME PERSIST DEL MULTI EXEC`, plus what ioredis sends on connect: `HELLO CLIENT SETNAME/SETINFO SELECT PING INFO ROLE QUIT` |

The `apiban` list was checked on Redis 7.4: vg-api-ban's full command sequence, direct and through
Sentinel, left `ACL LOG` empty, and any other key or command returned `NOPERM`.

**Clients**, all from the Secret, never from values:

| Workload | Variables |
|---|---|
| api-server, feature-server (all three), media-processor, vg-resource-resolver, sbc-inbound, sbc-outbound, sbc-sip-sidecar, test-call-manager, vg-connector | `JAMBONES_REDIS_PASSWORD` and `REDIS_PASSWORD` (`redis-password`) |
| drachtio (sbc-sip) | `REDIS_PASSWORD`, passed as `--blacklist-redis-password "$(REDIS_PASSWORD)"` so it never appears in the pod spec |
| update-api-ban-list | `REDIS_USERNAME=apiban`, `REDIS_PASSWORD` (`apiban-password`); needs vg-api-ban with `REDIS_USERNAME` support (Cognigy/vg-api-ban#38) |

vg-redis reads `JAMBONES_REDIS_PASSWORD`, then `REDIS_PASSWORD`. media-processor and the ioredis-based
services read `REDIS_PASSWORD`. drachtio sends the password to the Redis nodes only, never to Sentinel.

## Rollout

- `update-api-ban-list` logs in as the ACL user `apiban`, so its image must carry
  [vg-api-ban#38](https://github.com/Cognigy/vg-api-ban/pull/38) (`REDIS_USERNAME`). An older client
  ignores the variable, logs in as `default` with the `apiban` password, and fails `WRONGPASS` on
  every hourly run. The chart refuses the render rather than let that ship: set `apiBan.image` to a
  build that carries it. `redisHa.vgAuth.apiBanMinVersion` is the version it checks against, and
  only the tag is visible to the chart, so a non-semver tag is left alone and the choice is still
  the operator's. Empty disables the check.
- Turning auth on restarts redis-ha, and its in-memory data is lost.
- The blocklist refills on the next CronJob run. Temporary bans and call counters do not refill.
- Every client must get the password in the same release. A client without it fails with
  `NOAUTH Authentication required`.

## Rollback

Turn the switch off and `redisHa.auth.enabled: false` in the **same** release:

```yaml
global:
  fedramp:
    redisAuth: false          # documented deviation; or redisHa.vgAuth.enabled: false outside the profile
redisHa:
  auth:
    enabled: false
```

`existingSecret` can stay set; with `auth.enabled: false` nothing reads it. Switching off alone, with
`auth.enabled: true` and `existingSecret: redis-ha-auth` left in the overlay, is refused: redis-ha would
keep requiring the password from the kept Secret while every client stops sending it.

Rollback restarts redis-ha too, with the same data loss as in Rollout. The Secret `redis-ha-auth` stays
(`resource-policy: keep`); delete it by hand if it is no longer wanted.

## Rotation

1. Delete the Secret `redis-ha-auth` and reconcile. The chart mints new passwords.
2. Restart redis-ha, then every Redis client.

Until both sides are restarted, clients fail with `WRONGPASS`.

## Verify

```bash
kubectl -n <ns> exec redis-ha-node-0 -c redis -- redis-cli ping                       # NOAUTH Authentication required.
kubectl -n <ns> exec redis-ha-node-0 -c redis -- bash -c 'REDISCLI_AUTH=$REDIS_PASSWORD redis-cli acl log'   # empty after a CronJob run
kubectl -n <ns> exec redis-ha-node-0 -c redis -- bash -c \
  'redis-cli --user apiban --pass "$(sed -n "s/^user apiban on >\([^ ]*\).*/\1/p" /opt/bitnami/redis/acl/users.acl)" set foo bar'   # NOPERM
```

## Not covered

- **Sentinel authentication.** media-processor does not set a Sentinel password, and drachtio never
  sends one.
- **TLS on the same connections.** That is option A of the SC-8 work (CGY-42571, docs/011-redis-tls.md
  on its branch).
