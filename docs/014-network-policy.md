# NetworkPolicy — default-deny, stage 1 & 2

CSA-110265 (VHC-SC7-001, SC-7) and CSA-110267 (VHC-AC4-001, AC-4) both come from the same
underlying gap: almost no workload in this chart has a Kubernetes `NetworkPolicy`, and the
two that did (`silero-vad`, `feature-server` v2-api) were ingress-only — nothing restricted
egress. SC-7 (boundary protection) and AC-4 (information-flow enforcement) are two
control-framework lenses on the same defect, and both tickets ask for the same remediation:
default-deny ingress **and** egress per workload, with explicit allow rules, shipped enabled
under the FedRAMP profile, rolled out in stages with non-prod verification.

Stage 1 shipped the reusable pattern, plus default-deny egress for the two workloads where it
was actually safe to add then — `silero-vad` (egress added to its existing policy) and
`vg-resource-resolver` (a new policy, ground-up). Stage 2 (this PR) applies the same
mechanical pattern to the rest of the chart's "lower-risk" workloads: `homer`, `jaeger`,
`vg-connector`, `media-processor`, `vg-audio-manager`, `test-call-manager`, the billing
CronJobs, `api-ban`, `api-migrator`, `audit-cleanup`, `telegraf`, `influxdb`,
`heplify-server`, `otel-collector`, `sbc-inbound`, `sbc-outbound`, and `api-server` — see
"## Stage 2" below. `vg-console`, `vad-autotuner` and `test-harness` were explicitly excluded
from stage 2 (not used in production deployments). `feature-server`'s own egress and a
handful of specific external-egress sub-problems stay deferred after review — see "Deferred
to a later stage" below.

## The pattern

`templates/_network-policy.tpl` (companion to `templates/_fedramp.tpl`):

- `vg.fedramp.networkPolicyEnabled` — the same "FedRAMP forces, per-service override
  ignored" shape as every other feature in `templates/_fedramp.tpl`. `global.fedramp.networkPolicyEnabled`
  (`true` by default) wins while the profile is on; a workload's own `networkPolicy.enabled`
  applies otherwise.
- `vg.networkPolicy.dnsEgress` — the DNS allow rule every default-deny-egress policy needs
  (CoreDNS via the standard `kube-system` / `k8s-app: kube-dns` label). A cluster running
  NodeLocal DNSCache (common on EKS/GKE, optional on AKS) instead resolves DNS through a
  per-node listener (typically `169.254.20.10`), not a `kube-dns` pod directly — a
  `podSelector`-based rule cannot match that node-local address at all. An environment using
  it needs an explicit `networkPolicy.egressTo` `ipBlock` entry for that address on every
  egress-isolated workload, or DNS resolution breaks entirely once the policy is enforced.
- `vg.networkPolicy.mysqlEgress` / `vg.networkPolicy.redisEgress` / `vg.networkPolicy.influxdbEgress`
  — allow rules to this chart's own bundled data stores, by their actual Service/pod
  selector labels. Each renders **nothing** when the dependency isn't bundled in-cluster
  (e.g. `mysql.enabled: false` for an external MySQL) — there's no hostname-to-CIDR
  resolution at Helm template time, so an external data store needs an explicit entry in
  the workload's own `networkPolicy.egressTo` list instead (see below).
- `vg.networkPolicy.apiServerEgress` — **built but not wired to any workload yet** (stage 2,
  see below). Requires `global.fedramp.networkPolicyKubernetesApiCidr` and fails the render
  if it's missing: the control-plane endpoint differs by cloud (AKS/EKS/STACKIT) and can't be
  discovered at render time, so there's no safe default.

Every workload's `networkPolicy` values block carries the same shape now:

```yaml
networkPolicy:
  enabled: false          # forced true under the FedRAMP profile
  ingressFrom: []          # list of NetworkPolicyPeer, passed through via toYaml — not
                           # limited to podSelector; an ipBlock entry works too (see the
                           # sbc-sip note below)
  extraIngress: []         # list of NetworkPolicyIngressRule, appended verbatim
  egressTo: []             # list of NetworkPolicyEgressRule, for anything the chart
                           # can't resolve to an in-cluster podSelector on its own
```

`vg-resource-resolver` additionally has `dnsNamespaceSelector` (empty uses the shared
`kube-system`/`k8s-app: kube-dns` rule below; set it only for a non-standard DNS location)
and `monitoringNamespaceSelector` (empty falls back to `podMonitors.namespace`, matching
every other workload's `allowMonitoringScrape` rule).

`silero-vad` and `vg-resource-resolver` both render their application-port ingress rule only
while `ingressFrom` is non-empty (`{{- with .Values.*.networkPolicy.ingressFrom }}`), never an
empty `from: []`: Kubernetes reads an ingress rule with an empty `from` list as "match every
source" — the opposite of what clearing the list to lock a workload down further is meant to
do (Copilot review, PR #1131). For `silero-vad`, clearing `ingressFrom` (with
`allowMonitoringScrape` also off) instead renders `ingress: []`, Kubernetes' actual deny-all
spelling. `vg-resource-resolver` never reaches `ingress: []`, even with both cleared: its
health-port rule (ported from main, see above) renders unconditionally.

## What stage 1 covers

| Workload | Change | Egress allow-list |
|---|---|---|
| `silero-vad` | Added `Egress` to an existing ingress-only policy | DNS; MySQL when `sileroVad.mysql.enabled` |
| `feature-server` (v2-api policy, `app: feature-server`) | **Ingress only, unchanged** — egress isolation deliberately deferred, see below | n/a |
| `vg-resource-resolver` | New policy (first ground-up default-deny+allow-list example), ported from main's original CSA-109614 implementation (#1099) with the shared pattern underneath | Ingress from its real callers (api-server, feature-server, feature-server-nightly, sbc-inbound, sbc-outbound), the health port open to any source (kubelet probes), plus a monitoring-namespace scrape rule on the metrics port; egress to DNS, MySQL, Redis, each `runtimeApiTargets` URL (port derived automatically, same as main), the bundled mock runtime API when deployed |
| `vg-events-api` | New policy (`templates/events-api/networkpolicy.yaml`, `vgEventsApi.networkPolicy`), modelled on `vg-resource-resolver`; renders only while the component is active | Ingress from this chart's Traefik on the app port (plus `ingressFrom`), the health port open to any source, a monitoring-namespace scrape rule on the metrics port; egress to DNS, Redis, InfluxDB, Homer and each AI cluster's JWKS URL (port derived automatically, same as `runtimeApiTargets`) |

`silero-vad` and `vg-resource-resolver` are the two workloads that actually get egress
isolation in this stage: both only talk to this chart's own in-cluster data stores (plus, for
`vg-resource-resolver`, its own `runtimeApiTargets` — handled automatically, see the note
below) — none of them need the not-yet-solved Kubernetes-API CIDR or a hostNetwork design
decision (see below). `feature-server`'s v2-api policy is included in this table because this
stage touched it (and should have added egress, by the original plan), but egress isolation
there was reverted in review — see "Deferred to a later stage". `ci/render-tests/fedramp-network-policy.test.sh`
covers all three in both FedRAMP-off (opt-in, unchanged) and FedRAMP-on (forced,
override-ignored) modes, including feature-server's ingress-only policy.

### An external MySQL or Redis

`vg.networkPolicy.mysqlEgress`/`redisEgress` only match the bundled in-cluster subchart/StatefulSet.
An environment pointing `mysql.host`/`redis.host` at an external database has no in-cluster
pod for the built-in rule to select, so the workload's own `networkPolicy.egressTo` needs an
explicit `ipBlock` entry for that external host's CIDR, e.g.:

```yaml
sileroVad:
  networkPolicy:
    egressTo:
      - to:
          - ipBlock:
              cidr: 203.0.113.10/32
        ports:
          - protocol: TCP
            port: 3306
```

### `vg-resource-resolver`'s external `runtimeApiTargets`

`resourceResolver.runtimeApiTargets` can point at external Cognigy.AI clusters, the same
unenumerable-hostname shape as the risk that got feature-server's egress isolation deferred
entirely (see below) — just with a much smaller blast radius: it's runtime-resource
*fallback*, not the primary call path. Unlike `feature-server`, this chart already knows
every target's URL (it's `resourceResolver.runtimeApiTargets` itself), so the policy derives
each target's port automatically (the URL's explicit port, or 443/80 by scheme) and allows
it to any address except link-local — the same rule main's original CSA-109614
implementation (#1099) used, ported here (PR #1131 review feedback) rather than requiring a
manual `egressTo` entry. No extra config is needed for `runtimeApiTargets` itself; use
`resourceResolver.networkPolicy.egressTo` for anything else this policy can't resolve on its
own (an external MySQL/Redis, a NodeLocal DNSCache address, etc. — see below). This also
applies to JWKS verification if `featureServer.v2Api` later gets its own egress-isolation
design (see below).

## Stage 2

The same mechanical pattern, applied to the chart's remaining "lower-risk" workloads (the
ones stage 1 already flagged as such — see the old "Deferred to a later stage" entry this
section replaces). `vg-console`, `vad-autotuner` and `test-harness` were explicitly excluded
— not used in production deployments (confirmed with the reviewer who requested stage 2).
`ci/render-tests/fedramp-network-policy-stage2.test.sh` covers all of it.

| Workload | Ingress | Egress |
|---|---|---|
| `homer` | api-server; this chart's own Traefik (own `ingress.yaml`, CSA-110266) | the bundled `postgresql` pod |
| `jaeger` | feature-server/nightly (compact/UDP); otel-collector (otlp-grpc); api-server (UI/query API); Traefik | DNS only (all-in-one) |
| `vg-connector` | health port (any source); Traefik — no in-cluster podSelector caller, its real traffic is external Genesys AudioHook/MS Teams via its own `ingressroute.yaml` | MySQL, Redis, sbc-sip/sbc-rtp via `egressToHostNetwork` (both `hostNetwork`, empty by default — see below) |
| `media-processor` | feature-server/nightly (grpc); the metrics port, any source — it also serves `/health`, so it can't be restricted to the monitoring namespace without risking readiness | Redis, only when `mediaProcessor.cache.type` is `"redis"` |
| `vg-audio-manager` | the http port, any source — same shared-port/readiness trade-off as media-processor's metrics port; the metrics port from the monitoring namespace | MySQL; `resourcesApiTargets` (auto-derived port, same mechanism as `runtimeApiTargets`) |
| `test-call-manager` | health port; metrics (monitoring namespace); Traefik — no in-cluster caller, same shape as `vg-connector`. Its clean-up CronJob gets its own egress-only policy | Redis; api-server via `ingress.api.host` (`VG_ENDPOINT`, auto-derived port, see below). The CronJob: its *own* ingress hostname (`cleanUpEndpoint`/`ingress.testCallManager.host`) — not api-server |
| billing (3 CronJobs) | none (egress-only) | MySQL; `daily-billing-reporting` also egresses to `sendToCentral.serverUrl` (auto-derived port) |
| `api-ban` | none (egress-only) | Redis (honours `redisHa.nameOverride` and container ports); `apiBan.endpoint` on TCP 443 only, to public addresses (private, link-local and `100.64.0.0/10` excluded, APBN-SC7-001) — stricter than `vg.networkPolicy.externalUrlEgress` |
| `api-migrator` (2 Jobs: `api-migrator`, `billing-grants`) | none (egress-only) | MySQL; `api-migrator` also egresses to InfluxDB (`JAMBONES_TIME_SERIES_HOST`) |
| `audit-cleanup` | none (egress-only) | api-server via `ingress.api.host` (auto-derived port) |
| `telegraf` | sbc-inbound/outbound/sbc-rtp (`STATS_HOST`); sbc-sip via `ingressFromHostNetwork` | influxdb; heplify-server's stats port |
| `influxdb-ai-retention` (hook Job, while `influxdb.aiRetention.enabled`) | none (egress-only) | InfluxDB (`influxdb.host`/`port`); an external InfluxDB needs `influxdb.aiRetention.networkPolicy.egressTo` |
| `influxdb` | the app port, any source — same shared-port/readiness trade-off as media-processor; sbc-sip via `ingressFromHostNetwork` | DNS only (pure ingress target) |
| `heplify-server` | the HEP-ingest port (udp) from sbc-rtp, plus sbc-sip via `ingressFromHostNetwork`; the stats port (tcp) from telegraf | the bundled `postgresql` pod |
| `otel-collector` | feature-server/nightly (OTLP gRPC+HTTP) | this chart's own jaeger (`jaegerEndpoint`, a `host:port` string — pointing it elsewhere needs `egressTo`, same expectation as `mysql.host`) |
| `sbc-inbound` | health port; metrics (monitoring namespace); the dtmf port from sbc-rtp; the drachtio/tcp port from sbc-sip via `ingressFromHostNetwork` | feature-server (SIP/TLS), sbc-rtp, MySQL, Redis, InfluxDB, telegraf (when `stats.telegraf`), tracing (`tracing.baseUrl`, auto-derived port, when set), resource-resolver (when enabled), api-server via `ingress.api.host` (`VG_API_BASE_URL`, auto-derived port) |
| `sbc-outbound` | same as sbc-inbound, minus the feature-server dependency | same as sbc-inbound, minus feature-server and api-server — nothing in this chart calls sbc-outbound on their behalf |
| `api-server` | health port; metrics (monitoring namespace); **Traefik only — not a podSelector list of application callers** (see below) | MySQL, Redis |

### `api-server`'s ingress is "from Traefik", not a caller list

Every other workload in this table admits ingress from its real *in-cluster* callers by
podSelector. `api-server` is the one exception on purpose: almost every real caller
(`sbc-inbound`, `webapp`, `test-call-manager`, `audit-cleanup`, `feature-server`/nightly)
reaches it through its own public ingress hostname (`ingress.api.host`), which Traefik
proxies to the Service. From `api-server`'s own pod's point of view, Traefik is the only
direct network peer that traffic ever has — a podSelector naming the *application* services
would be both wrong (they're not the actual source Kubernetes sees) and a false sense of
coverage. `vg.networkPolicy.fromTraefik` (`templates/_network-policy.tpl`) captures this:
it renders nothing when `traefik.enabled` is false (an external Traefik has no in-cluster
pod this policy could select — same reasoning as
`vg.fedramp.refuseInsecureTraefikEntrypoints`'s external-Traefik deviation path).
`homer`, `jaeger`, `vg-connector` and `test-call-manager` also use this helper for the same
reason: each has its own public `ingress.yaml`/`ingressroute.yaml`, and Traefik is the real
peer for that path regardless of whether the workload also has in-cluster callers.

### Calls to a workload's own public ingress hostname (not just `api-server`)

Several stage-2 workloads call api-server by its own public hostname rather than
cluster-local Service DNS: `sbc-inbound` (`VG_API_BASE_URL`), `test-call-manager`
(`VG_ENDPOINT`), `audit-cleanup` (`API_BASE_URL`/`LOGIN_URL`/`CLEANUP_URL`). Whether that
hairpins back into the cluster (reaching Traefik) or genuinely leaves and re-enters depends
on the environment's DNS/LB setup, not anything this chart can determine at render time — the
same "no chart-known CIDR" situation `vg-resource-resolver`'s `runtimeApiTargets` already
established a precedent for. Each of these egress rules therefore uses the same
`vg.networkPolicy.externalUrlEgress` helper: derive the port from the URL, allow it to
`namespaceSelector: {}` plus `0.0.0.0/0` except link-local. This is deliberately broad on the
destination address — the alternative (guessing a podSelector or requiring a mandatory
`egressTo` from every environment on day one) would either not work or block real traffic.

### sbc-sip as a caller, beyond `vg-resource-resolver`

Stage 1 only solved sbc-sip's `hostNetwork: true` ingress problem for `vg-resource-resolver`
(`ingressFromHostNetwork`, ported from main's #1200/CGY-44772). Stage 2 found four more
workloads sbc-sip calls the same way: `telegraf` (`STATS_HOST`), `influxdb` (direct write),
`heplify-server` (HEP ingest, udp), and `sbc-inbound`/`sbc-outbound` (the drachtio app-dispatch
port). Each gets its own `networkPolicy.ingressFromHostNetwork` field, same shape as
`vg-resource-resolver`'s — a CIDR peer list, empty by default, so an environment still has to
supply its node CIDR before these calls pass once the policy is enforced. `vg-connector`'s
egress to sbc-sip/sbc-rtp has the same limitation on the egress side instead
(`networkPolicy.egressToHostNetwork`), since it is the one workload in this batch that calls
*out* to a `hostNetwork` peer rather than being called by one.

## Stage 3

Found by checking whether CSA-110265/CSA-110267 could be closed after stage 2: three
workloads — `webapp`, `vg-pagerduty-agent` (plus its two helper Jobs,
`vg-pagerduty-agent-hypercare` and `vg-pagerduty-agent-hypercare-activate-remote`),
`sbc-call-router`, and `vg-traffic-sniffer` — had no `NetworkPolicy` at all and weren't on
anyone's exclusion list, unlike `vg-console`/`vad-autotuner`/`test-harness` (explicitly
confirmed with the reviewer as not used in production).

| Workload | Ingress | Egress |
|---|---|---|
| `webapp` | This chart's own Traefik only (own `ingress.yaml`, CSA-110266) — no in-cluster caller, no probes of its own | api-server, tracing, `webapp.cognigyUrl` (all auto-derived ports) |
| `vg-pagerduty-agent` | The app port, any source (shares it with kubelet's probes, no separate health port); Traefik (own `ingress.yaml`) | vg-console (in-cluster and via its own public hostname); its two helper Jobs are egress-only, the CronJob to vg-pagerduty-agent itself, the activate-remote Job to `centralConsoleUrl`/`centralAgentUrl` |
| `sbc-call-router` | The health and metrics ports only — **KNOWN GAP**: the app port's real caller could not be confirmed from the chart (see the values.yaml comment); add it to `extraIngress` before relying on this policy for production call routing | sbc-inbound, sbc-outbound, tracing |
| `vg-traffic-sniffer` | The http port, any source (shares it with `/healthz`) — **KNOWN GAP**: same as sbc-call-router, its real caller ("scaled up on demand (vg-console / flux edit)," per its own values.yaml comment) is an out-of-band operational action, not a wired chart-level call | Degrades gracefully like api-server below: Kubernetes API access only, so without `global.fedramp.networkPolicyKubernetesApiCidr` it stays ingress-only |

`vg-pagerduty-agent`'s Elasticsearch/PagerDuty/Anthropic/Grafana/Azure-DevOps egress
(`ELASTICSEARCH_API_KEY_*`, `PAGERDUTY_API_KEY`, `ANTHROPIC_API_KEY`,
`PROM_GRAFANA_API_URL_*`, `ADO_FLUX_FLEET_*`) is deliberately not covered — same
no-chart-known-CIDR class as `vg-console`'s `changelogEnrichment`, see below.

## Deferred to a later stage — and why

- **`api-server`'s and `vg-traffic-sniffer`'s own direct Kubernetes API access**
  (`templates/api-server/rbac-credential-secrets.yaml`'s `secrets` get/create/update/patch
  RBAC; `templates/vg-traffic-sniffer/rbac.yaml`'s `pods/exec` and
  `pods/ephemeralcontainers` RBAC), the `vg-cluster-signing-key-generator` hook Job, and
  `sbc-sip`'s STACKIT-only `stackit-external-ip-detector` init container all talk to the
  Kubernetes API server directly. `vg.networkPolicy.apiServerEgress` is built for this (an
  `ipBlock` egress rule gated by `global.fedramp.networkPolicyKubernetesApiCidr`): an
  environment has to supply the control-plane CIDR before this can be turned on safely, and
  that's a per-environment rollout step, not a chart default. Unlike the hook Job and the
  init container, `api-server` and `vg-traffic-sniffer` otherwise have real coverage worth
  keeping even without that CIDR, so both degrade gracefully instead of going uncovered
  entirely or failing the render: without the CIDR, each stays ingress-only (no `Egress`
  policyType, no `egress:` key at all — Kubernetes API access stays exactly as unrestricted
  as it would be with no policy); with the CIDR, the full Ingress+Egress policy applies.
- **`sbc-sip` and `sbc-rtp`** run `hostNetwork: true`. A `podSelector`-based `NetworkPolicy`
  cannot reliably govern ingress to a host-network pod — the SIP/RTP data plane bypasses the
  pod network namespace entirely. Writing a policy *for sbc-sip/sbc-rtp themselves* would be
  either inert or a false sense of security, and still needs its own design (likely
  host-level firewalling instead of `NetworkPolicy`), not a bolt-on to this stage. Being
  *called by* sbc-sip, though, is now solved everywhere it happens:
  `vg-resource-resolver` (stage 1, CGY-44772 #1156/#1200), and `telegraf`, `influxdb`,
  `heplify-server`, `sbc-inbound`, `sbc-outbound` (stage 2) all gained a
  `networkPolicy.ingressFromHostNetwork` field (a CIDR peer list, merged into the relevant
  port's rule) instead of trying to fold a host-network caller into a `podSelector` list;
  `vg-connector` calls *out* to sbc-sip/sbc-rtp instead, so it has the same mechanism on its
  egress side (`networkPolicy.egressToHostNetwork`). Every one of these is empty by default,
  so an environment still has to supply its node CIDR before the relevant calls pass once the
  policy is enforced; `templates/NOTES.txt` warns at render time for the
  `vg-resource-resolver` case specifically (`sbcSipSidecar.runtimeRegbots.enabled` true and
  `ingressFromHostNetwork` still empty), so that one doesn't surface only as a runtime 403.
- **`vg-pagerduty-agent` and `vg-console`** (when `changelogEnrichment.enabled`) have real
  external SaaS/LLM-vendor egress (Anthropic, PagerDuty, Elasticsearch, Grafana, GitHub,
  Azure OpenAI, AWS Bedrock) — `vg-console` also has an always-on `ADO_FLUX_FLEET_*`
  credential pair strongly suggesting direct Azure DevOps egress that the chart can't confirm
  a target for either. Both workloads are excluded from stage 2 entirely (not used in
  production deployments). `otel-collector`'s `extraOtlpExporters` (arbitrary external
  `host:port`, requires `redactionProcessor.enabled`) is the same class of problem on a
  workload stage 2 *does* otherwise cover — see the table above. All of these need either an
  enumerated CIDR list per vendor or an egress gateway/proxy — a bigger architectural call
  than either stage should make unilaterally.
- **`vg-realtime-bridge`** (on by default since CGY-48116) is not covered by
  `global.fedramp.networkPolicyEnabled`. Its egress is the vendor realtime APIs and the
  Cognigy callback host on 443, and the vendors publish no stable IPs, so the
  chart has no CIDR it could default to. The bridge has its own opt-in policy instead
  (`realtimeBridge.networkPolicy.enabled`), which fails the render until
  `realtimeBridge.networkPolicy.egress.allowedCidrs` is set (for example an egress proxy).
  Same no-chart-known-CIDR class as `vg-pagerduty-agent` above.
- **`feature-server`'s v2-api policy egress** (PR #1131 review): an earlier version of this
  PR added `Egress` here with allow rules for feature-server's in-cluster destinations
  (sbc-sip, sbc-rtp, api-server, etc.). Review caught that this was the wrong shape entirely:
  mainline feature-server's main job is calling destinations this chart cannot reduce to a
  CIDR or `podSelector` — STT/TTS speech vendors (Azure, Google, Deepgram, ElevenLabs, ...),
  the application's own `call_hook`/`status_hook` webhook URLs (arbitrary Cognigy.AI or
  customer HTTPS endpoints), and `AGENTIC_ENDPOINT_BASE_URL` (Cognigy.AI). Forcing a
  default-deny egress policy with allow rules for only the in-cluster destinations, under the
  FedRAMP profile, would break real call flow on any CNI that enforces egress policy, with no
  fix expressible as an `ipBlock`. It is also unlikely those in-cluster allow rules even
  covered `sbc-sip`/`sbc-rtp` in practice: both run `hostNetwork: true`, and most CNIs
  (Calico, Cilium) do not create matchable workload endpoints for host-network pods, or
  classify that traffic under a host/remote-node identity instead of the pod's own labels —
  so a `podSelector`-based egress "to" rule for them is likely a no-op, not an enforced
  allowance. Egress isolation here needs the same kind of decision as `vg-pagerduty-agent`/
  `vg-console` above (an enumerated CIDR list per vendor, or an egress gateway/proxy) plus a
  real node/SBC CIDR for the `hostNetwork` destinations (e.g. a
  `global.fedramp.networkPolicyNodeCidr` value) — not attempted in this stage. The policy
  stays ingress-only, exactly as it was before this PR.
- **`vg-console`, `vad-autotuner` and `test-harness`** are excluded from stage 2 entirely —
  not used in production deployments. `test-harness` in particular is ~10 mock sub-services
  (`templates/test-harness/*.yaml`) gated by `vgTestHarness.enabled` (`false` by default, "a
  production install byte-identical" per its own values.yaml comment) — CI/kind-only, never a
  real production attack surface.
- **RabbitMQ and MongoDB**, named in both tickets' generic watch-out text, do not exist
  anywhere in this chart (confirmed by a full-repo search) — that line is boilerplate from a
  shared finding template and doesn't apply here.
- **`keda`** (a bundled subchart) isn't used by any stage-1/stage-2 workload's own
  `NetworkPolicy`, so its native `networkPolicy.*` support is left untouched for now.
  (`postgresql`, listed here in stage 1 as also unused, turned out to be wrong — `homer` and
  `heplify-server` both depend on it; stage 2 added `vg.networkPolicy.postgresqlEgress` and
  both now have egress coverage for it.)

A note on the bundled `mysql`/`redisHa`/`postgresql` subcharts' own ingress: neither stage
adds an ingress-restricting `NetworkPolicy` on the MySQL/Redis/Postgres pods themselves (even
though all three Bitnami subcharts ship native `networkPolicy.enabled` support). Doing that
correctly requires an allow-list entry for every workload that may call them — exactly the
full-scope work these stages are staging out. Each covered workload's own egress rules let it
reach its data stores; the data stores' own ingress stays as open as it is today until a
later stage covers every caller.
