{{/*
True (non-empty) when an optional realtimeBridge.env value was set: not null and not "". A plain
`with` would drop an explicit false or 0.
*/}}
{{- define "vg.realtimeBridge.envSet" -}}
{{- if and (not (kindIs "invalid" .)) (ne (toString .) "") -}}true{{- end -}}
{{- end -}}
