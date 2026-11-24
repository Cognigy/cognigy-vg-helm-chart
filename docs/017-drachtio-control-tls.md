# TLS on the drachtio control hop

sbc-sip's drachtio dials sbc-inbound and sbc-outbound over mutual TLS, with certificates from a chart-minted CA.
This is item A10 of the FedRAMP SC-8 work map (CGY-46071, epic CGY-41294). The same approach for Redis and MySQL is
in docs/011-redis-tls.md and docs/012-mysql-tls.md; the drachtio to sbc-call-router hop (A9) has its own switch.

## Why

In Kubernetes, sbc-inbound and sbc-outbound do not connect to drachtio. They listen (vg-drachtio-srf `srf.listen`)
on `DRACHTIO_PORT` (`sbcInbound.ports.tcp` / `sbcOutbound.ports.tcp`, 4000), and drachtio in sbc-sip opens a TCP
connection to one of them for every new SIP request it hands over. sbc-call-router tells drachtio where to go: it
answers drachtio's routing request with `sbc-inbound:4000` or `sbc-outbound:4000`. That connection carries every
SIP message and SDP of the call. sbc-sip runs on the host network, outside the mesh, so the hop was plaintext.

It also carries the shared secret. In listen mode, vg-drachtio-srf sends `authenticate|<secret>` to whoever
connects, as soon as the connection is up. The SBC side therefore checks a client certificate before that
(mTLS): a peer without a certificate from the chart's CA never gets the secret. This also remediates
CSA-103606 (DSRF-AC3-002) and the control-channel part of CSA-103767.

## Values

```yaml
drachtioControlTls:
  enabled: false                   # the hop on sbc-sip, sbc-inbound, sbc-outbound and sbc-call-router
  prepare: false                   # cutover step 1: certificates minted and mounted, nothing switched
  secretName: drachtio-control-tls # prefix of the four Secrets
  certValidityDays: 3650
  clusterDomain: cluster.local     # on the server certificates
  drachtioMinVersion: "1.3.28"     # older semver drachtio.image refused while on; "" switches the check off
  minImageVersions:                # first releases with CGY-46071; older images refused while on
    sbcInbound: "2026.24.0-95"     # "" leaves the image unchecked, which the FedRAMP profile refuses
    sbcOutbound: "2026.24.0-95"
    sbcCallRouter: "2026.24.0-95"
  allowUncheckedImages: false      # profile only: let images whose tag cannot be checked pass (a deviation)
```

Under the FedRAMP profile only `enabled` is ignored; the other keys still apply, and with the hop on the profile
requires `drachtioMinVersion` and all three `minImageVersions`.

Off by default. With the FedRAMP profile on, `global.fedramp.drachtioControlTls` decides instead and
`drachtioControlTls.enabled` is ignored (docs/009-fedramp-profile.md). That key is `true` in `values.yaml`: the
chart's default images (vg-drachtio 1.3.28, sbc-inbound, sbc-outbound and sbc-call-router 2026.24.0-95 or later)
carry CGY-46071, so a FedRAMP install runs the hop over mTLS from the start. An environment that already runs the
profile from an older chart gets the switch with the upgrade: that upgrade is the cutover (see Rollout), so stage
the certificates first with `drachtioControlTls.prepare: true` and `global.fedramp.drachtioControlTls: false`, then
remove the override in a maintenance window. `false` is a deviation (docs/009).

vg-drachtio 1.3.24 to 1.3.27 were released without the outbound TLS options; Cognigy/vg-drachtio#66 shipped in
1.3.28, which is `drachtioMinVersion` and the chart's default `drachtio.image`.

`prepare` mints and mounts the certificates (Secrets, volumes, `fsGroup`, checksums) without any of the variables
below, so the pods roll once and keep running in plaintext. It is the first step of the cutover (see Rollout). It
switches nothing, so it applies under the FedRAMP profile too.

## What the switch renders

| Workload | Change |
|---|---|
| sbc-sip, drachtio container (StatefulSet and DaemonSet) | `DRACHTIO_OUTBOUND_TLS_CA_FILE`, `DRACHTIO_OUTBOUND_TLS_CERT_FILE`, `DRACHTIO_OUTBOUND_TLS_KEY_FILE` under `/etc/drachtio-control-tls`; Secret `<secretName>-client-sbc-sip` mounted 0440; `fsGroup: 1000` unless `sbc.sip.podSecurityContext` sets one; `checksum/drachtio-control-tls` |
| sbc-inbound | `DRACHTIO_LISTEN_TLS_CERT_FILE`, `DRACHTIO_LISTEN_TLS_KEY_FILE`, `DRACHTIO_LISTEN_TLS_CA_FILE` under `/etc/drachtio-control-tls`; Secret `<secretName>-sbc-inbound` mounted 0440; `fsGroup: 1000` unless `sbcInbound.podSecurityContext` sets one; `checksum/drachtio-control-tls` |
| sbc-outbound | the same with `<secretName>-sbc-outbound` and `sbcOutbound.podSecurityContext` |
| sbc-call-router | `DRACHTIO_CONTROL_TRANSPORT=tls`: the routes become `sbc-inbound:4000;transport=tls`, which makes drachtio dial TLS |

With only `prepare` on, everything in the table renders except the variables (`DRACHTIO_OUTBOUND_TLS_*`,
`DRACHTIO_LISTEN_TLS_*`, `DRACHTIO_CONTROL_TRANSPORT`). The port does not change, so the NetworkPolicies stay as they are. Each pod mounts its own certificate and key and
the CA certificate; never another pod's key or the CA key. With the switch off the render is unchanged.

drachtio verifies the name it dials, which is the service name in the route (`sbcInbound.serviceName`, short). It
trusts only the chart's CA, allows TLS 1.2 and 1.3 with ECDHE and AES-GCM only, and presents the client certificate.
sbc-inbound and sbc-outbound load their certificate and key, replace Node's default roots with the chart's CA,
and require a client certificate signed by it (`requestCert: true, rejectUnauthorized: true`). Every component
refuses to start with a half-set or unreadable configuration and never falls back to plaintext (the per-repo
contract is in the vg-drachtio, vg-sbc-inbound, vg-sbc-outbound and vg-sbc-call-router PRs of CGY-46071).

## Certificates

The chart creates the CA and the certificates itself (`vg.drachtioControlTls.material` in
`templates/_drachtio-control-tls.tpl`, the Secrets in `templates/common-secrets/drachtio-control-tls.yaml`), with
the reuse logic of the Redis TLS certificates (docs/011). The CA is dedicated to this hop: it signs only the
sbc-inbound and sbc-outbound server certificates and the sbc-sip drachtio client certificate, so no other
certificate of the chart (Redis, MySQL, call-router) is accepted on 4000. Sprig's `genCA` / `genSignedCert` (RSA 2048, SHA-256):

| Secret | Keys | Mounted into |
|---|---|---|
| `drachtio-control-tls-ca` | `ca.crt`, `ca.key` | nothing: the chart signs certificates with it on later renders |
| `drachtio-control-tls-sbc-inbound` | `tls.crt`, `tls.key`, `ca.crt` | sbc-inbound |
| `drachtio-control-tls-sbc-outbound` | `tls.crt`, `tls.key`, `ca.crt` | sbc-outbound |
| `drachtio-control-tls-client-sbc-sip` | `tls.crt`, `tls.key`, `ca.crt`; CN `sbc-sip` | the drachtio container of sbc-sip |

- DNS names of a server certificate: the service name sbc-call-router routes to (`sbcInbound.serviceName` /
  `sbcOutbound.serviceName`), short, `.<ns>`, `.<ns>.svc` and `.<ns>.svc.<clusterDomain>`. No IP addresses and no
  `localhost`: nothing dials the SBCs' drachtio port by IP.
- Every render reads the Secrets back through `lookup`. With the stored CA it reuses the certificates it signed.
  A certificate Secret that is missing, lacks `tls.crt` or `tls.key`, or carries a different `ca.crt` is signed anew
  with the stored CA. A server Secret also carries a hash of its DNS names (`cognigy.com/dns-names-sha256`); when
  the names change (namespace, `serviceName`, `clusterDomain`) that certificate is signed anew.
- An existing server or client Secret without `ca.crt` is refused rather than overwritten (an external issuer).
  So is a `drachtio-control-tls-ca` that lacks `ca.crt` or `ca.key`: minting a new CA in its place would re-sign
  every certificate and roll three workloads without anyone asking for it. Delete it to rotate the CA.
- Extended key usage: every certificate carries both serverAuth and clientAuth, because Sprig's `genSignedCert`
  cannot restrict it, and the SBCs check the client certificate's CA, not its name. An sbc-inbound or sbc-outbound
  server key would therefore pass as a client certificate on the other SBC. Its only holders are the SBC pods,
  which already have `DRACHTIO_SECRET` in their environment, so it gives them nothing new. Checking the client CN
  `sbc-sip` in the SBCs is a possible follow-up.
- The Secrets carry `helm.sh/resource-policy: keep`. Turning the switch off leaves them, so turning it on again
  reuses the CA. A present Secret therefore does not mean the hop is on.
- `helm template` and `--dry-run` have no cluster access and mint on every render. That is a render artefact, not a
  rotation. A tool that renders without cluster access (Argo CD, `helm template | kubectl apply`) would mint a new
  CA on every sync and roll three workloads each time; such renderers are not supported with this switch.

**Rotation.** The pods read their certificates only at start, so they carry a checksum of their certificate and
the CA, and a new certificate rolls them:

| Delete | Effect on the next reconcile |
|---|---|
| `drachtio-control-tls-ca` | new CA and all three certificates; sbc-sip, sbc-inbound and sbc-outbound roll |
| `drachtio-control-tls-sbc-inbound` / `-sbc-outbound` | new server certificate from the same CA; that SBC rolls |
| `drachtio-control-tls-client-sbc-sip` | new client certificate from the same CA; sbc-sip rolls |

While a new CA rolls out, pods on different CAs fail the handshake, which fails calls until all three have
restarted. Rotate the CA in a maintenance window, like the first rollout.

**Expiry.** The CA and every certificate get `certValidityDays` (3650 days) from the day they are signed. A
certificate re-signed late in the CA's life (a deleted leaf Secret, a name change) gets the full 3650 days and
outlives its CA; it stops working when the CA expires. When the CA expires, every call fails at once. The chart
compares only the `ca.crt` text, so it never re-signs because of expiry, and there is no expiry alert yet. Read the
end dates after the rollout (Verify) and set a reminder to rotate the CA well before its end date. Whether 10-year
certificates and a manual reminder are acceptable under SC-12 / SC-17, or an x509-exporter alert is needed, is an
open question.

## Rollout

**All or nothing.** The switch changes sbc-sip, sbc-inbound, sbc-outbound and sbc-call-router at once. Any mix
fails calls, closed and never in plaintext:

- drachtio dials TLS (the call-router's route says so) and the SBC still listens in plaintext: the handshake fails.
- The SBC listens with TLS and drachtio dials plaintext, or presents no client certificate: the SBC drops the
  connection before sending the secret.
- drachtio and the SBC hold certificates from different CAs (during a CA rotation): the handshake fails.

So, in this order:

1. **Images first.** All four need the releases that carry CGY-46071 before the switch flips: vg-drachtio 1.3.28 or
   newer (`drachtio.image`, enforced: an older semver tag fails the render, see below), and the sbc-inbound,
   sbc-outbound and sbc-call-router images with CGY-46071 (`sbcInbound.image`, `sbcOutbound.image`,
   `sbcCallRouter.image`). An older SBC image ignores `DRACHTIO_LISTEN_TLS_*` and keeps listening in plaintext, so
   every call fails. An older call-router ignores `DRACHTIO_CONTROL_TRANSPORT` and keeps routing without
   `;transport=tls`: drachtio then dials plain TCP and logs only a warning, so calls fail against the TLS
   listeners, and where the SBCs are old too the hop silently stays plaintext.
   `drachtioControlTls.minImageVersions` holds the first build of each that carries CGY-46071, `2026.24.0-95` for
   all three, and the render refuses an older image (see below); the FedRAMP profile requires all three. The
   chart's default images are those builds or newer.
   Roll the images out with the switch off first; the new images behave exactly as before while nothing is set.
   Under the FedRAMP profile, which turns the hop on by default, that means holding it off with
   `global.fedramp.drachtioControlTls: false` until step 3. The chart's default `drachtio.image` (1.3.28) already
   carries the options; a pinned older one fails the render.

   **The minimums survive the release cut.** The release-cut automation rewrites every image on main to
   `<train>-rc1` (for example `2026.23.0-rc1`), and main can still publish `<train>-<n>` preview builds after the cut
   (`2026.23.0-140` followed `2026.23.0-rc1`). The chart counts the release line of a train (`-rcK`, the release,
   patch releases) as newer than every numbered build of that train, so the `2026.24.0-rc1` images the 2026.24 cut
   writes, the later preview builds and the 2026.24 releases all pass the `2026.24.0-95` minimums, and later trains
   pass anyway. The minimums never need to move.

   **A numbered minimum must predate its train's cut.** That ordering is only true for a build made before the cut:
   for 2026.23, `rc1` was cut after `-134` and lacks whatever came in `-135` to `-140`. A minimum of `2026.23.0-140`
   would therefore let `2026.23.0-rc1` pass without the change. `2026.24.0-95` was built before the 2026.24 cut.
   A change merged after its train's cut has no safe minimum in that train: a post-cut `<train>-<n>` lets the
   train's release line pass without the change, and `<train>-rc1` was cut before the change and also refuses the
   post-cut main builds that carry it. Use the first numbered build of the next train (not yet cut) that carries
   the change. Until main reaches that train its post-cut builds are refused, which fails closed.

   **A minimum must be on the main line:** a numbered build `<train>-<n>` built before its train's cut, or the cut
   `<train>-rc1` for a change merged before that cut; never a later candidate (`-rc2` and up), a release or a patch
   release. The chart treats every tag of a later train as newer,
   but main's first builds of the next train are cut from main at the time, which may be before a patch release or
   a late release candidate of the previous train was built (patch work can also happen only on the release
   branch). A change that first shipped in such a patch or late rc is then not known to be in those builds, and a
   minimum there would let them pass. A pre-cut numbered minimum, or `-rc1` for a change merged before the cut,
   does not have this gap: every later main build comes after it.
2. **Mount the certificates** with `drachtioControlTls.prepare: true`, the variables still unset. The pods roll once
   and behave as before. `prepare` does not prove the files are usable: nothing reads them yet. Before the cutover,
   run the checks in [Verify: before the cutover](#before-the-cutover) in all three containers.
3. **Cut over in one release, in a maintenance window.** Set `drachtioControlTls.enabled: true` (under the
   profile: remove the `global.fedramp.drachtioControlTls: false` override) and keep `prepare`. That one change switches drachtio
   (`DRACHTIO_OUTBOUND_TLS_*`), the SBC listeners (`DRACHTIO_LISTEN_TLS_*`) and the call-router transport together;
   the certificates and checksums stay as they were in step 2. The four workloads roll independently, and calls
   fail while old and new pods are mixed (a TLS dial to an old listener or the other way round). sbc-sip sets the
   length of that window: it rolls one pod at a time (StatefulSet) or one node at a time (DaemonSet), so the window
   is about (number of sbc-sip pods) × (call drain + start time per pod), not minutes. Calls that are already set up
   keep their media, but SIP in-dialog requests that need a new control connection can fail too. Every sbc-sip
   restart drops the calls on that node anyway. Plan it like a full sbc-sip roll with inbound and outbound calls
   paused, and watch it (below).
4. **Rollback** is the same flip back, with the same window: turn the switch off (or
   `global.fedramp.drachtioControlTls: false` under the profile, a documented deviation), keep `prepare`, and wait
   for all four to roll. Roll back when, after all four rollouts have finished:
   - test calls (one inbound, one outbound) still fail 10 minutes later, or
   - an sbc-inbound, sbc-outbound or sbc-call-router pod is not Ready, or an SBC is in CrashLoopBackOff (a refused
     configuration exits at start).

**Watch during the cutover and the rollback:**

- The new-call rate (inbound and outbound) on the VG dashboards. It drops while pods are mixed and must recover
  once all four have rolled.
- SBC pods: `kubectl -n <ns> get pods -l 'app in (sbc-inbound,sbc-outbound,sbc-call-router)' -w` for restarts and
  CrashLoopBackOff.
- drachtio, on every sbc-sip pod, not only `sbc-sip-0`. A server certificate drachtio does not accept (another CA,
  wrong name, expired) logs `certificate of <host>:<port> refused: <reason>`:

  ```bash
  for p in $(kubectl -n <ns> get pods -l app=sbc-sip -o name); do
    echo "== $p"; kubectl -n <ns> logs "$p" -c drachtio --since=30m | grep -E 'certificate of .* refused:|TLS handshake failed|has no ;transport=tls'
  done
  ```

  `has no ;transport=tls` means drachtio has the CA but the call-router route is still plaintext (an old
  call-router image, or the call-router not rolled yet).
- The SBCs log `drachtio control hop: TLS handshake refused` (at most once per interval, with a `suppressed` count)
  when they reject a handshake, and `drachtio control hop: mutual TLS on (client certificate required)` at start:

  ```bash
  for d in sbc-inbound sbc-outbound; do
    kubectl -n <ns> logs deploy/$d --since=30m | grep -E 'drachtio control hop: (TLS handshake refused|mutual TLS on|plaintext)'
  done
  ```

  `drachtio control hop: plaintext` after the cutover means that pod did not get the variables, or runs an image
  without CGY-46071 (then the line is missing entirely).
- The SBC gauges `sbc_inbound_drachtio_listen_tls_enabled` and `sbc_outbound_drachtio_listen_tls_enabled`
  (vg-sbc-inbound#183, vg-sbc-outbound#116): 1 when the listener runs mutual TLS, 0 otherwise. An image with the
  gauge exports it on every pod, label-less with a default of 0, also while TLS is off, so 0 means plaintext. An
  image without CGY-46071 exports no gauge at all. The gauges are scraped only with `podMonitors.enabled: true`
  (default `false`), a prerequisite for this check. The PodMonitors are named
  `prom-cognigy-monitor-cognigy-vg-sbc-inbound` and `-sbc-outbound` in `podMonitors.namespace`, so the Prometheus
  Operator's `job` label is `<podMonitors.namespace>/<name>`. After the cutover every SBC pod must report 1. The
  suggested alert, for FedRAMP clusters with the hop on, compares against the scrape targets, so one old or
  plaintext pod among new ones fires (and the same for sbc-outbound), for a few minutes:

  ```promql
  # every scraped sbc-inbound pod that does not report mutual TLS: an image without the gauge, or TLS off
  up{job=~".*/prom-cognigy-monitor-cognigy-vg-sbc-inbound"} == 1
    unless on(namespace, pod) (sbc_inbound_drachtio_listen_tls_enabled == 1)
  # the same per pod, for images that export the gauge
  sbc_inbound_drachtio_listen_tls_enabled == 0
  ```

  Do not use `absent(sbc_inbound_drachtio_listen_tls_enabled)` for this: it returns one series without labels, and
  only when no pod anywhere reports the gauge, so it means "scrape lost", not "one pod is plaintext". The alerts
  also catch a later regression to plaintext (an override, a rollback, a branch build). This chart ships no alert
  rule: the rule in cognigy-monitoring-stack is a follow-up. The drachtio side (`has no ;transport=tls`, an old
  call-router) has no metric yet and is found only in the logs.
- **Post-dial delay of about 64 s with no TLS error in drachtio's log** means an SBC is refusing drachtio's client
  certificate. Under TLS 1.3 drachtio finishes its side of the handshake before the server checks the client
  certificate, so drachtio sees only a closed connection and answers the request when its timer runs out. Look for
  `TLS handshake refused` in the SBC logs.

**Fails closed.** Nothing falls back to plaintext. drachtio refuses to start when the CA, the certificate or the key
cannot be loaded, and the SBCs exit at start with a half-set configuration. A wrong CA, a wrong name or a missing
client certificate fails the call, not the encryption.

**Refused renders.** While the switch is on, the chart fails the render instead of shipping a hop that cannot work
or that verifies less:

- a semver `drachtio.image` below `drachtioControlTls.drachtioMinVersion` (1.3.28). An older drachtio ignores the
  variables and fails every TLS dial ("TLS requested but not configured"). Suffixed (`1.3.23-fips`), `v`-prefixed
  and digest-pinned forms are judged by their X.Y.Z core. Outside the profile a non-semver tag (a branch build) is
  left alone, and for a build known to carry the options `drachtioMinVersion: ""` switches the check off; under the
  profile an empty `drachtioMinVersion` is refused (as are empty `minImageVersions`), and so is a non-semver tag
  (below).
- an `sbcInbound.image`, `sbcOutbound.image` or `sbcCallRouter.image` older than its
  `drachtioControlTls.minImageVersions` entry, and, under the FedRAMP profile, an empty entry. A minimum must be
  `YYYY.N.P`, `YYYY.N.P-<number>` or `YYYY.N.P-rc<number>` (an optional leading `v`); anything else
  (`2026.24.0-foo`, `2026.24.0-80-fips`) fails every render, also with the hop off. The tags are calendar versions,
  ordered as they are built, not by semver precedence (which would put `2026.24.0-78` below `2026.24.0-rc1`). The
  train is `YYYY.N`: main builds `YYYY.N.P-<number>` in order, then the release line, cut from main after them,
  goes `-rc1`, `-rc2`, …, the release `YYYY.N.P`, then patch releases `YYYY.N.(P+1)` (with any candidates).
  Minimums belong on the main line (`<train>-<n>` built before the cut, or `<train>-rc1` for a change merged
  before the cut, see Rollout); the other rows
  show how the chart orders the remaining shapes. So:

  | Minimum | Passes | Refused |
  |---|---|---|
  | any | every tag of a later train (`2026.25.0-3`, `2026.25.0-rc1`, `2026.25.0`, `2026.25.1`, `2027.1.0-1` against a `2026.24` minimum); the exact tag of the minimum | every tag of an earlier train |
  | numbered, `2026.24.0-80` | `2026.24.0-<n>` with n ≥ 80, as a number (`-100` passes, `-9` does not); the release line `2026.24.0-rcK`, `2026.24.0`, `2026.24.1-rcK`, `2026.24.1` (cut after build 80, see Rollout) | `2026.24.0-79`; `2026.24.1-5` (a numbered build of another P) |
  | rc, `2026.24.0-rc1` | `2026.24.0-rcK` with K ≥ 1 (`rc10` after `rc2`), the release `2026.24.0`, patches `2026.24.1` and their candidates | `2026.24.0-<n>`, `2026.24.1-5` (main builds come before the release line) |
  | release, `2026.24.0` (not on the main line) | `2026.24.0`, patches `2026.24.1` and their candidates | `2026.24.0-rcK` (before the release), `2026.24.0-<n>`, `2026.24.1-5` |
  | patch, `2026.24.1` (not on the main line) | `2026.24.1`, `2026.24.2` | `2026.24.0`, `2026.24.1-rcK`, `2026.24.0-<n>`, `2026.24.1-5` |

  To accept an image the table refuses (a release-branch tag known to carry the change), set the minimum to
  exactly its tag. The Rollout rules still apply: a numbered tag as the minimum must predate its train's cut, or
  the train's release line passes without the change. `v`-prefixed and digest-pinned tags (`:2026.24.0-81@sha256:…`) are judged by the tag; a
  registry port is not mistaken for one.
- a tag that cannot be checked, under the FedRAMP profile only: a digest-only reference, `latest`, no tag, a branch
  build, or a tag with another suffix (`2026.24.0-80-fips`, uppercase `RC`, `_hotfix`) on an SBC or call-router
  image; for drachtio anything but the tags vg-drachtio releases, `X.Y.Z` (optionally `v`-prefixed or with `-fips`):
  a pre-release such as `1.3.28-rc1` (which may predate the change), `1.3.28.1`, a branch build. Outside the
  profile drachtio tags are judged by their `X.Y.Z` core, as before.
  Pin a release tag, with the digest after it if needed, or record a deviation and set
  `drachtioControlTls.allowUncheckedImages: true` (docs/009-fedramp-profile.md). Outside the profile such tags are
  not checked: the operator's call, as before.
- `DRACHTIO_OUTBOUND_TLS_VERIFY` with a value drachtio reads as off (`0`, `false`, `no`, `off`, any case), or from a
  `valueFrom`, in `drachtio.extraEnvVars` or `cognigyEnv` (the drachtio container reads `cognigy-env`). drachtio
  would refuse to start with it anyway; the chart says so at render time. The chart itself never renders it.
- Under the FedRAMP profile, an `extraEnvVars` entry named after one of the hop's variables: `drachtio`
  (`DRACHTIO_OUTBOUND_TLS_CA_FILE`, `_CERT_FILE`, `_KEY_FILE`), `sbcInbound` and `sbcOutbound`
  (`DRACHTIO_LISTEN_TLS_*`), `sbcCallRouter` (`DRACHTIO_CONTROL_TRANSPORT`). It would override the profile without a
  `global.fedramp.*` deviation.

**Non-root.** The images run as uid/gid 1000 (vg-drachtio `USER drachtio`, the SBC images `USER 1000`), and the
Secret files are 0440 and owned by root. The chart therefore adds `fsGroup: 1000` to each of the three pods unless
its `podSecurityContext` already sets an `fsGroup` (any value works: kubelet gives the files that group and every
container gets it as a supplementary group). An environment that sets `fsGroup` keeps it.

## Verify

### Before the cutover

After step 2 (`prepare`), check in each of the three containers that the files are readable as the container's
own user (uid 1000, through `fsGroup`), that each certificate chains to the CA, and that each key matches its
certificate. `kubectl exec` runs as the container's runtime user, so a permission problem shows up here.

```bash
# drachtio in every sbc-sip pod: readable as uid 1000 (the image has no openssl; the content is checked below)
for p in $(kubectl -n <ns> get pods -l app=sbc-sip -o name); do
  kubectl -n <ns> exec "$p" -c drachtio -- sh -c 'id; for f in ca.crt tls.crt tls.key; do cat /etc/drachtio-control-tls/$f >/dev/null && echo "$f readable"; done'
done
# Its certificate and key, from the Secret it mounts: chains to the CA, key matches
t=$(mktemp -d); for k in ca.crt tls.crt tls.key; do
  kubectl -n <ns> get secret drachtio-control-tls-client-sbc-sip -o jsonpath="{.data.${k//./\\.}}" | base64 -d >"$t/$k"; done
openssl verify -CAfile "$t/ca.crt" "$t/tls.crt"
[ "$(openssl x509 -in "$t/tls.crt" -noout -pubkey)" = "$(openssl pkey -in "$t/tls.key" -pubout)" ] && echo "key matches"

# sbc-inbound and sbc-outbound, in every pod, as the app's own user, with Node's crypto (the image has no openssl)
for d in sbc-inbound sbc-outbound; do
  for p in $(kubectl -n <ns> get pods -l app=$d -o name); do
    kubectl -n <ns> exec "$p" -- node -e '
      const fs = require("fs"), { X509Certificate, createPrivateKey } = require("crypto");
      const dir = "/etc/drachtio-control-tls/";
      const ca = new X509Certificate(fs.readFileSync(dir + "ca.crt"));
      const cert = new X509Certificate(fs.readFileSync(dir + "tls.crt"));
      const key = createPrivateKey(fs.readFileSync(dir + "tls.key"));
      console.log("uid", process.getuid(), "chains to CA:", cert.verify(ca.publicKey),
        "key matches:", cert.checkPrivateKey(key), "SANs:", cert.subjectAltName, "notAfter:", cert.validTo);'
  done
done
```

Every line must show the files readable, `OK` / `true` for the chain and the key, and the SANs of the service name.

### After the cutover

```bash
# The switch reached all four workloads
kubectl -n <ns> get deploy sbc-call-router -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DRACHTIO_CONTROL_TRANSPORT")].value}'
for d in sbc-inbound sbc-outbound; do
  kubectl -n <ns> get deploy $d -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DRACHTIO_LISTEN_TLS_CA_FILE")].value}{"\n"}'
done

# The SBC listener speaks TLS and asks for a client certificate (run from a node or any pod with openssl)
openssl s_client -connect sbc-inbound.<ns>.svc.cluster.local:4000 -servername sbc-inbound </dev/null 2>&1 \
  | grep -E 'Acceptable client certificate CA names|subject=|Protocol|Cipher'
# Without a client certificate the connection is closed and no "authenticate|" line arrives

# Expiry: end dates of the CA and the three certificates
for s in drachtio-control-tls-ca:ca.crt drachtio-control-tls-sbc-inbound:tls.crt drachtio-control-tls-sbc-outbound:tls.crt \
  drachtio-control-tls-client-sbc-sip:tls.crt; do
  k=${s#*:}; printf '%s ' "${s%%:*}"
  kubectl -n <ns> get secret "${s%%:*}" -o jsonpath="{.data.${k//./\\.}}" | base64 -d | openssl x509 -noout -enddate
done

# A call: inbound and outbound calls connect. Then run the log checks of the watch plan above on every pod.
```

## Not covered yet

- FIPS (X1, X2): the encryption counts for SC-8(1) only with a FIPS 140-3 validated module on both ends (drachtio's
  OpenSSL 3, Node's OpenSSL in the SBCs), and keys generated in one. Helm's Go crypto is not running in FIPS mode.
- The mesh exception for 4000 under STRICT mTLS (CGY-46093).
- The default drachtio admin secret literal (CGY-46072) and the drachtio admin port 9022 binding.
- TLS session resumption: every new SIP request opens a new TLS connection. Measure the handshake cost before adding
  it.
