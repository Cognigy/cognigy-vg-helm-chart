{{- define "vg.common.image.render" -}}

{{- $fullName := .image }}

{{- if .global }}
  {{- if .global.imageRegistry }}
    {{- $currentRegistry := .image | toString | regexFind ".*/" | trimSuffix "/" }}
    {{- $fullName = (printf "%s%s" .global.imageRegistry (trimPrefix $currentRegistry .image)) }}
  {{- end }}
{{- end }}

{{- printf "%s" $fullName }}
{{- end }}

{{/*
The X.Y.Z release in an image reference, for minimum-version guards (vg.redisTls.validateDrachtioImage,
vg.redisAuth.validateApiBanImage); empty when the tag does not start with one (a branch build, a
two-part floating tag like "1.3"). Drops a "@sha256:..." digest first, so the tag before it is read,
and keeps only the X.Y.Z core of a suffixed tag ("1.3.22-fips" -> "1.3.22"): Masterminds semver never
matches a pre-release against a plain constraint, so the full tag would always pass. A reference
without a tag yields the last path segment, which never matches. Takes the image reference.
*/}}
{{- define "vg.common.imageVersion" -}}
{{- regexFind "^v?[0-9]+\\.[0-9]+\\.[0-9]+" (last (splitList ":" (first (splitList "@" .)))) -}}
{{- end -}}

{{/*
The release in an image reference with its pre-release suffix kept ("2026.24.0-91"), for guards
whose minimum is a preview build (vg.callRouterTls.validateImages): the preview releases of a sprint
share its X.Y.Z and differ only in the suffix, which vg.common.imageVersion drops. Compare it against a
minimum that carries a suffix too, since Masterminds semver never matches a pre-release against a plain
constraint. Empty when the tag is not a release (a branch build, a floating tag); a digest is dropped
first, as in vg.common.imageVersion. Takes the image reference.
*/}}
{{- define "vg.common.imageRelease" -}}
{{- regexFind "^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$" (last (splitList ":" (first (splitList "@" .)))) -}}
{{- end -}}
