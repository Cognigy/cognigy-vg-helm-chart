# TLS for the call-router hop

sbc-sip's drachtio sends every inbound INVITE to sbc-call-router over HTTPS, and trusts only the chart's CA for it.
The request carries the full SIP message, SDP included. sbc-sip runs on the host network, outside the mesh, so the
mesh cannot encrypt this hop: it encrypts itself. This is option A of the in-cluster encryption work for FedRAMP
SC-8, work map item A9 (CGY-47751; plan 015 REQ-FIPSTRANSPORT-036). The same approach for Redis and MySQL is in
docs/011-redis-tls.md and docs/012-mysql-tls.md.

## How it works

| Side | With TLS on |
|---|---|
| sbc-call-router | Serves HTTPS on `sbcCallRouter.port` (3000) with the chart's certificate (`HTTP_TLS_CERT_FILE`, `HTTP_TLS_KEY_FILE`). No plaintext listener. |
| drachtio (sbc-sip) | `<request-handler ... ca-file="/etc/call-router-tls/ca.crt">https://drachtio:<credential>@sbc-call-router:3000</request-handler>` (the credential from Secret `vg-call-router-credentials`, CGY-43876). curl checks the chain against that CA only, not the system store, and the host name. |

The port serves HTTPS only, so one switch covers both ends. The only client of the port is drachtio; the health and
metrics ports are separate and stay plain HTTP.

## Values

```yaml
sbcCallRouter:
  port: 3000
  tls:
    enabled: false                 # HTTPS on port, and drachtio's request-handler on https with ca-file
    secretName: sbc-call-router-tls
    certValidityDays: 3650
    drachtioMinVersion: "1.3.25"   # older drachtio.image release tags fail the render while TLS is on
    minVersion: "2026.24.0-91"     # older sbcCallRouter.image release tags fail the render while TLS is on
```

With the FedRAMP profile on (`global.fedramp.enabled`), `global.fedramp.callRouterTls` (`true`) decides instead
and `sbcCallRouter.tls.enabled` is ignored (docs/009-fedramp-profile.md). Under the profile an
`sbcCallRouter.extraEnvVars` entry named `HTTP_TLS_CERT_FILE` or `HTTP_TLS_KEY_FILE` fails the render.

## Certificate

Minted once and reused, like the MySQL one (`vg.callRouterTls.material` in `templates/_call-router-tls.tpl`,
`templates/sbc-call-router/tls-secret.yaml`): RSA 2048, SHA-256, Secret `sbc-call-router-tls` with `tls.crt`,
`tls.key`, `ca.crt`. An existing Secret without `ca.crt` is refused rather than overwritten. The Secret carries
`helm.sh/resource-policy: keep`, so an uninstall or turning TLS off leaves it, and a later enable reuses the same CA.
`helm template` and `--dry-run` mint a new pair on every render; that is a render artefact, not a rotation.

DNS names: `sbc-call-router`, `.<ns>`, `.<ns>.svc` and `.<ns>.svc.cluster.local`. drachtio dials the short name.
No IP addresses and no `localhost`.

| Mounted into | What | Mode |
|---|---|---|
| sbc-call-router, `/etc/call-router-tls` | `tls.crt`, `tls.key` | 0440; the pod gets `fsGroup: 1000` (the `node` user) unless `sbcCallRouter.podSecurityContext` sets one |
| sbc-sip drachtio, `/etc/call-router-tls` | `ca.crt` only | default |

**Rotation.** Delete the Secret and force a reconcile (a plain `flux reconcile` does not upgrade an unchanged
release; see docs/012-mysql-tls.md). The chart mints a new CA and certificate. sbc-call-router rolls through
`checksum/call-router-tls`, sbc-sip through `checksum/call-router-tls-ca`. Until both have restarted, INVITEs between
an old and a new pod fail the handshake. Every roll of sbc-sip drops the calls on the node being replaced.

## Rollout

- **Inbound calls fail while it switches.** Turning TLS on or off changes both ends, and they restart separately
  (sbc-call-router is a Deployment, sbc-sip a StatefulSet or DaemonSet). Until both have restarted, drachtio and the
  call-router disagree and new inbound INVITEs are refused. Switch it before go-live or in a maintenance window.
- **Images first.** Both images must support it before the chart turns it on. An older call-router ignores the
  variables and serves plain HTTP; an older drachtio ignores `ca-file` and checks against the system store. Either
  way every inbound INVITE fails (closed, never plaintext). It needs vg-drachtio 1.3.25 or newer (the request-handler
  `ca-file` attribute, vg-drachtio#65) and vg-sbc-call-router 2026.24.0-91 or newer (`HTTP_TLS_CERT_FILE`,
  vg-sbc-call-router#74). The chart enforces both while TLS is on: an older release tag in `drachtio.image` or
  `sbcCallRouter.image` fails the render. The call-router minimum is a preview build, and the check keeps the
  `-NN` suffix, since the sprint's earlier previews share `2026.24.0` and predate the change. Branch builds are not
  judged. For a build you know carries the change, set `drachtioMinVersion` or `minVersion` to `""`.
- **`lookup` is required**, as for Redis and MySQL: a tool that renders without cluster access would mint a new CA on
  every sync.

## TLS parameters

TLS 1.2 and 1.3, ECDHE with AES-GCM only (NIST SP 800-52r2), the list redis-ha and MySQL serve, and the key-exchange
groups P-256 and P-384. OpenSSL's default list also offers ChaCha20-Poly1305 and X25519, which are not FIPS-approved.
Unlike redis-ha and MySQL, the chart does not render these: the call-router pins them in code
(`lib/server.ts` in vg-sbc-call-router, CGY-47751) and offers no setting to loosen them. drachtio requires TLS 1.2 or
later on every https request-handler and follows redirects to https only.

## Verify

Run the checks from drachtio's container: the NetworkPolicy admits 3000 only from the host network, and the image
has curl. `method=options` only asks for a route; nothing is called.

```bash
# HTTPS against the chart's CA answers with a route
kubectl -n <ns> exec sbc-sip-0 -c drachtio -- curl -sS --cacert /etc/call-router-tls/ca.crt \
  -X POST 'https://sbc-call-router:3000/?method=options' -w '\n%{http_code}\n'

# Plain HTTP is refused
kubectl -n <ns> exec sbc-sip-0 -c drachtio -- curl -sS -X POST 'http://sbc-call-router:3000/?method=options'

# drachtio uses it: the route line at start, and no "failed:" line per INVITE
kubectl -n <ns> logs sbc-sip-0 -c drachtio | grep -E "Route for outbound connection|http request for transaction"
```

At start drachtio logs `http-url: https://sbc-call-router:3000, cert will be verified against /etc/call-router-tls/ca.crt`.
A handshake that fails logs `http request for transaction <id> failed:` with curl's reason, for example
`unable to get local issuer certificate` (another CA) or `wrong version number` (the call-router serves plain HTTP).

## Not covered yet

- **Mesh exception** (work map X4): under STRICT mTLS a `PeerAuthentication` must accept non-mesh traffic on 3000.
  The stage-3 NetworkPolicy already admits 3000 only from the host-network peers (docs/014-network-policy.md);
  there are no client certificates on this hop.
- **FIPS** (X1, X2): drachtio's libcurl and the call-router's Node must run a FIPS 140-3 validated module for the hop
  to count under SC-8(1).
- **Key generation** (X10): the chart mints the keys with Sprig in Helm's Go crypto, not in a validated module.
