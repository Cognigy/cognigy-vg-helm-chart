{{/*
TLS on the drachtio control hop (CGY-46071, SC-8 work map A10, docs/017-drachtio-control-tls.md).

In Kubernetes, sbc-sip's drachtio opens a TCP connection to sbc-inbound or sbc-outbound for every new
SIP request it hands over (DRACHTIO_PORT, sbcInbound.ports.tcp / sbcOutbound.ports.tcp), and that
connection carries every SIP message and SDP of the call. sbc-sip runs on the host network, outside
the mesh, so the hop carries its own TLS:
- sbc-inbound and sbc-outbound listen with TLS (vg-drachtio-srf srf.listen) on their chart-minted
  server certificates and require a client certificate from the chart's CA before they send drachtio
  the shared secret (mTLS);
- drachtio dials them over TLS, trusts only the chart's CA, checks the host name and presents the
  sbc-sip client certificate (DRACHTIO_OUTBOUND_TLS_*, vg-drachtio 1.3.28 or later);
- sbc-call-router appends ;transport=tls to the routes it returns, which is what makes drachtio dial
  TLS (DRACHTIO_CONTROL_TRANSPORT).
All four workloads follow one switch (vg.fedramp.drachtioControlTls). A mix fails calls closed: a TLS
dial to a plaintext listener, or a plaintext dial to a TLS listener, fails the handshake.
drachtioControlTls.prepare mints and mounts the certificates without the variables, the first step of
the cutover (vg.drachtioControlTls.mounted). The certificates are in
templates/common-secrets/drachtio-control-tls.yaml.
*/}}

{{/* Where the certificates are mounted, in the drachtio container of sbc-sip and in sbc-inbound / sbc-outbound. */}}
{{- define "vg.drachtioControlTls.mountPath" -}}/etc/drachtio-control-tls{{- end -}}

{{/*
"true" when the control hop runs over TLS, empty otherwise. Takes the root context. Refuses malformed
image minimums on every render (vg.drachtioControlTls.validateMinimums), and, while the hop is on, a
drachtio image without the options (vg.drachtioControlTls.validateDrachtioImage), SBC and call-router
images older than their minimum (vg.drachtioControlTls.validateServiceImages) and values that would
weaken the hop (vg.drachtioControlTls.validateEnv).
*/}}
{{- define "vg.drachtioControlTls.enabled" -}}
{{- include "vg.drachtioControlTls.validateMinimums" . -}}
{{- if include "vg.fedramp.drachtioControlTls" . -}}
{{- include "vg.drachtioControlTls.validateDrachtioImage" . -}}
{{- include "vg.drachtioControlTls.validateServiceImages" . -}}
{{- include "vg.drachtioControlTls.validateEnv" . -}}
true
{{- end -}}
{{- end -}}

{{/*
"true" when the certificates are minted and mounted: with the hop on, or with drachtioControlTls.prepare,
which stages them before the cutover (secrets, mounts, fsGroup and checksums, but none of the hop's
variables, so the pods behave as before). Allowed under the FedRAMP profile too: it switches nothing.
Takes the root context.
*/}}
{{- define "vg.drachtioControlTls.mounted" -}}
{{- if or (include "vg.drachtioControlTls.enabled" .) (dig "prepare" false (.Values.drachtioControlTls | default dict)) -}}true{{- end -}}
{{- end -}}

{{/*
"true" when an image whose tag cannot be judged may pass: outside the FedRAMP profile always (the
operator's call, as before), under it only with drachtioControlTls.allowUncheckedImages, a deviation to
record in the POA&M (docs/009-fedramp-profile.md). Takes the root context.
*/}}
{{- define "vg.drachtioControlTls.uncheckedAllowed" -}}
{{- if or (not (include "vg.fedramp.enabled" .)) (dig "allowUncheckedImages" false (.Values.drachtioControlTls | default dict)) -}}true{{- end -}}
{{- end -}}

{{/*
Refuses a drachtio image that predates DRACHTIO_OUTBOUND_TLS_CA_FILE (vg-drachtio, CGY-46071). An older
drachtio ignores the variables and, without an admin TLS port, fails every ;transport=tls dial ("TLS
requested but not configured"), so every call would fail.
- Outside the FedRAMP profile, judged as vg.redisTls.validateDrachtioImage: release tags by their X.Y.Z
  core (1.3.28-fips as 1.3.28), other tags left to the operator, and "" switches the check off.
- Under the profile an empty minimum is refused, and only the tags vg-drachtio releases are judged:
  X.Y.Z, optionally v-prefixed or with -fips. Any other tag (a pre-release such as 1.3.28-rc1, which may
  predate the change, a branch build, latest, untagged, digest only) is refused unless
  vg.drachtioControlTls.uncheckedAllowed, as for the SBC images.
Takes the root context.
*/}}
{{- define "vg.drachtioControlTls.validateDrachtioImage" -}}
{{- $min := toString (.Values.drachtioControlTls.drachtioMinVersion | default "") -}}
{{- $version := include "vg.common.imageVersion" .Values.drachtio.image -}}
{{- $tag := last (splitList ":" (first (splitList "@" (toString .Values.drachtio.image)))) -}}
{{- if and (include "vg.fedramp.enabled" .) (not (regexMatch `^v?[0-9]+\.[0-9]+\.[0-9]+(-fips)?$` $tag)) -}}
{{- $version = "" -}}
{{- end -}}
{{- if not $min -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- fail "drachtioControlTls.drachtioMinVersion must be set while global.fedramp.drachtioControlTls is on: an older drachtio would fail every call, and the profile must not rely on an unchecked image. Set it to the first vg-drachtio release with DRACHTIO_OUTBOUND_TLS_CA_FILE (docs/017-drachtio-control-tls.md)." -}}
{{- end -}}
{{- else if not $version -}}
{{- if not (include "vg.drachtioControlTls.uncheckedAllowed" .) -}}
{{- fail (printf "drachtio.image is %s, whose tag is not a vg-drachtio release tag (X.Y.Z, optionally with -fips), so it cannot be checked against drachtioControlTls.drachtioMinVersion %s while global.fedramp.drachtioControlTls is on. Pin a release tag (a digest may follow it: :1.3.28@sha256:...), or record a deviation and set drachtioControlTls.allowUncheckedImages: true (docs/009-fedramp-profile.md)." .Values.drachtio.image $min) -}}
{{- end -}}
{{- else if semverCompare (printf "<%s" $min) $version -}}
{{- fail (printf "drachtio control TLS needs vg-drachtio %s or newer in sbc-sip (DRACHTIO_OUTBOUND_TLS_CA_FILE). drachtio.image is %s, which ignores the options and fails every TLS dial to sbc-inbound and sbc-outbound, so every call would fail. Set drachtio.image to a build that carries them, turn drachtio control TLS off, or, outside the FedRAMP profile and for a build you know carries them, set drachtioControlTls.drachtioMinVersion: \"\" (docs/017-drachtio-control-tls.md)." $min .Values.drachtio.image) -}}
{{- end -}}
{{- end -}}

{{/*
A calendar-version tag of the VG service images, as JSON {"y","n","p","build"} (strings), or empty for a tag
that is not one. Takes the image reference or the bare tag. The tag is the part after the last ":" before
any "@digest", so a registry port is not mistaken for it and a digest after the tag does not matter.
The shapes the release process produces, with an optional leading v:
- Y.N.P-<digits>: a preview build of train Y.N, cut from main (2026.24.0-78);
- Y.N.P-rc<digits>: a release candidate, cut from the release branch (2026.23.0-rc1);
- Y.N.P: a release, or a patch release (P >= 1), from the release branch (2026.12.0, 2026.24.1).
Anything else is not judged: another suffix (2026.24.0-80-fips), a branch build, latest, no tag, digest
only. A minimum must have one of the three shapes.
*/}}
{{- define "vg.drachtioControlTls.calver" -}}
{{- $tag := last (splitList ":" (first (splitList "@" .))) -}}
{{- $re := `^v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:-(rc[0-9]+|[0-9]+))?$` -}}
{{- if regexMatch $re $tag -}}
{{- dict "y" (regexReplaceAll $re $tag "${1}") "n" (regexReplaceAll $re $tag "${2}") "p" (regexReplaceAll $re $tag "${3}") "build" (regexReplaceAll $re $tag "${4}") | toJson -}}
{{- end -}}
{{- end -}}

{{/*
"true" when calendar version .v is known to be at least .m (both from vg.drachtioControlTls.calver).
Not semver precedence, which puts 2026.24.0-78 below 2026.24.0-rc1 (numeric identifiers sort before
alphanumeric ones) and so would accept a release candidate cut before the minimum. The tags are ordered
by how they are built (docs/017-drachtio-control-tls.md has the table):
- The train is Y.N. A later train is newer than every tag of an earlier one, whatever its shape.
- Main builds Y.N.P-<n> in order: against a numbered minimum, a numbered build of the same Y.N.P passes
  with a number at least as high (100 after 80, as numbers).
- The release line comes after the main builds of its train: the cut to Y.N.P-rc1 is taken from main
  after the minimum was built, so a release candidate, the release and patch releases of the train
  (P at least the minimum's) pass a numbered minimum. This holds because a numbered minimum must predate
  its train's cut (docs/017-drachtio-control-tls.md, Rollout): main can still publish Y.N.P-<n> builds
  after the cut (2026.23.0-140 followed 2026.23.0-rc1), and a minimum among those would be passed by an
  rc1 that lacks its change.
- The release line goes Y.N.P-rc1, -rc2, ..., Y.N.P, then Y.N.(P+1) (patches, with any candidates).
  Against an rc or release minimum, a release-line tag passes when it comes at or after it in that
  order; a numbered main build of the same train comes before the release line and is refused.
*/}}
{{- define "vg.drachtioControlTls.calverAtLeast" -}}
{{- $v := .v -}}
{{- $m := .m -}}
{{- $decided := false -}}
{{- $ok := false -}}
{{- range $k := list "y" "n" -}}
{{- if and (not $decided) (ne (atoi (get $v $k)) (atoi (get $m $k))) -}}
{{- $decided = true -}}
{{- $ok = gt (atoi (get $v $k)) (atoi (get $m $k)) -}}
{{- end -}}
{{- end -}}
{{- if not $decided -}}
{{- $vb := get $v "build" -}}
{{- $mb := get $m "build" -}}
{{- $vp := atoi (get $v "p") -}}
{{- $mp := atoi (get $m "p") -}}
{{- $vNum := regexMatch "^[0-9]+$" $vb -}}
{{- $mNum := regexMatch "^[0-9]+$" $mb -}}
{{- if $mNum -}}
{{- if not $vNum -}}
{{- /* The release line of the train comes after its main builds. */ -}}
{{- $ok = ge $vp $mp -}}
{{- else if eq $vp $mp -}}
{{- $ok = ge (atoi $vb) (atoi $mb) -}}
{{- end -}}
{{- else if not $vNum -}}
{{- /* Both on the release branch: (P, rcK before the release, K). */ -}}
{{- if ne $vp $mp -}}
{{- $ok = gt $vp $mp -}}
{{- else if eq $vb "" -}}
{{- $ok = true -}}
{{- else if ne $mb "" -}}
{{- $ok = ge (atoi (trimPrefix "rc" $vb)) (atoi (trimPrefix "rc" $mb)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $ok -}}true{{- end -}}
{{- end -}}

{{/*
Refuses, on every render, a drachtioControlTls.minImageVersions entry that is set but not a release tag
(vg.drachtioControlTls.calver), and a drachtioMinVersion that is set but not X.Y.Z (optionally v-prefixed),
so a typo shows when it is written and not when the hop is turned on. Takes the root context.
*/}}
{{- define "vg.drachtioControlTls.validateMinimums" -}}
{{- $dmin := toString ((.Values.drachtioControlTls | default dict).drachtioMinVersion | default "") -}}
{{- if and $dmin (not (regexMatch `^v?[0-9]+\.[0-9]+\.[0-9]+$` $dmin)) -}}
{{- fail (printf "drachtioControlTls.drachtioMinVersion is %q, which is not a vg-drachtio release version: X.Y.Z (docs/017-drachtio-control-tls.md)." $dmin) -}}
{{- end -}}
{{- $mins := (.Values.drachtioControlTls | default dict).minImageVersions | default dict -}}
{{- range $key := list "sbcInbound" "sbcOutbound" "sbcCallRouter" -}}
{{- $min := toString (get $mins $key | default "") -}}
{{- if and $min (not (include "vg.drachtioControlTls.calver" $min)) -}}
{{- fail (printf "drachtioControlTls.minImageVersions.%s is %q, which is not a release tag: YYYY.N.P, YYYY.N.P-<number> or YYYY.N.P-rc<number> (docs/017-drachtio-control-tls.md)." $key $min) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Refuses sbc-inbound, sbc-outbound and sbc-call-router images older than
drachtioControlTls.minImageVersions.<key>, the first release of each that carries CGY-46071. An older
SBC ignores DRACHTIO_LISTEN_TLS_* and keeps a plaintext listener, so every call fails; an older
call-router ignores DRACHTIO_CONTROL_TRANSPORT and routes without ;transport=tls, so drachtio dials plain
TCP and logs only a warning: calls fail against the TLS listeners, and where the SBCs are old too the hop
silently stays plaintext. Ordering: vg.drachtioControlTls.calverAtLeast.
- Outside the FedRAMP profile an empty minimum leaves the image unchecked, and so does a tag that cannot
  be judged (vg.drachtioControlTls.calver): the operator's call, as before.
- Under the profile an empty minimum is refused, and so is a tag that cannot be judged (digest only,
  latest, untagged, a branch build, another suffix) unless drachtioControlTls.allowUncheckedImages
  records a deviation: the profile must not rely on an unchecked image.
Takes the root context.
*/}}
{{- define "vg.drachtioControlTls.validateServiceImages" -}}
{{- $root := . -}}
{{- $mins := (.Values.drachtioControlTls | default dict).minImageVersions | default dict -}}
{{- $names := dict "sbcInbound" "vg-sbc-inbound" "sbcOutbound" "vg-sbc-outbound" "sbcCallRouter" "vg-sbc-call-router" -}}
{{- range $key := list "sbcInbound" "sbcOutbound" "sbcCallRouter" -}}
{{- $name := get $names $key -}}
{{- $min := toString (get $mins $key | default "") -}}
{{- $image := toString (index $root.Values $key).image -}}
{{- if not $min -}}
{{- if include "vg.fedramp.enabled" $root -}}
{{- fail (printf "drachtioControlTls.minImageVersions.%s must be set while global.fedramp.drachtioControlTls is on: an image without CGY-46071 would leave the hop plaintext or fail every call, and the profile must not rely on an unchecked image. Set it to the first %s release that carries CGY-46071 (docs/017-drachtio-control-tls.md)." $key $name) -}}
{{- end -}}
{{- else -}}
{{- /* Test the JSON text: fromJson of an empty string is not empty (it carries an Error key). */ -}}
{{- $vj := include "vg.drachtioControlTls.calver" $image -}}
{{- if not $vj -}}
{{- if not (include "vg.drachtioControlTls.uncheckedAllowed" $root) -}}
{{- fail (printf "%s.image is %s, whose tag is not a release tag (YYYY.N.P, YYYY.N.P-<number>, YYYY.N.P-rc<number>), so it cannot be checked against drachtioControlTls.minImageVersions.%s %s while global.fedramp.drachtioControlTls is on. Pin a release tag (a digest may follow it: :%s@sha256:...), or record a deviation and set drachtioControlTls.allowUncheckedImages: true (docs/009-fedramp-profile.md)." $key $image $key $min $min) -}}
{{- end -}}
{{- else if not (include "vg.drachtioControlTls.calverAtLeast" (dict "v" ($vj | fromJson) "m" (include "vg.drachtioControlTls.calver" $min | fromJson))) -}}
{{- fail (printf "drachtio control TLS needs %s %s or newer (drachtioControlTls.minImageVersions.%s). %s.image is %s, which is older, or cannot be ordered against it: a main build against a release-line tag of the same train, or a main build of another patch level. %s. Set %s.image to a release that carries CGY-46071, or, for an image you know carries it, set drachtioControlTls.minImageVersions.%s to exactly its tag; a numbered tag must predate its train's cut, or that train's release line passes without the change (docs/017-drachtio-control-tls.md, Rollout)." $name $min $key $key $image (ternary "An older sbc-call-router ignores DRACHTIO_CONTROL_TRANSPORT and routes without ;transport=tls, so drachtio dials plain TCP: calls fail against TLS listeners, or the hop silently stays plaintext" "An older SBC ignores DRACHTIO_LISTEN_TLS_* and keeps a plaintext listener, so every call would fail" (eq $key "sbcCallRouter")) $key $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Refuses values that would weaken the hop while it is on. Takes the root context.
- DRACHTIO_OUTBOUND_TLS_VERIFY with a value drachtio reads as off (false, 0, no, off; any case,
  whitespace ignored, as vg-drachtio parseVerifyPeer), or from valueFrom, which the chart cannot judge,
  in drachtio.extraEnvVars or cognigyEnv (the drachtio container reads cognigy-env through envFrom).
  vg-drachtio refuses to start with it next to the CA file anyway; this fails at render time instead.
- Under the FedRAMP profile, an extraEnvVars entry named after one of the hop's variables: it renders
  after the chart's entry and would override the profile without a global.fedramp.* deviation (as for
  Redis and MySQL TLS).
*/}}
{{- define "vg.drachtioControlTls.validateEnv" -}}
{{- $root := . -}}
{{- $off := list "false" "0" "no" "off" -}}
{{- $verify := "DRACHTIO_OUTBOUND_TLS_VERIFY" -}}
{{- with .Values.drachtio.extraEnvVars -}}
{{- range include "vg.common.tplvalues.render" (dict "value" . "context" $root) | fromYamlArray -}}
{{- if and (kindIs "map" .) (eq (toString (get . "name")) $verify) -}}
{{- if or (hasKey . "valueFrom") (has (lower (nospace (toString (get . "value")))) $off) -}}
{{- fail (printf "drachtio.extraEnvVars cannot set %s to %s while drachtio control TLS is on: drachtio would stop verifying sbc-inbound and sbc-outbound. Remove the entry (docs/017-drachtio-control-tls.md)." $verify (ternary "a valueFrom" (printf "%q" (toString (get . "value"))) (hasKey . "valueFrom"))) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if hasKey (.Values.cognigyEnv | default dict) $verify -}}
{{- $v := toString (get .Values.cognigyEnv $verify) -}}
{{- if has (lower (nospace $v)) $off -}}
{{- fail (printf "cognigyEnv.%s cannot be %q while drachtio control TLS is on: drachtio in sbc-sip reads cognigy-env and would stop verifying sbc-inbound and sbc-outbound. Remove the key (docs/017-drachtio-control-tls.md)." $verify $v) -}}
{{- end -}}
{{- end -}}
{{- if include "vg.fedramp.enabled" . -}}
{{- $locked := dict
  "drachtio" (list "DRACHTIO_OUTBOUND_TLS_CA_FILE" "DRACHTIO_OUTBOUND_TLS_CERT_FILE" "DRACHTIO_OUTBOUND_TLS_KEY_FILE")
  "sbcInbound" (list "DRACHTIO_LISTEN_TLS_CERT_FILE" "DRACHTIO_LISTEN_TLS_KEY_FILE" "DRACHTIO_LISTEN_TLS_CA_FILE")
  "sbcOutbound" (list "DRACHTIO_LISTEN_TLS_CERT_FILE" "DRACHTIO_LISTEN_TLS_KEY_FILE" "DRACHTIO_LISTEN_TLS_CA_FILE")
  "sbcCallRouter" (list "DRACHTIO_CONTROL_TRANSPORT") -}}
{{- range $key := keys $locked | sortAlpha -}}
{{- $names := get $locked $key -}}
{{- with (index $root.Values $key).extraEnvVars -}}
{{- range include "vg.common.tplvalues.render" (dict "value" . "context" $root) | fromYamlArray -}}
{{- if and (kindIs "map" .) (has (toString (get . "name")) $names) -}}
{{- fail (printf "%s.extraEnvVars cannot set %s while global.fedramp.enabled is true: it would override the profile's drachtio control TLS. Use global.fedramp.drachtioControlTls instead (docs/017-drachtio-control-tls.md)." $key (get . "name")) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The two servers: the Secret suffix and the values key of each. The certificate carries the name
sbc-call-router routes to (<serviceName>:<ports.tcp>), which is the name drachtio dials and checks.
*/}}
{{- define "vg.drachtioControlTls.servers" -}}
{{- toJson (dict "sbc-inbound" "sbcInbound" "sbc-outbound" "sbcOutbound") -}}
{{- end -}}

{{/*
DNS names on a server certificate, as a YAML list: the service name sbc-call-router routes to (short,
which is what drachtio dials), `.<ns>`, `.<ns>.svc` and fully qualified. No IP addresses and no
localhost: nothing dials the SBCs' drachtio port by IP. Takes (dict "root" $ "service" <values key>).
*/}}
{{- define "vg.drachtioControlTls.dnsNames" -}}
{{- $ns := .root.Release.Namespace -}}
{{- $svc := (index .root.Values .service).serviceName -}}
{{- $domain := .root.Values.drachtioControlTls.clusterDomain | default "cluster.local" -}}
{{- toYaml (list $svc (printf "%s.%s" $svc $ns) (printf "%s.%s.svc" $svc $ns) (printf "%s.%s.svc.%s" $svc $ns $domain)) -}}
{{- end -}}

{{/*
Secret <name> in the release namespace as JSON, {} when there is none. `helm template` cannot reach the
reuse paths (lookup returns nothing there), so ci/render-tests/drachtio-control-tls.test.sh hands in
the Secrets of an earlier render as drachtioControlTls._lookup (Secrets by name); with it set, lookup is
not called. Test-only, not part of the values contract, and refused under the FedRAMP profile, as
redisHa.vgTls._lookup. Takes (dict "root" $ "name" <Secret name>).
*/}}
{{- define "vg.drachtioControlTls.lookupSecret" -}}
{{- $cfg := .root.Values.drachtioControlTls -}}
{{- if hasKey $cfg "_lookup" -}}
{{- if include "vg.fedramp.enabled" .root -}}
{{- fail "drachtioControlTls._lookup is a hook for ci/render-tests/drachtio-control-tls.test.sh and cannot be set while global.fedramp.enabled is true: the chart would stop reading its certificate Secrets from the cluster. Remove it from the values." -}}
{{- end -}}
{{- get $cfg._lookup .name | default dict | toJson -}}
{{- else -}}
{{- lookup "v1" "Secret" .root.Release.Namespace .name | toJson -}}
{{- end -}}
{{- end -}}

{{/*
Certificate material of the hop, as JSON with base64 values: ca.crt / ca.key (Secret <secretName>-ca,
never mounted), <server>.crt / <server>.key for sbc-inbound and sbc-outbound (Secrets
<secretName>-<server>), client.crt / client.key for drachtio in sbc-sip (Secret
<secretName>-client-sbc-sip; CN sbc-sip, no names: the servers check the CA, not a name).

Reuse before mint, as vg.redisTls.materialFor, so the CA is stable across upgrades:
- With the stored CA (<secretName>-ca with ca.crt and ca.key) the chart rebuilds it and reuses the
  certificates it signed. A certificate Secret that is missing, lacks tls.crt or tls.key, or carries a
  different ca.crt is signed anew (vg.redisTls.reusable: only the ca.crt text is compared, expiry is
  not checked).
- A server Secret carries a hash of its DNS names (annotation cognigy.com/dns-names-sha256). When the
  names change (namespace, serviceName, clusterDomain) that certificate is signed anew.
- Without the stored CA (first install, or a rotation that deleted it) the chart mints a new CA and all
  three certificates. The checksums then roll sbc-sip, sbc-inbound and sbc-outbound in one reconcile.
Refused rather than replaced:
- a certificate Secret (server or client) without ca.crt: that is what an external issuer produces,
  and overwriting it would swap the CA under the other end;
- a CA Secret that lacks ca.crt or ca.key: minting a new CA would silently re-sign every certificate
  and roll three workloads. Deleting the CA Secret is the way to rotate it (docs/017).

The result is cached in this render (drachtioControlTls._material), so the Secrets and the checksums
see the same certificates even in the render that mints them. Takes the root context.
*/}}
{{- define "vg.drachtioControlTls.material" -}}
{{- $cache := .Values.drachtioControlTls -}}
{{- if not (hasKey $cache "_material") -}}
{{- $root := . -}}
{{- $sn := $cache.secretName -}}
{{- $days := int $cache.certValidityDays -}}
{{- $m := dict -}}
{{- $ca := dict -}}
{{- $stored := include "vg.drachtioControlTls.lookupSecret" (dict "root" . "name" (printf "%s-ca" $sn)) | fromJson -}}
{{- if and $stored.data (not (and (index $stored.data "ca.crt") (index $stored.data "ca.key"))) -}}
{{- fail (printf "Secret %q already exists in namespace %q but lacks ca.crt or ca.key, so this chart cannot sign with it and refuses to replace it: a new CA would re-sign every certificate of the hop. Delete it to rotate the CA (docs/017-drachtio-control-tls.md, Rotation)." (printf "%s-ca" $sn) .Release.Namespace) -}}
{{- end -}}
{{- if and $stored.data (index $stored.data "ca.crt") (index $stored.data "ca.key") -}}
{{- $ca = buildCustomCert (index $stored.data "ca.crt") (index $stored.data "ca.key") -}}
{{- $_ := set $m "ca.crt" (index $stored.data "ca.crt") -}}
{{- $_ := set $m "ca.key" (index $stored.data "ca.key") -}}
{{- else -}}
{{- $ca = genCA "drachtio-control-ca" $days -}}
{{- $_ := set $m "ca.crt" (b64enc $ca.Cert) -}}
{{- $_ := set $m "ca.key" (b64enc $ca.Key) -}}
{{- end -}}
{{- range $server, $key := include "vg.drachtioControlTls.servers" . | fromJson -}}
{{- $name := printf "%s-%s" $sn $server -}}
{{- $s := include "vg.drachtioControlTls.lookupSecret" (dict "root" $root "name" $name) | fromJson -}}
{{- if and $s.data (not (index $s.data "ca.crt")) -}}
{{- fail (printf "Secret %q already exists in namespace %q but has no ca.crt, so this chart cannot reuse it and refuses to overwrite it. Delete it and let the chart mint its own certificates." $name $root.Release.Namespace) -}}
{{- end -}}
{{- $names := include "vg.drachtioControlTls.dnsNames" (dict "root" $root "service" $key) | fromYamlArray -}}
{{- /* Hash of the names themselves, not of toYaml's text, which a Helm upgrade could format differently. */ -}}
{{- $sum := join "," $names | sha256sum -}}
{{- $_ := set $m (printf "%s.dns-names-sha256" $server) $sum -}}
{{- if and (include "vg.redisTls.reusable" (dict "secret" $s "ca" (get $m "ca.crt"))) (eq (toString (dig "metadata" "annotations" "cognigy.com/dns-names-sha256" "" $s)) $sum) -}}
{{- $_ := set $m (printf "%s.crt" $server) (index $s.data "tls.crt") -}}
{{- $_ := set $m (printf "%s.key" $server) (index $s.data "tls.key") -}}
{{- else -}}
{{- $leaf := genSignedCert (printf "%s.%s.svc" (index $root.Values $key).serviceName $root.Release.Namespace) nil $names $days $ca -}}
{{- $_ := set $m (printf "%s.crt" $server) (b64enc $leaf.Cert) -}}
{{- $_ := set $m (printf "%s.key" $server) (b64enc $leaf.Key) -}}
{{- end -}}
{{- end -}}
{{- $clientName := printf "%s-client-sbc-sip" $sn -}}
{{- $client := include "vg.drachtioControlTls.lookupSecret" (dict "root" . "name" $clientName) | fromJson -}}
{{- if and $client.data (not (index $client.data "ca.crt")) -}}
{{- fail (printf "Secret %q already exists in namespace %q but has no ca.crt, so this chart cannot reuse it and refuses to overwrite it. Delete it and let the chart mint its own certificates." $clientName .Release.Namespace) -}}
{{- end -}}
{{- if include "vg.redisTls.reusable" (dict "secret" $client "ca" (get $m "ca.crt")) -}}
{{- $_ := set $m "client.crt" (index $client.data "tls.crt") -}}
{{- $_ := set $m "client.key" (index $client.data "tls.key") -}}
{{- else -}}
{{- $leaf := genSignedCert "sbc-sip" nil nil $days $ca -}}
{{- $_ := set $m "client.crt" (b64enc $leaf.Cert) -}}
{{- $_ := set $m "client.key" (b64enc $leaf.Key) -}}
{{- end -}}
{{- $_ := set $cache "_material" $m -}}
{{- end -}}
{{- get $cache "_material" | toJson -}}
{{- end -}}

{{/*
Pod annotation: a checksum of the pod's certificate and the CA, so a certificate the chart signs anew
restarts the pod, which reads them only at start. Takes (dict "root" $ "cert" <"client" or a server name>).
*/}}
{{- define "vg.drachtioControlTls.checksum" -}}
{{- $m := include "vg.drachtioControlTls.material" .root | fromJson -}}
checksum/drachtio-control-tls: {{ printf "%s%s" (get $m "ca.crt") (get $m (printf "%s.crt" .cert)) | sha256sum }}
{{- end -}}

{{/* drachtio in sbc-sip: the CA, and the client certificate it presents (vg-drachtio 1.3.28 or later). */}}
{{- define "vg.drachtioControlTls.clientEnv" -}}
- name: DRACHTIO_OUTBOUND_TLS_CA_FILE
  value: {{ include "vg.drachtioControlTls.mountPath" . }}/ca.crt
- name: DRACHTIO_OUTBOUND_TLS_CERT_FILE
  value: {{ include "vg.drachtioControlTls.mountPath" . }}/tls.crt
- name: DRACHTIO_OUTBOUND_TLS_KEY_FILE
  value: {{ include "vg.drachtioControlTls.mountPath" . }}/tls.key
{{- end -}}

{{/*
sbc-inbound and sbc-outbound: the server certificate, and the CA the client certificate must chain to.
Images with CGY-46071 listen with TLS and require a client certificate when all three are set.
*/}}
{{- define "vg.drachtioControlTls.serverEnv" -}}
- name: DRACHTIO_LISTEN_TLS_CERT_FILE
  value: {{ include "vg.drachtioControlTls.mountPath" . }}/tls.crt
- name: DRACHTIO_LISTEN_TLS_KEY_FILE
  value: {{ include "vg.drachtioControlTls.mountPath" . }}/tls.key
- name: DRACHTIO_LISTEN_TLS_CA_FILE
  value: {{ include "vg.drachtioControlTls.mountPath" . }}/ca.crt
{{- end -}}

{{- define "vg.drachtioControlTls.volumeMount" -}}
- name: drachtio-control-tls
  mountPath: {{ include "vg.drachtioControlTls.mountPath" . }}
  readOnly: true
{{- end -}}

{{/*
The pod's own certificate and the CA; never another pod's key or the CA key. 0440 and owned by root:
drachtio (uid/gid 1000) and the SBC images (uid/gid 1000) read them through fsGroup, which the chart
adds while they are mounted (vg.sbc.sip.podSecurityContext, vg.drachtioControlTls.podSecurityContext).
Takes (dict "root" $ "cert" <"client-sbc-sip" or a server name>).
*/}}
{{- define "vg.drachtioControlTls.volume" -}}
- name: drachtio-control-tls
  secret:
    secretName: {{ printf "%s-%s" .root.Values.drachtioControlTls.secretName .cert }}
    defaultMode: 0440
{{- end -}}

{{/*
Pod securityContext of sbc-inbound and sbc-outbound: the service's podSecurityContext, plus fsGroup 1000
while the certificates are mounted and none is set, so the image's uid 1000 can read the 0440 key.
Otherwise the value renders exactly as before. Empty when there is nothing to set.
Takes (dict "root" $ "value" <the service's podSecurityContext>).
*/}}
{{- define "vg.drachtioControlTls.podSecurityContext" -}}
{{- if include "vg.drachtioControlTls.mounted" .root -}}
{{- /* podSecurityContext may be a templated string: render and parse it into a map before adding to it. */ -}}
{{- $psc := fromYaml (include "vg.common.tplvalues.render" (dict "value" (.value | default dict) "context" .root)) | default dict -}}
{{- /* An explicit null counts as unset: it is how values unset a key. */ -}}
{{- if or (not (hasKey $psc "fsGroup")) (kindIs "invalid" (index $psc "fsGroup")) -}}
{{- $_ := set $psc "fsGroup" 1000 -}}
{{- end -}}
{{- toYaml $psc -}}
{{- else if .value -}}
{{- include "vg.common.tplvalues.render" (dict "value" .value "context" .root) -}}
{{- end -}}
{{- end -}}
