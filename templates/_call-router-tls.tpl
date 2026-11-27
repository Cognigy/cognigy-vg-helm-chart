{{/*
TLS for the drachtio -> sbc-call-router hop (CGY-47751, SC-8 work map A9, docs/016-call-router-tls.md).

sbc-sip's drachtio posts every inbound INVITE (the full SIP message, SDP included) to sbc-call-router.
sbc-sip runs on the host network, outside the mesh, so the hop carries its own TLS: sbc-call-router
serves HTTPS on sbcCallRouter.port with a chart-minted certificate (templates/sbc-call-router/tls-secret.yaml),
and drachtio's request-handler trusts only the chart's CA (its ca-file attribute). The port serves
HTTPS only, so both ends follow one switch (vg.fedramp.callRouterTls).
*/}}

{{/* Where the certificate is mounted: the server's pair in sbc-call-router, the CA in drachtio. */}}
{{- define "vg.callRouterTls.mountPath" -}}/etc/call-router-tls{{- end -}}

{{/*
DNS names on the certificate, as a YAML list: the sbc-call-router Service, short (what drachtio dials)
and qualified. No IP addresses and no localhost: nothing dials the call-router by IP, and the probes
use the health port.
*/}}
{{- define "vg.callRouterTls.dnsNames" -}}
{{- $ns := .Release.Namespace -}}
{{- toYaml (list "sbc-call-router" (printf "sbc-call-router.%s" $ns) (printf "sbc-call-router.%s.svc" $ns) (printf "sbc-call-router.%s.svc.cluster.local" $ns)) -}}
{{- end -}}

{{/*
The certificate material, as JSON with the base64 values of tls.crt, tls.key and ca.crt.
Reuse before mint, cached in this render (sbcCallRouter.tls._material), with the same reasons and
limits as vg.mysqlTls.material: the CA stays stable across upgrades, and the Secret and both pods'
checksums see the same certificate even in the render that mints it.
sbcCallRouter.tls._lookup (Secrets by name) stands in for the API server in the render tests, since
lookup returns nothing under `helm template`; with it set, lookup is not called. Test-only.
*/}}
{{- define "vg.callRouterTls.material" -}}
{{- $cache := .Values.sbcCallRouter.tls -}}
{{- if not (hasKey $cache "_material") -}}
{{- $secretName := .Values.sbcCallRouter.tls.secretName -}}
{{- $existing := dict -}}
{{- if hasKey $cache "_lookup" -}}
{{- $existing = get $cache._lookup $secretName | default dict -}}
{{- else -}}
{{- $existing = lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- end -}}
{{- /*
  A Secret that exists without ca.crt is refused rather than replaced: that is what an external
  issuer produces, and overwriting it would swap the CA under drachtio. One with the CA but without
  its certificate or key cannot be repaired either: the CA key is not kept, so nothing can sign a new
  certificate for that CA.
*/ -}}
{{- if and $existing $existing.data (not (index $existing.data "ca.crt")) -}}
{{- fail (printf "Secret %q already exists in namespace %q but has no ca.crt, so this chart cannot reuse it and refuses to overwrite it. Delete it and let the chart mint its own pair." $secretName .Release.Namespace) -}}
{{- end -}}
{{- if and $existing $existing.data (index $existing.data "ca.crt") (or (not (index $existing.data "tls.crt")) (not (index $existing.data "tls.key"))) -}}
{{- fail (printf "Secret %q in namespace %q has ca.crt but lacks tls.crt or tls.key, so sbc-call-router could not serve TLS. Delete it and let the chart mint a new pair (docs/016-call-router-tls.md, Rotation)." $secretName .Release.Namespace) -}}
{{- end -}}
{{- if and $existing $existing.data (index $existing.data "ca.crt") -}}
{{- $_ := set $cache "_material" (dict "tls.crt" (index $existing.data "tls.crt") "tls.key" (index $existing.data "tls.key") "ca.crt" (index $existing.data "ca.crt")) -}}
{{- else -}}
{{- $days := int .Values.sbcCallRouter.tls.certValidityDays -}}
{{- $ca := genCA "sbc-call-router-ca" $days -}}
{{- $leaf := genSignedCert (printf "sbc-call-router.%s.svc" .Release.Namespace) nil (include "vg.callRouterTls.dnsNames" . | fromYamlArray) $days $ca -}}
{{- $_ := set $cache "_material" (dict "tls.crt" (b64enc $leaf.Cert) "tls.key" (b64enc $leaf.Key) "ca.crt" (b64enc $ca.Cert)) -}}
{{- end -}}
{{- end -}}
{{- get $cache "_material" | toJson -}}
{{- end -}}

{{/*
Refuses images that predate the hop's TLS. The port serves HTTPS only and drachtio dials it with
ca-file, so both ends must carry it or every inbound INVITE fails to route:
- drachtio older than sbcCallRouter.tls.drachtioMinVersion (vg-drachtio#65) ignores ca-file, checks the
  certificate against the system store and fails every routing request.
- sbc-call-router older than sbcCallRouter.tls.minVersion (vg-sbc-call-router#74) ignores HTTP_TLS_* and
  serves plain HTTP, which drachtio's TLS handshake fails against.
Only release tags are judged (vg.common.imageVersion, vg.common.imageRelease); a branch build is the
operator's call. An empty minimum switches its check off. Takes the root context.
*/}}
{{- define "vg.callRouterTls.validateImages" -}}
{{- $t := .Values.sbcCallRouter.tls -}}
{{- $drachtio := include "vg.common.imageVersion" .Values.drachtio.image -}}
{{- if and $t.drachtioMinVersion $drachtio (semverCompare (printf "<%s" $t.drachtioMinVersion) $drachtio) -}}
{{- fail (printf "TLS to sbc-call-router needs vg-drachtio %s or newer (the request-handler ca-file attribute). drachtio.image is %s, which ignores ca-file, so every inbound INVITE would fail to route. Set drachtio.image to a build that carries it or, for a build you know carries it, sbcCallRouter.tls.drachtioMinVersion: \"\" (docs/016-call-router-tls.md)." $t.drachtioMinVersion .Values.drachtio.image) -}}
{{- end -}}
{{- $router := include "vg.common.imageRelease" .Values.sbcCallRouter.image -}}
{{- if and $t.minVersion $router (semverCompare (printf "<%s" $t.minVersion) $router) -}}
{{- fail (printf "TLS to sbc-call-router needs vg-sbc-call-router %s or newer (HTTP_TLS_CERT_FILE / HTTP_TLS_KEY_FILE). sbcCallRouter.image is %s, which serves plain HTTP, so every inbound INVITE would fail to route. Set sbcCallRouter.image to a build that carries it or, for a build you know carries it, sbcCallRouter.tls.minVersion: \"\" (docs/016-call-router-tls.md)." $t.minVersion .Values.sbcCallRouter.image) -}}
{{- end -}}
{{- end -}}

{{/*
Checksums as pod annotations, so a certificate that changes rolls the pods that read it at start:
sbc-call-router the server certificate, sbc-sip the CA.
*/}}
{{- define "vg.callRouterTls.serverChecksum" -}}
checksum/call-router-tls: {{ get (include "vg.callRouterTls.material" . | fromJson) "tls.crt" | sha256sum }}
{{- end -}}

{{- define "vg.callRouterTls.caChecksum" -}}
checksum/call-router-tls-ca: {{ get (include "vg.callRouterTls.material" . | fromJson) "ca.crt" | sha256sum }}
{{- end -}}

{{/*
sbc-call-router env (vg-sbc-call-router with CGY-47751): both set, the port serves HTTPS only. Under the
FedRAMP profile an sbcCallRouter.extraEnvVars entry with either name fails the render: it renders after
this block and would override the profile without a global.fedramp.* deviation (as for MySQL TLS).
*/}}
{{- define "vg.callRouterTls.serverEnv" -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- with .Values.sbcCallRouter.extraEnvVars -}}
{{- range include "vg.common.tplvalues.render" (dict "value" . "context" $) | fromYamlArray -}}
{{- if and (kindIs "map" .) (has (toString (get . "name")) (list "HTTP_TLS_CERT_FILE" "HTTP_TLS_KEY_FILE")) -}}
{{- fail (printf "sbcCallRouter.extraEnvVars cannot set %s while global.fedramp.enabled is true: it would override the profile's call-router TLS. Use global.fedramp.callRouterTls instead (docs/016-call-router-tls.md)." (get . "name")) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
- name: HTTP_TLS_CERT_FILE
  value: {{ include "vg.callRouterTls.mountPath" . }}/tls.crt
- name: HTTP_TLS_KEY_FILE
  value: {{ include "vg.callRouterTls.mountPath" . }}/tls.key
{{- end -}}

{{/*
The key is mounted 0440 and owned by root; the call-router runs as uid/gid 1000 (node), so the pod
gets fsGroup 1000 (vg.sbcCallRouter.podSecurityContext).
*/}}
{{- define "vg.callRouterTls.serverVolume" -}}
- name: call-router-tls
  secret:
    secretName: {{ .Values.sbcCallRouter.tls.secretName }}
    defaultMode: 0440
    items:
      - key: tls.crt
        path: tls.crt
      - key: tls.key
        path: tls.key
{{- end -}}

{{/* Only the CA reaches sbc-sip, never the server key. */}}
{{- define "vg.callRouterTls.caVolume" -}}
- name: call-router-tls-ca
  secret:
    secretName: {{ .Values.sbcCallRouter.tls.secretName }}
    items:
      - key: ca.crt
        path: ca.crt
{{- end -}}

{{- define "vg.callRouterTls.serverVolumeMount" -}}
- name: call-router-tls
  mountPath: {{ include "vg.callRouterTls.mountPath" . }}
  readOnly: true
{{- end -}}

{{- define "vg.callRouterTls.caVolumeMount" -}}
- name: call-router-tls-ca
  mountPath: {{ include "vg.callRouterTls.mountPath" . }}
  readOnly: true
{{- end -}}

{{/*
Pod securityContext of sbc-call-router, from sbcCallRouter.podSecurityContext, plus fsGroup 1000 while
TLS is on and none is set, so the node user can read the 0440 key. Empty when there is nothing to set.
Takes the root context.
*/}}
{{- define "vg.sbcCallRouter.podSecurityContext" -}}
{{- /* podSecurityContext may be a templated string: render and parse it into a map before adding to it. */ -}}
{{- $psc := fromYaml (include "vg.common.tplvalues.render" (dict "value" (.Values.sbcCallRouter.podSecurityContext | default dict) "context" .)) | default dict -}}
{{- /* An explicit null counts as unset: it is how values unset a key. */ -}}
{{- if and (include "vg.fedramp.callRouterTls" .) (or (not (hasKey $psc "fsGroup")) (kindIs "invalid" (index $psc "fsGroup"))) -}}
{{- $_ := set $psc "fsGroup" 1000 -}}
{{- end -}}
{{- if $psc -}}{{ toYaml $psc }}{{- end -}}
{{- end -}}
