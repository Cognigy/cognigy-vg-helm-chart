{{/*
Default-deny NetworkPolicy, stage 1 (CSA-110265 / VHC-SC7-001, SC-7; CSA-110267 /
VHC-AC4-001, AC-4). Companion to templates/_fedramp.tpl — see docs/014-network-policy.md
for which workloads this stage covers, which are deliberately deferred, and why.

vg.fedramp.networkPolicyEnabled follows the same "FedRAMP forces, per-service override
ignored" shape as vg.fedramp.statsEnabled (templates/_fedramp.tpl:70-76): it reads through
`dig`, not `default`, so an explicit per-service `false` is never mistaken for "unset".
  - Profile on: global.fedramp.networkPolicyEnabled (true in values.yaml, and true if the
    key is missing). The per-service `networkPolicy.enabled` is ignored.
  - Profile off: the per-service `networkPolicy.enabled` (false by default — opt-in,
    unchanged from today).
Takes (dict "enabled" <per-service .Values.X.networkPolicy.enabled> "root" $).
*/}}
{{- define "vg.fedramp.networkPolicyEnabled" -}}
{{- $enabled := .enabled -}}
{{- if include "vg.fedramp.enabled" .root -}}
{{- $enabled = dig "fedramp" "networkPolicyEnabled" true .root.Values.global -}}
{{- end -}}
{{- if $enabled -}}true{{- end -}}
{{- end -}}

{{/*
DNS egress. Every default-deny-egress policy needs this or nothing resolves. Targets
CoreDNS by its standard kube-system label (k8s-app: kube-dns), applied by kubeadm, AKS,
EKS and kind alike. Takes no arguments; emits one `egress:` list entry — the caller
indents it under `egress:`.
*/}}
{{- define "vg.networkPolicy.dnsEgress" -}}
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
  ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
{{- end -}}

{{/*
MySQL egress. Allows traffic to the bundled mysql subchart's primary pod when it is
deployed in-cluster (.Values.mysql.enabled — the chart default). Renders nothing when
mysql is not bundled: an external MySQL has no in-cluster pod to select, and the chart
cannot resolve an external hostname to a CIDR at render time. An environment using an
external MySQL must add its own allow rule via the workload's `networkPolicy.egressTo`
list instead (see docs/014-network-policy.md).
Takes the root context $.
*/}}
{{- define "vg.networkPolicy.mysqlEgress" -}}
{{- if .Values.mysql.enabled -}}
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: mysql
          app.kubernetes.io/instance: {{ .Release.Name }}
          app.kubernetes.io/component: primary
  ports:
    - protocol: TCP
      port: 3306
{{- end -}}
{{- end -}}

{{/*
Redis egress. Allows traffic to whichever Redis is actually deployed: this chart's own
single-instance StatefulSet (default, selector `app: redis`) or the bundled Bitnami
redis-ha subchart when redisHa.enabled is true. Same "renders nothing for a fully
external Redis" rationale as vg.networkPolicy.mysqlEgress. For redis-ha, the pod label follows
redisHa.nameOverride and the ports follow the subchart's containerPorts (Redis, plus Sentinel,
which clients ask for the master first) — as #1196 first did for api-ban alone.
Takes the root context $.
*/}}
{{- define "vg.networkPolicy.redisEgress" -}}
{{- if .Values.redisHa.enabled -}}
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: {{ .Values.redisHa.nameOverride | default "redisHa" | quote }}
          app.kubernetes.io/instance: {{ .Release.Name | quote }}
  ports:
    - protocol: TCP
      port: {{ dig "replica" "containerPorts" "redis" 6379 .Values.redisHa | int }}
    - protocol: TCP
      port: {{ dig "sentinel" "containerPorts" "sentinel" 26379 .Values.redisHa | int }}
{{- else -}}
- to:
    - podSelector:
        matchLabels:
          app: redis
  ports:
    - protocol: TCP
      port: {{ .Values.redis.port }}
{{- end -}}
{{- end -}}

{{/*
InfluxDB egress. This chart's own single-instance Service, always rendered (no enabled
flag to gate on). Takes the root context $.
*/}}
{{- define "vg.networkPolicy.influxdbEgress" -}}
- to:
    - podSelector:
        matchLabels:
          app: influxdb
  ports:
    - protocol: TCP
      port: {{ .Values.influxdb.port }}
{{- end -}}

{{/*
PostgreSQL egress. Allows traffic to the bundled postgresql subchart's primary pod
(homer, heplify-server — both read additionalDbParameters.postgresql for host/port and
.Values.postgresql.auth for credentials). Same "renders nothing for a fully external
Postgres" rationale as vg.networkPolicy.mysqlEgress. Takes the root context $.
*/}}
{{- define "vg.networkPolicy.postgresqlEgress" -}}
{{- if .Values.postgresql.enabled -}}
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: postgresql
          app.kubernetes.io/instance: {{ .Release.Name }}
          app.kubernetes.io/component: primary
  ports:
    - protocol: TCP
      port: {{ .Values.additionalDbParameters.postgresql.port | default 5432 }}
{{- end -}}
{{- end -}}

{{/*
Egress to a list of external URLs with no chart-known host/CIDR (ported from
vg-resource-resolver's original runtimeApiTargets rule, CSA-109614/#1099): derives each
URL's port (explicit, or 443/80 by scheme) and allows it to namespaceSelector: {} plus
0.0.0.0/0 except 169.254.0.0/16 (link-local, the cloud instance-metadata endpoint). An
ipBlock is not guaranteed to match pod IPs, and the chart cannot resolve an arbitrary
hostname to a CIDR at render time, so this is deliberately broad on the destination
address and narrow only on the port. Takes (dict "urls" <list of URL strings, nil-safe>
"root" $). Renders nothing for an empty list.
*/}}
{{- define "vg.networkPolicy.externalUrlEgress" -}}
{{- $ports := list -}}
{{- range (.urls | default list) -}}
{{- if . -}}
{{- $u := urlParse . -}}
{{- $port := regexFind ":[0-9]+$" $u.host | trimPrefix ":" -}}
{{- if not $port -}}
{{- $port = ternary "443" "80" (eq (lower $u.scheme) "https") -}}
{{- end -}}
{{- $ports = append $ports ($port | int) -}}
{{- end -}}
{{- end -}}
{{- with $ports -}}
- to:
    - namespaceSelector: {}
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 169.254.0.0/16
  ports:
    {{- range (uniq .) }}
    - protocol: TCP
      port: {{ . }}
    {{- end }}
{{- end -}}
{{- end -}}

{{/*
Ingress from this chart's own Traefik (charts/traefik, the official chart, its pod
labelled app.kubernetes.io/name: traefik / app.kubernetes.io/instance: <see below>): the
real direct network peer for any workload whose own public traffic arrives through a
templates/<workload>/ingress.yaml or ingressroute.yaml — Traefik itself opens the
connection to the backend Service's pods, so from the workload pod's own point of view,
Traefik is the caller, not whatever client (in-cluster or external) originally asked for
the URL. When traefik.enabled is false, this chart's own Traefik isn't the one in front of
the install (see vg.fedramp.refuseInsecureTraefikEntrypoints, templates/_fedramp.tpl, for
the external-Traefik deviation path), so the rule admits networkPolicy.ingressControllerPeers
instead — the external controller's real network location, which the chart cannot know.
With that list empty the render fails while the workload's own ingress/ingressroute renders
(the "ingress" argument, that template's own gate): the policy would otherwise deny the
public port with nothing in the render saying so. With no ingress rendered there is no
public path to admit, so nothing renders and nothing is required.

app.kubernetes.io/instance is NOT simply the release name: this chart pins
traefik.instanceLabelOverride to "voicegateway" by default (values.yaml), so the bundled
Traefik chart's own labels use that fixed string regardless of what this release is
actually named — a selector built from $.Release.Name alone silently never matches it
(verified by rendering the Traefik subchart directly: instance label stayed "voicegateway"
under a different release name, and became "<release>-<namespace>" — not bare
$.Release.Name — once the override was cleared, the traefik chart's own fallback
convention). Read the override from .Values.traefik.instanceLabelOverride first, and only
fall back to that chart's own default shape if an environment ever clears it.

Takes (dict "port" <the workload's own ingress-facing port> "ingress" <whether that
workload's ingress/ingressroute renders> "root" $).
*/}}
{{- define "vg.networkPolicy.fromTraefik" -}}
{{- if .root.Values.traefik.enabled -}}
- from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: traefik
          app.kubernetes.io/instance: {{ .root.Values.traefik.instanceLabelOverride | default (printf "%s-%s" .root.Release.Name .root.Release.Namespace) }}
  ports:
    - protocol: TCP
      port: {{ .port }}
{{- else if .ingress -}}
{{- $peers := include "vg.networkPolicy.sharedPeers" (dict "key" "ingressControllerPeers" "root" .root) | fromYamlArray -}}
{{- if not $peers -}}
{{- fail "networkPolicy.ingressControllerPeers must be set while a workload's NetworkPolicy is on (global.fedramp.networkPolicyEnabled under the FedRAMP profile, or <workload>.networkPolicy.enabled) and traefik.enabled is false: the policy admits the workload's public port only from the ingress controller in front of this chart, and an external controller can only be selected by the peers you list there. See docs/014-network-policy.md." -}}
{{- end -}}
- from:
{{ toYaml $peers | indent 4 }}
  ports:
    - protocol: TCP
      port: {{ .port }}
{{- end -}}
{{- end -}}

{{/*
Peers for the nodes that sbc-sip and sbc-rtp run on. Both are hostNetwork: true in every
shape (sbc-rtp's StatefulSet as well as its DaemonSet), so their traffic leaves and arrives
with node addresses: no podSelector matches it, only an ipBlock does. Returns the
workload's own list followed by networkPolicy.hostNetworkPeers (the shared, per-environment
list) as YAML, or nothing when both are empty. Takes (dict "peers" <the workload's own
list, nil-safe> "root" $).
*/}}
{{- define "vg.networkPolicy.hostNetworkPeers" -}}
{{- with concat (.peers | default list) (include "vg.networkPolicy.sharedPeers" (dict "key" "hostNetworkPeers" "root" .root) | fromYamlArray) -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/*
One of the top-level networkPolicy lists (hostNetworkPeers, ingressControllerPeers) as YAML,
nil-safe for networkPolicy: null. Fails on a non-list value: a map would otherwise render
into a peer position and only be rejected by the API server at apply time. Takes (dict "key"
<list name> "root" $).
*/}}
{{- define "vg.networkPolicy.sharedPeers" -}}
{{- $v := get (.root.Values.networkPolicy | default dict) .key | default list -}}
{{- if not (kindIs "slice" $v) -}}
{{- fail (printf "networkPolicy.%s must be a list of NetworkPolicyPeer entries, got a %s. See docs/014-network-policy.md." .key (kindOf $v)) -}}
{{- end -}}
{{- toYaml $v -}}
{{- end -}}

{{/*
vg.networkPolicy.hostNetworkPeers for a workload that cannot serve a call without sbc-sip
or sbc-rtp reaching it (or it reaching them): fails the render when the result is empty,
rather than rendering a policy that blocks every call. Takes (dict "peers" <the workload's
own list> "field" <that list's values path, for the message> "root" $).
*/}}
{{- define "vg.networkPolicy.requiredHostNetworkPeers" -}}
{{- $peers := include "vg.networkPolicy.hostNetworkPeers" . -}}
{{- if not $peers -}}
{{- fail (printf "networkPolicy.hostNetworkPeers (or %s) must be set while this workload's NetworkPolicy is on (global.fedramp.networkPolicyEnabled under the FedRAMP profile, or its own networkPolicy.enabled): sbc-sip and sbc-rtp run hostNetwork: true, so only an ipBlock for their nodes can admit them, and without one every call is blocked. See docs/014-network-policy.md." .field) -}}
{{- end -}}
{{- $peers -}}
{{- end -}}

{{/*
Kubernetes API server egress — stage 2, not wired to any workload yet (api-server, the
vg-cluster-signing-key-generator hook Job, sbc-sip's STACKIT-only init container, and
vg-traffic-sniffer all need this; see docs/014-network-policy.md for why they're deferred).
Takes (dict "root" $ "needed" <bool>). When `needed` is true and the FedRAMP profile is on,
requires global.fedramp.networkPolicyKubernetesApiCidr and fails the render otherwise: the
control-plane endpoint differs by cloud (AKS/EKS/STACKIT) and cannot be discovered at
template time, so there is no safe default to fall back to.
*/}}
{{- define "vg.networkPolicy.apiServerEgress" -}}
{{- if and .needed (include "vg.fedramp.enabled" .root) -}}
{{- $cidr := dig "fedramp" "networkPolicyKubernetesApiCidr" "" .root.Values.global -}}
{{- if not $cidr -}}
{{- fail "global.fedramp.networkPolicyKubernetesApiCidr must be set while global.fedramp.enabled is true for a workload that needs direct Kubernetes API egress: the control-plane endpoint is environment-specific and cannot be discovered at render time. See docs/014-network-policy.md." -}}
{{- end -}}
- to:
    - ipBlock:
        cidr: {{ $cidr | quote }}
  ports:
    - protocol: TCP
      port: 443
{{- end -}}
{{- end -}}

{{/*
Warns, without failing the render, when vg-resource-resolver's NetworkPolicy is on and
sbc-sip's runtime-regbots sidecar is enabled (it calls the resolver by default, CGY-44772
#1156) but resourceResolver.networkPolicy.ingressFromHostNetwork is still empty: sbc-sip runs
hostNetwork: true, so no podSelector entry in ingressFrom can reach it (docs/014-network-policy.md,
"Deferred to a later stage") — ingressFromHostNetwork (a CIDR peer list, #1200) is the real
mechanism, but it ships empty, so an environment still has to supply its node CIDR. Takes the
root context $. Included from NOTES.txt (not a `fail`) because the gap already exists today
with the policy's default values — a render failure here would block every FedRAMP install
rather than just surfacing the gap.
*/}}
{{- define "vg.networkPolicy.sbcSipResolverWarning" -}}
{{- $npEnabled := include "vg.fedramp.networkPolicyEnabled" (dict "enabled" .Values.resourceResolver.networkPolicy.enabled "root" .) -}}
{{- $regbotsEnabled := include "vg.sbcSip.runtimeRegbots.enabled" . -}}
{{- if and $npEnabled $regbotsEnabled -}}
{{- if not (include "vg.networkPolicy.hostNetworkPeers" (dict "peers" .Values.resourceResolver.networkPolicy.ingressFromHostNetwork "root" .)) }}
WARNING: vg-resource-resolver's NetworkPolicy is on (global.fedramp.networkPolicyEnabled, or
resourceResolver.networkPolicy.enabled) and sbcSipSidecar.runtimeRegbots.enabled is true, but
neither networkPolicy.hostNetworkPeers nor resourceResolver.networkPolicy.ingressFromHostNetwork
is set. sbc-sip runs hostNetwork: true and cannot be allow-listed by podSelector, so its calls to
vg-resource-resolver will be blocked once this policy is enforced by the cluster's CNI. Set an
ipBlock entry for this environment's node CIDR in networkPolicy.hostNetworkPeers, or set
sbcSipSidecar.runtimeRegbots.enabled: false if this environment doesn't need runtime regbots.
{{- end -}}
{{- end -}}
{{- end -}}
