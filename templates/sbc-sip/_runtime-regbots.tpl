{{/*
Regbots for carriers configured in Cognigy.AI (CGY-44772, vg-resources docs/tdd/06-vg-in-ai/031).

sbcSipSidecar.runtimeRegbots.enabled turns on REGBOT_RUNTIME_TARGETS_ENABLED and points the sidecar
at vg-resource-resolver, from which it reads the carriers to register every 60 s.

When vgAudioManager.resourcesApiTargets is also set, the sidecar reports each REGISTER attempt to
the owning AI cluster's vg-resources-api, signed with this cluster's identity: the same key, name
and target list as vg-audio-manager, so the cluster keeps ONE list of linked AI clusters. Without
it, runtime regbots still register and their results are only logged.

The resolver guard runs whether or not the sbc-sip workload renders, like vg-audio-manager's. Reporting
needs no guards of its own: it is on only when vgAudioManager.resourcesApiTargets is set, and
vg-audio-manager/deployment.yaml fails the render unconditionally for that list (no signing key,
malformed targets, missing cluster name), so the sidecar can never see an invalid one.
*/}}

{{- /* Under the FedRAMP profile global.fedramp.sbcSipRuntimeRegbots decides (templates/_fedramp.tpl). */}}
{{- define "vg.sbcSip.runtimeRegbots.enabled" -}}
{{- include "vg.fedramp.sbcSipRuntimeRegbots" . -}}
{{- end -}}

{{- define "vg.sbcSip.runtimeRegbots.reporting" -}}
{{- if and (include "vg.sbcSip.runtimeRegbots.enabled" .) (include "vg.resourcesApiTargets.effective" . | fromJsonArray) -}}true{{- end -}}
{{- end -}}

{{- define "vg.sbcSip.runtimeRegbots.validate" -}}
{{- if include "vg.sbcSip.runtimeRegbots.enabled" . -}}
{{- if not .Values.resourceResolver.enabled -}}
{{- fail "sbcSipSidecar.runtimeRegbots.enabled needs resourceResolver.enabled: the sidecar reads the carriers to register from vg-resource-resolver." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Pod annotations: the target list and the key are read once at start, so either changing rolls the pod. */}}
{{- define "vg.sbcSip.runtimeRegbots.annotations" -}}
{{- if include "vg.sbcSip.runtimeRegbots.reporting" . -}}
{{- $secret := include "vg.clusterSigningKey.secretName" . -}}
checksum/sbc-sip-resources-api-targets: {{ include (print .Template.BasePath "/sbc-sip/resources-api-targets-configmap.yaml") . | sha256sum }}
checksum/vg-cluster-signing-key: {{ if not (lookup "v1" "Secret" .Release.Namespace $secret) }}{{ $secret | sha256sum }}{{ else }}{{ toYaml (lookup "v1" "Secret" .Release.Namespace $secret).data | sha256sum }}{{ end }}
{{- end -}}
{{- end -}}

{{/* sbc-sip-sidecar env. Rendered before extraEnvVars, so an extraEnvVars entry still wins. */}}
{{- define "vg.sbcSip.runtimeRegbots.env" -}}
{{- if include "vg.sbcSip.runtimeRegbots.enabled" . -}}
- name: REGBOT_RUNTIME_TARGETS_ENABLED
  value: "true"
- name: RESOURCE_RESOLVER_URL
  value: "http://vg-resource-resolver.{{ .Release.Namespace }}:{{ .Values.resourceResolver.port | default 4000 }}"
{{- if include "vg.sbcSip.runtimeRegbots.reporting" . }}
## Register events (031 §2.4). VG_CLUSTER_NAME is this cluster's JWT `iss`.
- name: VG_CLUSTER_NAME
  value: {{ include "vg.clusterName" . | quote }}
- name: RESOURCES_API_TARGETS_PATH
  value: "/config/vg-resources-api/targets.json"
- name: VG_CLUSTER_SIGNING_KEY_PATH
  value: "/var/run/secrets/vg-cluster/{{ .Values.vgCluster.signingKey.privateKeyFile }}"
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "vg.sbcSip.runtimeRegbots.volumeMounts" -}}
{{- if include "vg.sbcSip.runtimeRegbots.reporting" . -}}
- name: sbc-sip-resources-api-targets
  mountPath: /config/vg-resources-api
  readOnly: true
- name: vg-cluster-signing-key
  mountPath: /var/run/secrets/vg-cluster
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "vg.sbcSip.runtimeRegbots.volumes" -}}
{{- if include "vg.sbcSip.runtimeRegbots.reporting" . -}}
- name: sbc-sip-resources-api-targets
  configMap:
    name: sbc-sip-resources-api-targets
    items:
      - key: targets.json
        path: targets.json
- name: vg-cluster-signing-key
  secret:
    secretName: {{ include "vg.clusterSigningKey.secretName" . | quote }}
    ## Private half only, 0400. Readable by root only: a non-root sidecar needs podSecurityContext.fsGroup
    ## (see sbcSipSidecar.runtimeRegbots in values.yaml).
    items:
      - key: {{ .Values.vgCluster.signingKey.privateKeyFile | quote }}
        path: {{ .Values.vgCluster.signingKey.privateKeyFile | quote }}
    defaultMode: 256
{{- end -}}
{{- end -}}
