{{/*
Expand the name of the chart.
*/}}
{{- define "helm-chart-voicegateway-new.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "helm-chart-voicegateway-new.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "helm-chart-voicegateway-new.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "helm-chart-voicegateway-new.labels" -}}
helm.sh/chart: {{ include "helm-chart-voicegateway-new.chart" . }}
{{ include "helm-chart-voicegateway-new.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "helm-chart-voicegateway-new.selectorLabels" -}}
app.kubernetes.io/name: {{ include "helm-chart-voicegateway-new.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Renders a value that contains template.
Usage:
{{ include "vg.common.tplvalues.render" ( dict "value" .Values.path.to.the.Value "context" $) }}
*/}}
{{- define "vg.common.tplvalues.render" -}}
    {{- if typeIs "string" .value }}
        {{- tpl .value .context }}
    {{- else }}
        {{- tpl (.value | toYaml) .context }}
    {{- end }}
{{- end -}}

{{/*
Derive the vg-agentic-endpoint adapter's base URL for AGENTIC_ENDPOINT_BASE_URL.

Consumed by feature-server only, as a FALLBACK: vg-api-server now derives and
stores a per-application agentic_endpoint_hook from each application's own
call_hook at save time, so it needs no cluster-wide config here at all. This
value still matters for an agent-targeted application that predates that
column (has not been re-saved since) — .Values.agenticEndpoint feeds it.

agenticEndpoint.baseUrl is a HOST, not a full URL: an http(s):// override for
when the adapter is mounted somewhere other than the API host. Left empty (the
default), the host is DERIVED from cognigyLogin.baseUrl instead: that value
already names the Cognigy environment this VG cluster is paired with, and the
adapter is mounted on that same API host, so restating the host per
environment is only something to drift out of sync with the adapter's
ingress. Either way the scheme is normalized to ws(s):// and pathPrefix is
appended — callers never write the wss:// form themselves.

Returns "" when agenticEndpoint.enabled is false, or when BOTH
agenticEndpoint.baseUrl and cognigyLogin.baseUrl are empty; callers omit the
env var then, instead of failing the whole render. cognigyLogin.baseUrl alone
is set on every production cluster, so it can never be treated as "the adapter
is deployed": set agenticEndpoint.enabled=false on clusters whose paired
Cognigy environment does not run vg-agentic-endpoint, otherwise feature-server
reroutes agent calls to a path that does not exist there. Only an explicit
false disables it; an absent key keeps the default (true).

Usage:
{{ include "vg.agenticEndpoint.baseUrl" . }}
*/}}
{{- define "vg.agenticEndpoint.baseUrl" -}}
{{- $ae := .Values.agenticEndpoint -}}
{{- if ne (toString $ae.enabled) "false" -}}
{{- $host := $ae.baseUrl -}}
{{- if not $host -}}
{{- $host = .Values.cognigyLogin.baseUrl -}}
{{- end -}}
{{- if $host -}}
{{- printf "%s%s" (trimSuffix "/" (replace "https://" "wss://" (replace "http://" "ws://" $host))) $ae.pathPrefix -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the proper tls certificate Secret Name
*/}}
{{- define "vg.tlsCertificate.secretName.render" -}}
  {{- $tlsCertificateSecretName := "" -}}

  {{- if (.Values.tls.enabled) -}}
    {{- if .Values.tls.existingSecret -}}
      {{- $tlsCertificateSecretName = .Values.tls.existingSecret -}}
    {{- else if and (.Values.tls.crt) (.Values.tls.key) -}}
      {{- $tlsCertificateSecretName = "cognigy-traefik" -}}
    {{- else -}}
      {{ required "A valid value for .Values.tls is required!" .Values.tls.crt }}
      {{ required "A valid value for .Values.tls is required!" .Values.tls.key }}
      {{ required "A valid value for .Values.tls is required!" .Values.tls.existingSecret }}
    {{- end -}}
  {{- end -}}

  {{- if (not (empty $tlsCertificateSecretName)) -}}
tls:
  - secretName: {{- printf "%s" (tpl $tlsCertificateSecretName $) | indent 1 -}}
  {{- end -}}
{{- end -}}

{{/*
Return the proper interaction panel service provider info 
*/}}
{{- define "interactionPanelServiceProvider" -}}
  {{- $interactionPanelServiceProviderInfo := "" -}}

  {{- if .Values.testCallManager.enabled -}}
    {{- if .Values.testCallManager.interactionPanelServiceProvider.existingCredentials -}}
      {{- $interactionPanelServiceProviderInfo = .Values.testCallManager.interactionPanelServiceProvider.existingCredentials -}}
    {{- else if and (.Values.testCallManager.interactionPanelServiceProvider.id) (.Values.testCallManager.interactionPanelServiceProvider.apiKey) (.Values.testCallManager.interactionPanelServiceProvider.adminApiKey) -}}
      {{- $interactionPanelServiceProviderInfo = "voicegateway-interaction-panel-service-provider" -}}
    {{- else -}}
      {{ required "A valid value for .Values.testCallManager.interactionPanelServiceProvider.id is required!" .Values.testCallManager.interactionPanelServiceProvider.id }}
      {{ required "A valid value for .Values.testCallManager.interactionPanelServiceProvider.apiKey is required!" .Values.testCallManager.interactionPanelServiceProvider.apiKey }}
      {{ required "A valid value for .Values.testCallManager.interactionPanelServiceProvider.adminApiKey is required!" .Values.testCallManager.interactionPanelServiceProvider.adminApiKey }}
      {{ required "A valid value for .Values.testCallManager.interactionPanelServiceProvider.existingCredentials is required!" .Values.testCallManager.interactionPanelServiceProvider.existingCredentials }}
    {{- end -}}
  {{- end -}}

  {{- if (not (empty $interactionPanelServiceProviderInfo)) -}}
    {{- printf "%s" (tpl $interactionPanelServiceProviderInfo $) | indent 1 -}}
  {{- end -}}
{{- end -}}

{{/*
Return the proper Azure SIP DNS updater credentials
*/}}
{{- define "sipDnsUpdaterAzure" -}}
  {{- $sipDnsUpdaterAzureInfo := "" -}}

  {{- if .Values.sbc.sipDnsUpdaterAzure.enabled -}}
    {{- if .Values.sbc.sipDnsUpdaterAzure.servicePrincipal.existingSecret -}}
      {{- $sipDnsUpdaterAzureInfo = .Values.sbc.sipDnsUpdaterAzure.servicePrincipal.existingSecret  -}}
    {{- else if and (.Values.sbc.sipDnsUpdaterAzure.servicePrincipal.tenantId) (.Values.sbc.sipDnsUpdaterAzure.servicePrincipal.appId) (.Values.sbc.sipDnsUpdaterAzure.servicePrincipal.appPassword) -}}
      {{- $sipDnsUpdaterAzureInfo = "sip-dns-updater-azure" -}}
    {{- else -}}
      {{ required "A valid value for .Values.sbc.sipDnsUpdaterAzure.servicePrincipal.tenantId is required!" .Values.sbc.sipDnsUpdaterAzure.servicePrincipal.tenantId }}
      {{ required "A valid value for .Values.sbc.sipDnsUpdaterAzure.servicePrincipal.appId is required!" .Values.sbc.sipDnsUpdaterAzure.servicePrincipal.appId }}
      {{ required "A valid value for .Values.sbc.sipDnsUpdaterAzure.servicePrincipal.appPassword is required!" .Values.sbc.sipDnsUpdaterAzure.servicePrincipal.appPassword }}
    {{- end -}}
  {{- end -}}

  {{- if (not (empty $sipDnsUpdaterAzureInfo)) -}}
    {{- printf "%s" (tpl $sipDnsUpdaterAzureInfo $) | indent 1 -}}
  {{- end -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Auth Credentials
*/}}
{{- define "image.pullSecrets" -}}
  {{- $pullSecrets := list -}}

  {{- if and (.Values.imageCredentials.registry) (.Values.imageCredentials.username) (.Values.imageCredentials.password) -}}
      {{- $pullSecrets = append $pullSecrets "cognigy-registry-token" -}}
  {{- else if .Values.imageCredentials.pullSecrets -}}
    {{- range .Values.imageCredentials.pullSecrets -}}
      {{- $pullSecrets = append $pullSecrets . -}}
    {{- end -}}
  {{- else -}}
    {{ required "A valid value for .Values.imageCredentials is required!" .Values.imageCredentials.registry }}
    {{ required "A valid value for .Values.imageCredentials is required!" .Values.imageCredentials.username }}
    {{ required "A valid value for .Values.imageCredentials is required!" .Values.imageCredentials.password }}
    {{ required "A valid value for .Values.imageCredentials is required!" .Values.imageCredentials.pullSecrets }}
  {{- end -}}

  {{- if (not (empty $pullSecrets)) -}}
imagePullSecrets:
    {{- range $pullSecrets }}
  - name: {{ . }}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- define "imagePullSecret" }}
{{- with .Values.imageCredentials }}
{{- printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"auth\":\"%s\"}}}" .registry .username .password (printf "%s:%s" .username .password | b64enc) | b64enc }}
{{- end }}
{{- end }}

{{/*
Render the FreeSWITCH pod's opt-in region-DNS dnsPolicy/dnsConfig block used
for the Deepgram region-routing regression test, or fail loudly if
freeswitch.regionDnsEnabled is set without the matching vgTestHarness region
DNS resolver. Shared by the feature-server workload, workload-nightly, and
stateful-set-legacy templates so the three stay in lockstep.
Usage: {{- include "vg.freeswitch.regionDnsConfig" $ | nindent 6 }}
*/}}
{{- define "vg.freeswitch.regionDnsConfig" -}}
{{- if and .Values.freeswitch.regionDnsEnabled (not (include "vg.testHarness.testDnsEnabled" .)) }}{{ fail "freeswitch.regionDnsEnabled requires vgTestHarness.enabled=true and either vgTestHarness.regionDns.enabled=true or vgTestHarness.speechInterception=vendor (otherwise the FreeSWITCH pod's dnsConfig points at a Service that doesn't exist)" }}{{- end }}
{{- if or .Values.freeswitch.regionDnsEnabled (include "vg.testHarness.vendorRoute" .) }}
dnsPolicy: None
dnsConfig:
  nameservers:
    - {{ include "vg.testHarness.testDnsClusterIP" . }}
  searches:
    - {{ printf "%s.svc.cluster.local" .Release.Namespace }}
    - svc.cluster.local
    - cluster.local
{{- end }}
{{- end -}}

{{/*
Render the FreeSWITCH "--log-level <level>" argument pair from freeswitch.logLevel
so the chart's log-level default survives a freeswitch.args override. Helm replaces
lists wholesale, so a user overriding freeswitch.args (e.g. to add a codec flag)
used to silently drop the "--log-level info" entry that used to live in that list
and fall back to the FreeSWITCH binary's own default (notice).

Skipped when freeswitch.args already carries an explicit --log-level (either
"--log-level", "level" as two entries or "--log-level=level" as one), so an
in-args level still wins and no duplicate flag is emitted.

Deliberately does NOT inherit global.logLevel: FreeSWITCH names its levels
syslog-style (disable, console, alert, crit, err, warning, notice, info, debug —
see switch_log.c's LEVELS[]), so the other components' "error"/"warn"/"trace"
values are not valid here and must not leak in. An unrecognised level is silently
ignored by FreeSWITCH, which would leave the image default of notice in place —
exactly the failure this helper exists to prevent. Set freeswitch.logLevel.
Shared by the feature-server workload, workload-nightly, and stateful-set-legacy
templates so the three stay in lockstep. Included AFTER the freeswitch.args range
so that with default values the rendered flag order matches the pre-helper chart
(…--codec-answer-generous, --log-level, info) and upgrading does not restate the
pod's args array — i.e. no needless feature-server rollout.

The `with` wrapper is required: the helper renders empty when an in-args level
already won, and a bare `include … | nindent` would leave a blank list entry.
Usage: {{- with (include "vg.freeswitch.logLevelArgs" $) }}{{- . | nindent 12 }}{{- end }}
*/}}
{{- define "vg.freeswitch.logLevelArgs" -}}
{{- $explicit := false -}}
{{- range .Values.freeswitch.args }}
{{- $arg := toString . }}
{{- if or (eq $arg "--log-level") (hasPrefix "--log-level=" $arg) }}{{- $explicit = true -}}{{- end }}
{{- end }}
{{- if not $explicit -}}
- --log-level
- {{ .Values.freeswitch.logLevel | default "info" | quote }}
{{- end }}
{{- end -}}

{{/*
Return the proper Secret Name
Usage:
{{ include "common.secretName.render" ( dict "existingSecret" .Values.path.to.existingSecret "defaultSecret" "default-secret-name") }}
*/}}
{{- define "common.secretName.render" -}}
  {{- if .existingSecret -}}
    {{- printf "%s" .existingSecret -}}
  {{- else -}}
    {{- printf "%s" .defaultSecret -}}
  {{- end -}}
{{- end }}

{{/*
The FreeSWITCH container's env on the vendor-hostname route.

mod_google_transcribe builds grpc::SslCredentials with no explicit
pem_root_certs, which uses gRPC's OWN bundled roots and ignores the hashed CA
directory the overlay installs at /etc/ssl/certs. This variable is the only
thing that points it at the mock's CA.

This helper used to carry TESTING_OVERRIDE_{TTS,STT}_URL as well -- a FreeSWITCH
build-time hook that clobbers every STT vendor's resolved host with mock-speech.
It was removed because nothing could use it: it is #ifdef'd out of release
builds, and both namespaces that enabled the harness set
freeswitch.regionDnsEnabled, which suppressed it anyway. Its only visible effect
was the NOTES.txt warning that speech "will still hit REAL providers", which was
a false alarm on every kind gate run. Redirect a vendor-native module with
speechInterception: vendor, or a custom:<name> credential, both of which work on
the production image.
*/}}
{{- define "vg.testHarness.freeswitchEnv" -}}
{{- if include "vg.testHarness.vendorRoute" . }}
- name: GRPC_DEFAULT_SSL_ROOTS_FILE_PATH
  value: /ca-overlay/mock-cas.pem
{{- end }}
{{- end -}}

{{- /*
The mock-cognigy call-hook URL, shared by the provision Job (which writes it
onto every application it creates) and the number manifest's defaults, so the
two cannot disagree about where calls are sent.

FQDN, not the bare service name: api-server validates hook URLs with
dns.resolve4, which does not consult the search domains in resolv.conf.
ws://, not http://: the scheme is what selects the feature-server's requestor,
and production uses the WebSocket one. Both are explained at length in
templates/test-harness/provision-job.yaml.
*/}}
{{- define "vg.testHarness.webhookUrl" -}}
{{- .Values.vgTestHarness.autoProvision.webhookUrl | default (printf "ws://mock-cognigy.%s.svc.cluster.local:8080/voiceGateway" .Release.Namespace) -}}
{{- end -}}

{{/*
RTP traffic gate: validate .Values.sbc.rtp.trafficGate.drainAddresses and emit it as a
comma-separated scalar.

DENY-LIST semantics: a pod serves RTP unless its own Elastic IP appears here.
Unset/empty therefore means "everything serves" — identical to the behaviour of
every release before this key existed — and adding capacity needs no entry here
at all.

Two properties this helper must preserve:

  1. It MUST emit a scalar, not a YAML sequence. reloadable-config's
     parseYamlFile uses the failsafe schema and skips non-scalar values with only
     a warn log, so a sequence would be silently dropped and every sbc-rtp pod
     would fail closed.

  2. The key is ALWAYS rendered, empty when nothing is drained. That is what lets
     the sidecar treat an ABSENT key as "the mounted file is missing or wrong"
     and fail closed, while an EMPTY value means "explicitly nothing drained".
     Never make the key itself conditional.
*/}}
{{- define "vg.sbcRtp.drainAddresses" -}}
{{- $addresses := .Values.sbc.rtp.trafficGate.drainAddresses | default list -}}
{{- if not (kindIs "slice" $addresses) -}}
{{- fail (printf "sbc.rtp.trafficGate.drainAddresses must be a list of IPv4 address strings, got %s" (kindOf $addresses)) -}}
{{- end -}}
{{- if and (gt (len $addresses) 0) (ne .Values.cloud "aws") -}}
{{- fail (printf "sbc.rtp.trafficGate.drainAddresses is only supported on cloud=aws, because the gate compares against the EC2 IMDS public-ipv4 of the pod's associated Elastic IP. cloud is %q." .Values.cloud) -}}
{{- end -}}
{{- if hasKey (.Values.cognigyEnv | default dict) "SBC_RTP_DRAIN_ADDRESSES" -}}
{{- fail "SBC_RTP_DRAIN_ADDRESSES must not be set in cognigyEnv. reloadable-config snapshots process.env at init and that snapshot beats every mounted file, so an env copy would freeze the gate at its boot value and break graceful drain. Use sbc.rtp.trafficGate.drainAddresses only." -}}
{{- end -}}
{{- range $addresses -}}
{{- if not (regexMatch "^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$" (toString .)) -}}
{{- fail (printf "sbc.rtp.trafficGate.drainAddresses entry %q is not a valid IPv4 address" (toString .)) -}}
{{- end -}}
{{- end -}}
{{- join "," $addresses -}}
{{- end -}}

{{/*
RTP traffic gate: fail if the readiness port collides with health or metrics.

All three probes are served by the same rtp-engine-sidecar container. A
collision means the readiness listener never binds — the sidecar answers the
probe with whichever service already owns the port (e.g. metrics' 404) — and
the pod never becomes Ready. Since the gate is always wired when enabled (see
traffic-gate-configmap.yaml), that isn't a transient failure an operator can
roll back out of; it wedges the StatefulSet rollout permanently.
*/}}
{{- define "vg.sbcRtp.trafficGate.validatePort" -}}
{{- $readiness := toString .Values.rtpEngineSidecar.ports.readiness -}}
{{- if eq $readiness (toString .Values.health.port) -}}
{{- fail (printf "rtpEngineSidecar.ports.readiness (%s) must not equal health.port (%v)" $readiness .Values.health.port) -}}
{{- end -}}
{{- if eq $readiness (toString .Values.metrics.port) -}}
{{- fail (printf "rtpEngineSidecar.ports.readiness (%s) must not equal metrics.port (%v)" $readiness .Values.metrics.port) -}}
{{- end -}}
{{- end -}}

{{/*
Whether drachtio gets --cloud-deployment. Non-empty means yes.

Shared by sbc-sip's stateful-set.yaml and daemon-set.yaml so the two cannot
drift; both render drachtio and both need the same answer.

An ALLOW-LIST of the clouds that actually answer on the metadata service at
169.254.169.254, not a deny-list. The flag makes drachtio resolve its advertised
address from that service; where nothing answers, the host comes back empty and
drachtio dies at startup with

  SipTransport::init - contact: sip::5060;transport=udp,tcp
  Uncaught exception: SipTransport::init - invalid contact

taking sbc-sip-sidecar with it (ECONNREFUSED 127.0.0.1:9022). The previous
condition — anything non-empty except "stackit" — turned every unrecognised
value into that crash: "openstack", "onprem", or a mere typo like "AWS". Nothing
else in the chart validates .Values.cloud, so a typo has no other backstop.

Comparison is case-sensitive on purpose, matching how the rest of the chart
reads this key (see vg.sbcRtp.drainAddresses, which tests `eq .Values.cloud
"aws"`). "AWS" therefore omits the flag rather than enabling it — the
recoverable direction, since drachtio then derives its own contact and
sbc.sip.contact can pin one explicitly.
*/}}
{{- define "vg.sbc.sip.useCloudDeployment" -}}
{{- if has .Values.cloud (list "aws" "azure" "gcp") }}true{{ end }}
{{- end -}}

{{/*
Whether the sbc-rtp RTP traffic gate is actually wired. Non-empty means yes.

Shared by stateful-set.yaml, daemon-set.yaml and traffic-gate-configmap.yaml so
the probe, the ConfigMap and the mount cannot disagree — a probe without its
ConfigMap is exactly the fail-closed-forever state the gate must never enter.

The gate is AWS-ONLY BY CONSTRUCTION: it decides whether a pod serves by
comparing that pod's address against the drain list, and it reads the address
from the EC2 instance metadata service at 169.254.169.254. Nothing answers there
off AWS, so off AWS the gate can never pass.

The chart already enforced that for the drain LIST — vg.sbcRtp.drainAddresses
hard-fails unless cloud is "aws" — but not for the PROBE, which rendered for
every cloud including unset, while enabled defaulted to true. So EVERY install
mounted a gate, and off AWS it could never pass: sbc-rtp stayed at 1/2
containers forever with

  Readiness probe failed: Get "http://<ip>:8003/health/ready":
  dial tcp <ip>:8003: connect: connection refused

The condition is now simply "explicitly enabled", which works because
trafficGate.enabled DEFAULTS TO FALSE. Helm cannot distinguish a value the
operator set from the chart's own default — both read as true — so an opt-out
default of true left no way to say "on here, off there". Flipping the default is
what makes `enabled: true` mean something.

Why not also test cloud=aws here: the gate is AWS-only in PRODUCTION because of
IMDS, but whether /health/ready actually REQUIRES IMDS when nothing is drained
is unverified — a pod that serves unless its address is listed may not need to
know its address at all while the list is empty. ci/kind/values-kind.yaml turns
the gate on off-AWS with a sidecar build that serves the endpoint precisely to
answer that empirically. If the probe cannot pass without IMDS, add the cloud
test back here; if it can, this feature is testable outside AWS and that is
worth knowing. drainAddresses keeps its own hard cloud=aws guard either way, so
nobody can DRAIN off AWS regardless of what this predicate allows.

Serving /health/ready is vg-sbc-rtpengine-sidecar#23, still open, so no RELEASED
sidecar image answers on the readiness port. Turning this on requires an image
that does — see rtpEngineSidecar.image.
*/}}
{{- define "vg.sbcRtp.trafficGate.wired" -}}
{{- if .Values.sbc.rtp.trafficGate.enabled }}true{{ end }}
{{- end -}}

{{/*
vgTestHarness.speechInterception: none (default) redirects nothing -- a
custom:<name> credential still reaches mock-speech by the URL on the credential.
vendor makes VG dial the real vendor hostnames and rewrites them, in-namespace,
to mock-speech's TLS listener, deriving regionDns, mockSpeech.tls, the FreeSWITCH
and api-server dnsConfig and the CA-trust overlay from this one value.

Returns "none" whenever the harness is disabled, so callers need not also test
vgTestHarness.enabled -- and nothing below can render in a production install.
*/}}
{{- define "vg.testHarness.speechMode" -}}
{{- if not .Values.vgTestHarness.enabled -}}
none
{{- else -}}
{{- /* "none", never "off": YAML 1.1 reads a bare off as the boolean false. */ -}}
{{- $mode := .Values.vgTestHarness.speechInterception | default "none" -}}
{{- if not (has $mode (list "none" "vendor")) }}{{ fail (printf "vgTestHarness.speechInterception must be none or vendor, got %v" $mode) }}{{- end -}}
{{- $mode -}}
{{- end -}}
{{- end -}}

{{- define "vg.testHarness.vendorRoute" -}}
{{- if eq (include "vg.testHarness.speechMode" .) "vendor" }}true{{ end }}
{{- end -}}

{{/* regionDns.enabled still turns test-dns on by itself, for the region suite. */}}
{{- define "vg.testHarness.testDnsEnabled" -}}
{{- if and .Values.vgTestHarness.enabled (or .Values.vgTestHarness.regionDns.enabled (include "vg.testHarness.vendorRoute" .)) }}true{{ end }}
{{- end -}}

{{/* mockSpeech.tls.enabled stays honoured alone, for installs predating the flag. */}}
{{- define "vg.testHarness.mockSpeechTls" -}}
{{- if and .Values.vgTestHarness.enabled (or (dig "tls" "enabled" false .Values.vgTestHarness.mockSpeech) (include "vg.testHarness.vendorRoute" .)) }}true{{ end }}
{{- end -}}

{{/*
The vendor hostnames the vendor route rewrites. In the chart, not in each
caller's values, because a vendor added on one side and not the other is a call
that quietly reaches the real paid provider. regionDns.rewrites is APPENDED to
this, never replaces it.

Azure is a regex because the JS Speech SDK derives the hostname from the
credential's region: an exact list silently misses any region nobody added.
*/}}
{{- define "vg.testHarness.vendorRewrites" -}}
- name: api.deepgram.com
  target: mock-speech
- name: api.eu.deepgram.com
  target: mock-speech
- name: api.elevenlabs.io
  target: mock-speech
- name: speech.googleapis.com
  target: mock-speech
- name: texttospeech.googleapis.com
  target: mock-speech
- name: '(.*)\.tts\.speech\.microsoft\.com'
  type: regex
  target: mock-speech
- name: '(.*)\.stt\.speech\.microsoft\.com'
  type: regex
  target: mock-speech
{{- end -}}

{{- define "vg.testHarness.mintCerts" -}}
{{- if and (include "vg.testHarness.vendorRoute" .) (dig "tls" "generate" true .Values.vgTestHarness.mockSpeech) }}true{{ end }}
{{- end -}}

{{- define "vg.testHarness.caConfigMapName" -}}
{{- dig "tls" "caConfigMapName" "mock-speech-ca" .Values.vgTestHarness.mockSpeech -}}
{{- end -}}

{{/*
SANs for the minted leaf, derived from the same rewrite list that routes the
traffic -- a hostname routed here but missing from the cert fails the handshake,
and two hand-maintained lists is how that happens. A regex rewrite becomes a TLS
wildcard; both match exactly one label. mock-speech's own names are included
because AWS Polly and the credential-field vendors dial the Service directly.
*/}}
{{- define "vg.testHarness.certSans" -}}
- mock-speech
- mock-speech.{{ .Release.Namespace }}.svc
- mock-speech.{{ .Release.Namespace }}.svc.cluster.local
{{- $rewrites := concat (include "vg.testHarness.vendorRewrites" . | fromYamlArray) .Values.vgTestHarness.regionDns.rewrites }}
{{- range $r := $rewrites }}
{{- if eq ($r.type | default "exact") "regex" }}
{{- /*
  Only a LEFTMOST (.*) translates exactly. A TLS wildcard must be the first
  label and match exactly one, so foo\.(.*)\.example\.com would yield the
  invalid SAN foo.*.example.com and every handshake against it would fail
  hostname verification -- which reads as a routing bug, not a certificate one.
*/}}
{{- if not (hasPrefix "(.*)\\." $r.name) }}{{ fail (printf "vgTestHarness.regionDns.rewrites: regex %q cannot be turned into a TLS SAN. Only a leftmost (.*) wildcard is supported, because a TLS wildcard must be the first label and match exactly one label." $r.name) }}{{- end }}
- {{ $r.name | replace "(.*)" "*" | replace "\\." "." | quote }}
{{- else }}
- {{ $r.name | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The CA-trust overlay for the feature-server pod. Trust is four stores that share
no mechanism -- libwebsockets reads a hashed DIRECTORY, libcurl a bundle FILE,
gRPC only GRPC_DEFAULT_SSL_ROOTS_FILE_PATH, Node only NODE_EXTRA_CA_CERTS -- so
one emptyDir carries the system roots, the CA appended to the bundle, the CA as
its own PEM, and a rehash. Mounting a ConfigMap over /etc/ssl/certs instead would
hide the system roots the same clients need for everything else.

The freeswitch image, not a bare debian: this pod has dnsPolicy None and no route
off the cluster, so an apt-get here hangs on connect and the pod never leaves
Init with nothing saying why.
*/}}
{{- define "vg.testHarness.caInitContainer" -}}
{{- if include "vg.testHarness.vendorRoute" . }}
- name: mock-speech-ca-overlay
  image: {{ include "vg.common.image.render" (dict "global" .Values.global "image" .Values.freeswitch.image) }}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      cp -aL /etc/ssl/certs/. /ca-overlay/
      cp /mock-ca/ca.pem /ca-overlay/mock-cas.pem
      cat /ca-overlay/mock-cas.pem >> /ca-overlay/ca-certificates.crt
      (command -v c_rehash >/dev/null && c_rehash /ca-overlay) \
        || (command -v openssl >/dev/null && openssl rehash /ca-overlay) \
        || { echo "no c_rehash/openssl rehash in this freeswitch image - libwebsockets needs the hashed dir, not just the bundle" >&2; exit 1; }
  volumeMounts:
    - name: mock-speech-ca
      mountPath: /mock-ca
      readOnly: true
    - name: mock-speech-ca-overlay
      mountPath: /ca-overlay
{{- end }}
{{- end -}}

{{- define "vg.testHarness.caVolumes" -}}
{{- if include "vg.testHarness.vendorRoute" . }}
- name: mock-speech-ca
  configMap:
    name: {{ include "vg.testHarness.caConfigMapName" . }}
- name: mock-speech-ca-overlay
  emptyDir: {}
{{- end }}
{{- end -}}

{{/*
Usage: {{- include "vg.testHarness.caVolumeMount" (dict "ctx" $ "mountPath" "/ca-overlay") }}
freeswitch mounts the overlay at both /etc/ssl/certs (libwebsockets reads the
hashed dir there and nowhere else) and /ca-overlay, so the roots path is one
string in every container.
*/}}
{{- define "vg.testHarness.caVolumeMount" -}}
{{- if include "vg.testHarness.vendorRoute" .ctx }}
- name: mock-speech-ca-overlay
  mountPath: {{ .mountPath }}
  readOnly: true
{{- end }}
{{- end -}}

{{/*
@grpc/grpc-js, the client behind Google TTS, does not read NODE_EXTRA_CA_CERTS.
AWS_ENDPOINT_URL_POLLY is the only thing that redirects Polly -- vg-speech-utils
never sets an endpoint on PollyClient, so no rewrite or credential field reaches
it. :443, not :8443: the Service publishes 443 -> targetPort 8443, and Polly
fails soft (a tone), so the wrong port looks like a healthy call.
*/}}
{{- define "vg.testHarness.featureServerEnv" -}}
{{- if include "vg.testHarness.vendorRoute" . }}
- name: NODE_EXTRA_CA_CERTS
  value: /ca-overlay/mock-cas.pem
- name: GRPC_DEFAULT_SSL_ROOTS_FILE_PATH
  value: /ca-overlay/mock-cas.pem
- name: AWS_ENDPOINT_URL_POLLY
  value: "https://mock-speech:443"
{{- end }}
{{- end -}}

{{/*
api-server's half, needed only for Google: feature-server refuses a Google
credential until tts_tested_ok/stt_tested_ok are set, and only api-server's own
credential-test route sets them -- so it must reach mock-speech itself. No CA
overlay here: api-server is Node only, and both stores it uses take a plain file.
*/}}
{{- define "vg.testHarness.apiServerEnv" -}}
{{- if include "vg.testHarness.vendorRoute" . }}
- name: NODE_EXTRA_CA_CERTS
  value: /mock-ca/ca.pem
- name: GRPC_DEFAULT_SSL_ROOTS_FILE_PATH
  value: /mock-ca/ca.pem
{{- end }}
{{- end -}}

{{- define "vg.testHarness.apiServerCaMount" -}}
{{- if include "vg.testHarness.vendorRoute" . }}
- name: mock-speech-ca
  mountPath: /mock-ca
  readOnly: true
{{- end }}
{{- end -}}

{{- define "vg.testHarness.apiServerCaVolume" -}}
{{- if include "vg.testHarness.vendorRoute" . }}
- name: mock-speech-ca
  configMap:
    name: {{ include "vg.testHarness.caConfigMapName" . }}
{{- end }}
{{- end -}}

{{- define "vg.testHarness.apiServerDnsConfig" -}}
{{- if include "vg.testHarness.vendorRoute" . }}
dnsPolicy: None
dnsConfig:
  nameservers:
    - {{ include "vg.testHarness.testDnsClusterIP" . }}
  searches:
    - {{ printf "%s.svc.cluster.local" .Release.Namespace }}
    - svc.cluster.local
    - cluster.local
{{- end }}
{{- end -}}

{{/*
clusterIP if given, else the namespace's slot within clusterIPBase, else within
kube-dns's own /24 -- so the usual case configures no address at all.

Helm can read kube-dns but cannot list what is allocated, so the result is a
STABLE address, not a verified-free one: a collision means the API server
rejects the second Service, which is a failed install rather than traffic going
somewhere surprising. Range .20-.250 avoids the reserved and conventional
addresses at either end.

231 buckets, so this is a birthday problem and not a guarantee: roughly a 19%
chance of a collision across 10 harness-enabled namespaces on one cluster, 50%
across 18. Past a handful, pin regionDns.clusterIP per namespace.
*/}}
{{- define "vg.testHarness.testDnsClusterIP" -}}
{{- $rd := .Values.vgTestHarness.regionDns -}}
{{- if $rd.clusterIP -}}
{{- $rd.clusterIP -}}
{{- else -}}
{{- $base := dig "clusterIPBase" "" $rd -}}
{{- if not $base -}}
{{- /* kube-dns sits in the low band of the Service CIDR, which Kubernetes holds
       back for pinned addresses and never allocates from dynamically -- so its
       own /24 is the emptiest part of the range, and the best default base. */ -}}
{{- $kubeDns := lookup "v1" "Service" "kube-system" "kube-dns" -}}
{{- if and $kubeDns $kubeDns.spec (regexMatch "^[0-9]+(\\.[0-9]+){3}$" (default "" $kubeDns.spec.clusterIP)) -}}
{{- $base = regexReplaceAll "\\.[0-9]+$" $kubeDns.spec.clusterIP "" -}}
{{- end -}}
{{- end -}}
{{- if not $base -}}
{{- fail "test-dns needs an address. The chart derives one from kube-system/kube-dns, but could not read that Service -- a client-side render (helm template) or a reconciler without get on Services in kube-system. Set vgTestHarness.regionDns.clusterIPBase (e.g. \"172.20.0\") to derive the last octet from the namespace, or vgTestHarness.regionDns.clusterIP to pin the whole address." -}}
{{- end -}}
{{- printf "%s.%d" $base (add 20 (mod (atoi (adler32sum .Release.Namespace)) 231)) -}}
{{- end -}}
{{- end -}}

{{/*
Checksum of the CA the pods should be trusting, as a pod annotation, so a CA
that genuinely changes rolls the workloads that baked it into a trust store.

Without this a rotation is invisible: the feature-server's init container builds
/ca-overlay once at pod start, and api-server reads NODE_EXTRA_CA_CERTS once at
process start, so both keep trusting the previous CA indefinitely while
mock-speech serves a leaf signed by the new one -- an opaque handshake failure
with nothing in `helm diff` to explain it.

Read from the live Secret rather than from the freshly minted value on purpose:
genCA is random, so checksumming what this render produced would change the
annotation on EVERY reconcile and roll the pods forever. The live Secret is
stable, which makes this annotation stable too. The cost is one extra rollout on
the reconcile after a first install, when the Secret appears and the annotation
goes from absent to set.
*/}}
{{- define "vg.testHarness.caChecksum" -}}
{{- if include "vg.testHarness.vendorRoute" . }}
{{- $secretName := dig "tls" "secretName" "mock-speech-tls" .Values.vgTestHarness.mockSpeech }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if and $existing $existing.data (index $existing.data "ca.crt") }}
checksum/mock-speech-ca: {{ index $existing.data "ca.crt" | sha256sum }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Core dumps for the rtp-engine container.

Off by default: dumps are large, and the image only produces useful ones when it
is built unstripped (Cognigy/vg-rtpengine ships debug symbols and `gdb`).

`type: emptyDir` is the safe default. rtpengine crashing restarts the CONTAINER,
not the pod, so an emptyDir still holds the dump when you exec in afterwards; it
is lost only when the pod itself goes away. `type: hostPath` survives that, at
the cost of writing to the node and having to clean up after yourself.

`privileged` exists because /proc/sys/kernel/core_pattern is a node-wide kernel
setting -- the entrypoint can only point dumps at `path` from a privileged
container. Left false, dumps still happen, they just follow whatever pattern the
node has (often systemd-coredump on the host, outside the pod).
*/}}
{{- define "vg.rtpEngine.coreDumps.enabled" -}}
{{- if .Values.rtpEngine.coreDumps.enabled }}true{{ end }}
{{- end -}}

{{- define "vg.rtpEngine.coreDumps.volumeMount" -}}
- name: core-dumps
  mountPath: {{ .Values.rtpEngine.coreDumps.path }}
{{- end -}}

{{- define "vg.rtpEngine.coreDumps.volume" -}}
- name: core-dumps
{{- if eq .Values.rtpEngine.coreDumps.type "hostPath" }}
  hostPath:
    path: {{ .Values.rtpEngine.coreDumps.hostPath }}
    type: DirectoryOrCreate
{{- else if eq .Values.rtpEngine.coreDumps.type "emptyDir" }}
  emptyDir:
    sizeLimit: {{ .Values.rtpEngine.coreDumps.sizeLimit }}
{{- else }}
{{- fail (printf "rtpEngine.coreDumps.type must be \"emptyDir\" or \"hostPath\", got %q" .Values.rtpEngine.coreDumps.type) }}
{{- end }}
{{- end -}}

{{/*
The Secret holding this VG cluster's ES256 signing keypair, or "" when there is
none.

Two ways to have one, and this collapses them for every consumer: a Secret you
manage (`existingSecret`), or the chart-generated one from
common-secrets/vg-cluster-signing-key-job.yaml. Empty means neither -- the JWKS
endpoint then 404s and the resolver presents no credential.
*/}}
{{- define "vg.clusterSigningKey.secretName" -}}
{{- if .Values.vgCluster.signingKey.existingSecret -}}
{{- .Values.vgCluster.signingKey.existingSecret -}}
{{- else if .Values.vgCluster.signingKey.autoGenerate -}}
vg-cluster-signing-key
{{- end -}}
{{- end -}}

{{/*
This VG cluster's identity, used as the JWT `iss` and as the key every linked AI
cluster files it under.

Falls back to billing.clusterId then the webapp ingress host -- the same chain
api-server already uses for VG_CLUSTER_ID -- so an upgraded cluster has a working
identity with no new value set. A cluster that will actually be linked should set
vgCluster.name explicitly: a hostname-derived identity changes if the host does,
and each linked AI cluster's trust list is keyed by this exact string.
*/}}
{{- define "vg.clusterName" -}}
{{- .Values.vgCluster.name | default .Values.billing.clusterId | default .Values.ingress.webapp.host -}}
{{- end -}}

{{/*
Fail the render unless this cluster's identity is usable as a JWT `iss`.

Called only when resourceResolver.runtimeApiTargets is non-empty -- an unlinked
cluster needs no identity at all.

Emptiness is the load-bearing check: every verifier rejects an empty issuer, so a
cluster with no vgCluster.name, no billing.clusterId and no ingress.webapp.host
would otherwise render VG_CLUSTER_NAME: "" and 401 on every call.

Whitespace is checked because the AI side's trust list is keyed by this string
BYTE FOR BYTE -- `vg-team-dev ` with a trailing space is a different key from
`vg-team-dev`, and the resulting 401 says nothing about where the space is. A
stray space is invisible in a values-file review and unguessable from the error.

Deliberately NOT a hostname or DNS-label regex: the fallback chain ends at
ingress.webapp.host, so a perfectly valid identity here can be `vg.example.com`,
dots and all. Case is not checked either -- the chart cannot know how a given AI
cluster filed this one, so `VG-Team-Dev` may well be correct. Both belong in the
linking SOP, not in a render guard that would reject working configurations.
*/}}
{{- define "vg.clusterName.validate" -}}
{{- $name := include "vg.clusterName" . -}}
{{- if not $name -}}
{{- fail "This cluster has no resolvable identity, and resourceResolver.runtimeApiTargets is set. VG_CLUSTER_NAME becomes the JWT `iss` the AI cluster's trust list is keyed by, and an empty issuer is rejected by every verifier. Set vgCluster.name (recommended for a linked cluster), or billing.clusterId, or ingress.webapp.host." -}}
{{- end -}}
{{- if regexMatch "\\s" $name -}}
{{- fail (printf "This cluster's identity %q contains whitespace. It becomes the JWT `iss`, and each linked AI cluster's trust list is keyed by this string byte for byte -- a stray space is a 401 on every call, with nothing in the error to point at it. Fix vgCluster.name (or whichever of billing.clusterId / ingress.webapp.host it fell back to)." $name) -}}
{{- end -}}
{{- end -}}

{{/*
Fail the render unless every resourceResolver.runtimeApiTargets entry carries the
`name` and `url` the resolver requires.

vg-resource-resolver's own parseRuntimeApiTargets rejects a malformed entry at
boot, so this is defence in depth rather than the only check -- but it moves the
failure from a CrashLoopBackOff on an already-rolled pod to a refused reconcile,
which is where a values typo should surface. Same reasoning as the drainAddresses
IPv4 guard above.

Shape only. `url` is not pattern-checked: the resolver tolerates an optional
trailing /v1, and the set of valid AI-cluster URLs is not something this chart
can enumerate.
*/}}
{{- define "vg.runtimeApiTargets.validate" -}}
{{- $targets := .Values.resourceResolver.runtimeApiTargets -}}
{{- if not (kindIs "slice" $targets) -}}
{{- fail (printf "resourceResolver.runtimeApiTargets must be a list of {name, url} maps, got %s. It is mounted as a YAML list, and vg-resource-resolver rejects a keyed map outright." (kindOf $targets)) -}}
{{- end -}}
{{- range $i, $t := $targets -}}
{{- if not (kindIs "map" $t) -}}
{{- fail (printf "resourceResolver.runtimeApiTargets[%d] must be a map with `name` and `url`, got %s" $i (kindOf $t)) -}}
{{- end -}}
{{- if not (dig "name" "" $t) -}}
{{- fail (printf "resourceResolver.runtimeApiTargets[%d] has no `name`. It becomes the JWT `aud` and must match the key this VG cluster is filed under in that AI cluster's trust list, so it cannot be derived from the url." $i) -}}
{{- end -}}
{{- if not (dig "url" "" $t) -}}
{{- fail (printf "resourceResolver.runtimeApiTargets[%d] (%v) has no `url`." $i (dig "name" "?" $t)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
