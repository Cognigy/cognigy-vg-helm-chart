# STACKIT Cloud Support

This document describes the STACKIT cloud provider support for deploying Cognigy Voice Gateway on **STACKIT Kubernetes Engine (SKE)**, an OpenStack-based infrastructure.

## Overview

STACKIT Cloud requires special handling because it lacks the cloud metadata services (like AWS IMDSv2 or Azure IMDS) that are typically used for external IP discovery. The Helm chart includes STACKIT-specific configurations that:

1. Query the Kubernetes API for node external IPs
2. Use OpenStack Cinder CSI for persistent storage
3. Provide an optional TLS toggle for SIP/WSS

## Quick Start

### Minimal Configuration

```yaml
cloud: "stackit"

drachtio:
  tls:
    enabled: true  # Set to false if TLS is not required
```

### Full Example

```yaml
cloud: "stackit"

# TLS Configuration (optional - enabled by default)
drachtio:
  tls:
    enabled: true
    certFile: /etc/letsencrypt/tls.crt
    keyFile: /etc/letsencrypt/tls.key
    chainFile: /etc/letsencrypt/tls.crt

# Storage classes automatically use OpenStack Cinder CSI
# Default values shown below - override only if needed
stackit:
  influxdb:
    storageClassName: "influxdb"
    provisionerName: "cinder.csi.openstack.org"
    pdType: "storage_premium_perf6"
  mysql:
    storageClassName: "mysql"
    provisionerName: "cinder.csi.openstack.org"
    pdType: "storage_premium_perf6"
  postgresql:
    storageClassName: "postgres"
    provisionerName: "cinder.csi.openstack.org"
    pdType: "storage_premium_perf6"
```

## Architecture

### External IP Detection

On STACKIT, external IP detection works differently than on AWS/Azure/GCP:

```
┌─────────────────────────────────────────────────────────────────┐
│                         SBC-SIP Pod                             │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ InitContainer: stackit-external-ip-detector              │   │
│  │                                                          │   │
│  │  1. Query K8s API for node's ExternalIP                  │   │
│  │  2. Write to /etc/nodeip/external_ip.sh                  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Container: sbc-sip-sidecar                               │   │
│  │                                                          │   │
│  │  1. entrypoint-wrapper.sh sources external_ip.sh         │   │
│  │  2. Sets SIP_EXTERNAL_IP environment variable            │   │
│  │  3. App detects CLOUD=stackit, uses explicit IP          │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### RTP Engine Configuration

For RTP nodes, STACKIT uses explicit IPv4 configuration to prevent IPv6 auto-detection issues:

```
┌─────────────────────────────────────────────────────────────────┐
│                         SBC-RTP Pod                             │
├─────────────────────────────────────────────────────────────────┤
│  Container: rtp-engine                                          │
│                                                                 │
│  STACKIT-specific entrypoint:                                   │
│  1. Extract IPv4 from eth0 (ignores IPv6)                       │
│  2. Read RTP_EXTERNAL_IP from environment                       │
│  3. Set PRIVATE_INTERFACE and PUBLIC_INTERFACE explicitly       │
│  4. Start rtpengine with correct configuration                  │
└─────────────────────────────────────────────────────────────────┘
```

## Components Created for STACKIT

When `cloud: "stackit"` is set, the following additional resources are created:

| Resource                                             | Purpose                                   |
| ---------------------------------------------------- | ----------------------------------------- |
| `ServiceAccount/sbc-sip-node-reader`                 | Allows InitContainer to query K8s API     |
| `ClusterRole/{namespace}-node-reader`                | Grants `get`, `list` permissions on nodes |
| `ClusterRoleBinding/{namespace}-sbc-sip-node-reader` | Binds role to service account             |
| `ConfigMap/sbc-sip-sidecar-patch`                    | Entrypoint wrapper script                 |
| `StorageClass/influxdb`                              | OpenStack Cinder storage for InfluxDB     |
| `StorageClass/mysql`                                 | OpenStack Cinder storage for MySQL        |
| `StorageClass/postgres`                              | OpenStack Cinder storage for PostgreSQL   |

## Key Differences from AWS/Azure/GCP

| Aspect                    | AWS/Azure/GCP                         | STACKIT                               |
| ------------------------- | ------------------------------------- | ------------------------------------- |
| **External IP Detection** | Cloud metadata service (IMDSv2, IMDS) | Kubernetes Node API via InitContainer |
| **Drachtio Flag**         | Uses `--cloud-deployment`             | No `--cloud-deployment` flag          |
| **RTP Engine**            | Auto-detection                        | Manual IPv4-only configuration        |
| **Storage Provisioner**   | Cloud-native CSI                      | OpenStack Cinder CSI                  |
| **TLS**                   | Always enabled                        | Optional via `drachtio.tls.enabled`   |

## TLS Configuration

TLS support is optional and controlled by `drachtio.tls.enabled`:

### TLS Enabled (Default)

```yaml
drachtio:
  tls:
    enabled: true
    certFile: /etc/letsencrypt/tls.crt
    keyFile: /etc/letsencrypt/tls.key
    chainFile: /etc/letsencrypt/tls.crt
```

This enables:
- SIPS (SIP over TLS) on port 5061
- WSS (WebSocket Secure) on port 8443
- TLS certificate volume mounts

### TLS Disabled

```yaml
drachtio:
  tls:
    enabled: false
```

This disables:
- TLS-related environment variables
- TLS certificate volume mounts
- SIPS and WSS ports

> **Note**: The TLS toggle applies to all cloud providers, not just STACKIT.

## Environment Variables

### SIP Nodes

| Variable          | Source        | Description                     |
| ----------------- | ------------- | ------------------------------- |
| `CLOUD`           | Helm values   | Set to `"stackit"`              |
| `SIP_EXTERNAL_IP` | InitContainer | Node's external IP from K8s API |

### RTP Nodes

| Variable          | Source           | Description                 |
| ----------------- | ---------------- | --------------------------- |
| `CLOUD`           | Helm values      | Set to `"stackit"`          |
| `RTP_EXTERNAL_IP` | Must be provided | External IP for RTP traffic |

## Prerequisites

1. **STACKIT Kubernetes Engine (SKE)** cluster with:
   - Kubernetes 1.28+
   - OpenStack Cinder CSI driver installed
   - Nodes with ExternalIP assigned

2. **Node Labels** (same as other clouds):
   ```yaml
   # SIP nodes
   voip-environment: "edge"
   
   # RTP nodes  
   media-environment: "edge"
   ```

3. **Node Taints** (same as other clouds):
   ```yaml
   # SIP nodes
   - key: "voip-edge"
     effect: "NoSchedule"
   
   # RTP nodes
   - key: "media-edge"
     effect: "NoSchedule"
   ```

## Troubleshooting

### External IP Not Detected

Check the InitContainer logs:

```bash
kubectl logs <sbc-sip-pod> -c stackit-external-ip-detector
```

Expected output:
```
Node: <node-name>, External IP: <external-ip>
```

### Verify RBAC Permissions

```bash
kubectl auth can-i get nodes --as=system:serviceaccount:<namespace>:sbc-sip-node-reader
```

### Check SBC Public IP Registration

In sbc-sip-sidecar logs, look for:

```
sbc public ip addresses (STACKIT override): {"udp":"<ip>:5060","tls":"<ip>:5061"}
```

### RTP IPv6 Issues

If RTP has connectivity issues, verify the entrypoint script output:

```bash
kubectl logs <sbc-rtp-pod> -c rtp-engine | grep -A5 "Configuring RTP engine"
```

## Migration Guide

### From Another Cloud Provider

1. Update `cloud` value:
   ```yaml
   cloud: "stackit"
   ```

2. Remove cloud-specific configurations (aws, azure, gcp sections are ignored)

3. Ensure storage classes match STACKIT provisioner

4. Set `drachtio.tls.enabled` based on your requirements

### Upgrading from Chart Without TLS Toggle

Add to maintain existing behavior:

```yaml
drachtio:
  tls:
    enabled: true
```

## Files Reference

| File                                              | Description                |
| ------------------------------------------------- | -------------------------- |
| `templates/sbc-sip/stackit-rbac.yaml`             | RBAC for node API access   |
| `templates/sbc-sip/configmap-sidecar-patch.yaml`  | Sidecar entrypoint wrapper |
| `templates/stackit/influxdb/storage-class.yaml`   | InfluxDB storage class     |
| `templates/stackit/mysql/storage-class.yaml`      | MySQL storage class        |
| `templates/stackit/postgresql/storage-class.yaml` | PostgreSQL storage class   |

## Compatibility

- **Chart Version**: 2025.21.0+
- **Kubernetes**: 1.28+
- **STACKIT SKE**: Supported
- **Backward Compatible**: Yes - existing AWS/Azure/GCP deployments unaffected
