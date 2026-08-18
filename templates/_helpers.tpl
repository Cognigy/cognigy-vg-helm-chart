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
{{- if and .Values.freeswitch.regionDnsEnabled (not (and .Values.vgTestHarness.enabled .Values.vgTestHarness.regionDns.enabled)) }}{{ fail "freeswitch.regionDnsEnabled requires vgTestHarness.enabled=true and vgTestHarness.regionDns.enabled=true (otherwise the FreeSWITCH pod's dnsConfig points at a Service that doesn't exist)" }}{{- end }}
{{- if .Values.freeswitch.regionDnsEnabled }}
dnsPolicy: None
dnsConfig:
  nameservers:
    - {{ required "vgTestHarness.regionDns.clusterIP is required when freeswitch.regionDnsEnabled is true" .Values.vgTestHarness.regionDns.clusterIP }}
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
Test-harness FreeSWITCH speech-endpoint overrides (vg-freeswitch PR #255).
Origin-only, plain HTTP/WS, port 8080 on the in-cluster mock-speech Service.
No-op unless vgTestHarness.enabled. Requires an asan/debug freeswitch image.

Suppressed whenever freeswitch.regionDnsEnabled is true: the two mechanisms
are mutually exclusive by design. TESTING_OVERRIDE_STT_URL is read by
fs_testing_override_stt_endpoint() (vg-freeswitch's testing_overrides.cpp),
which is called unconditionally from every STT vendor's glue code — including
classic Deepgram's dg_transcribe_glue.cpp — AFTER it already resolves the
region-specific DEEPGRAM_URI host, and clobbers that resolved host with
mock-speech regardless of what it was. If both were set at once, the
region-routing regression test (mock-deepgram-eu/intl + the dedicated
test-dns CoreDNS instance) would never see any traffic: FreeSWITCH would
always connect to mock-speech instead of attempting real DNS resolution for
api.deepgram.com / api.eu.deepgram.com, regardless of the configured region.
Enabling freeswitch.regionDnsEnabled therefore means this pod's OTHER
mocked-speech scenarios are not mocked for the duration — toggle it only for
the two region-test scenario runs, not as a permanently-on flag alongside
routine quality-gate scenarios.
*/}}
{{- define "vg.testHarness.freeswitchEnv" -}}
{{- if and .Values.vgTestHarness.enabled (not .Values.freeswitch.regionDnsEnabled) }}
- name: TESTING_OVERRIDE_TTS_URL
  value: "http://mock-speech.{{ .Release.Namespace }}.svc.cluster.local:8080"
- name: TESTING_OVERRIDE_STT_URL
  value: "ws://mock-speech.{{ .Release.Namespace }}.svc.cluster.local:8080"
{{- end }}
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
