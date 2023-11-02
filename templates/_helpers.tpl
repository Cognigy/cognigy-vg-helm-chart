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
Return the proper tls certificate Secret Name
*/}}
{{- define "tlsCertificate.secretName.render" -}}
  {{- $tlsCertificateSecretName := "" -}}

  {{- if and (.Values.tls.enabled) (.Values.traefik.enabled) -}}
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
Return the proper billing app user credentials 
*/}}
{{- define "billingAppUserCreds" -}}
  {{- $billingAppUserCredsInfo := "" -}}

  {{- if .Values.billingApp.enabled -}}
    {{- if .Values.billingApp.billingAppUserCreds.existingCredentials -}}
      {{- $billingAppUserCredsInfo = .Values.billingApp.billingAppUserCreds.existingCredentials -}}
    {{- else if and (.Values.billingApp.billingAppUserCreds.user) (.Values.billingApp.billingAppUserCreds.password) -}}
      {{- $billingAppUserCredsInfo = "billing-app-user-credentials" -}}
    {{- else -}}
      {{ required "A valid value for .Values.billingApp.billingAppUserCredsInfo is required!" .Values.billingApp.billingAppUserCredsInfo.user }}
      {{ required "A valid value for .Values.billingApp.billingAppUserCredsInfo is required!" .Values.billingApp.billingAppUserCredsInfo.password }}
      {{ required "A valid value for .Values.billingApp.billingAppUserCredsInfo is required!" .Values.billingApp.billingAppUserCredsInfo.existingCredentials }}
    {{- end -}}
  {{- end -}}

  {{- if (not (empty $billingAppUserCredsInfo)) -}}
    {{- printf "%s" (tpl $billingAppUserCredsInfo $) | indent 1 -}}
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
    {{- else if and (.Values.testCallManager.interactionPanelServiceProvider.id) (.Values.testCallManager.interactionPanelServiceProvider.apiKey) -}}
      {{- $interactionPanelServiceProviderInfo = "voicegateway-interaction-panel-service-provider" -}}
    {{- else -}}
      {{ required "A valid value for .Values.testCallManager.interactionPanelServiceProvider is required!" .Values.testCallManager.interactionPanelServiceProvider.id }}
      {{ required "A valid value for .Values.testCallManager.interactionPanelServiceProvider is required!" .Values.testCallManager.interactionPanelServiceProvider.apiKey }}
      {{ required "A valid value for .Values.testCallManager.interactionPanelServiceProvider is required!" .Values.testCallManager.interactionPanelServiceProvider.existingCredentials }}
    {{- end -}}
  {{- end -}}

  {{- if (not (empty $interactionPanelServiceProviderInfo)) -}}
    {{- printf "%s" (tpl $interactionPanelServiceProviderInfo $) | indent 1 -}}
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