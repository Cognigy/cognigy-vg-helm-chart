{{/*
True (non-empty) when an optional realtimeBridge.env value was set: not null and not "". A plain
`with` would drop an explicit false or 0.
*/}}
{{- define "vg.realtimeBridge.envSet" -}}
{{- if and (not (kindIs "invalid" .)) (ne (toString .) "") -}}true{{- end -}}
{{- end -}}

{{/*
NOTES.txt warnings for the default-on bridge. Never fail the render: each states a degraded but
working state an operator should know about.
- The key Secret is missing (lookup is empty; it always is under helm template / --dry-run): the
  Session API answers 503 while /healthz and /readyz stay 200, so the pod looks healthy.
- The shared-host route is skipped on an ingress class other than traefik (no prefix strip).
*/}}
{{- define "vg.realtimeBridge.notesWarnings" -}}
{{- if .Values.realtimeBridge.enabled }}
{{- if not (lookup "v1" "Secret" .Release.Namespace .Values.realtimeBridge.secret.name) }}
WARNING: vg-realtime-bridge is enabled but the Secret {{ .Values.realtimeBridge.secret.name }} was not
found in namespace {{ .Release.Namespace }}. The pod runs and reports ready, but its Session API
answers 503 until the Secret (key {{ .Values.realtimeBridge.secret.bridgeApiKeyKey }}) exists. The key
is read at boot: after creating the Secret, run
  $ kubectl -n {{ .Release.Namespace }} rollout restart deploy/vg-realtime-bridge
or let the next helm upgrade roll the pod.
{{- end }}
{{- $cfg := .Values.ingress.realtimeBridge }}
{{- if and .Values.ingress.enabled $cfg.enabled (not $cfg.host) (ne .Values.ingress.ingressClassName "traefik") }}
WARNING: the vg-realtime-bridge Ingress was not rendered: without ingress.realtimeBridge.host the
Session API shares the api host under {{ $cfg.routePrefix }}, which needs a Traefik Middleware, and
ingress.ingressClassName is {{ .Values.ingress.ingressClassName | quote }}. Set an own host, or
ingress.realtimeBridge.enabled: false to silence this.
{{- end }}
{{- end }}
{{- end -}}
