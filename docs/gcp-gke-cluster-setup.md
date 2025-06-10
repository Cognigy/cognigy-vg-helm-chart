# (DEPRECATED) GCP GKE Cluster Setup
## WARNING: The installation guide below is deprecated and is not actively maintained!

In order to install Cognigy VoiceGateway (VG) product, you need to provision a dedicated GCP GKE cluster. 
Please, create a GKE Cluster in accordance with [Official GKE Documentation](https://cloud.google.com/kubernetes-engine/docs/concepts/types-of-clusters). 

You can use a tool of your choice for cluster provisioning, but in the simplest case you can provision a GKE cluster via [Google Cloud Console](https://console.cloud.google.com/), use `Standard` Cluster mode to create the cluster via Google Cloud Console.

### Installation Tools
For the installation you will need following tools installed locally on Linux or MacOS client. Windows clients are not supported by this installation guide: 
- [gcloud](https://cloud.google.com/sdk/docs/install-sdk) utility
- `gke-gcloud-auth-plugin` and `beta` plugins, install the plugins with:
    ```bash
    gcloud components install gke-gcloud-auth-plugin
    gcloud components install beta
    ```

## GCP GKE Cluster Setup & Requirements
GKE Cluster for VG operation must meet following requirements, set them during cluster creation accordingly:

### Cluster basics
1. `Location Type`: `Regional` , select a region of your choice
2. `Control plane version`: `Static version`, use `v1.23.x` at the moment

### Cluster Networking 
Set following parameters, you can leave the rest with default values:
1. `Network access`: `Public cluster`. The Nodes in the cluster must have public IPs for SIP and RTP Nodes to be reachable from external SIP trunk providers.
2. Advanced networking options: set `Enable VPC-native traffic routing (uses alias IP)` and `Automatically create secondary ranges` options
3. Disable `Enable HTTP load balancing` option. We use [Treafik](https://traefik.io/) Ingress controller shipped with VG Helm Chart.

### Node Pools
The cluster requires 3 node pools to be created: `default-pool`, `media-nodes` and `voip-nodes`. All 3 node pools must have following common settings:
* `Machine Series`: `E2`
* `Machine Type`: `e2-standard-4`
* `Boot disk Type`: `Standard Persistent Disk`
* `Boot disk size (GB)`: `100`
* `Automatically upgrade nodes to next available version` option must be disabled

Additionally, every node must have following specific settings: 

#### default-pool
Default node pool for VG common workloads, at least 6 `e2-standard-4` instances distributed across 3 availability zones are required:
* Name: `default-pool`
* Number of nodes (per zone): `2`

#### voip-nodes
Node pool for SIP protocol handling, at least 3 `e2-standard-4` instances distributed across 3 availability zones are required. Nodes must have public IPs assigned to each instance for direct external access. To isolate SIP workloads, the node pool must have the following label and taint applied:
* Name: `voip-nodes`
* Number of nodes (per zone): `1`
* Networking:
  * Network Tags: `voip-nodes`
* Metadata: 
  * Kubernetes labels:
    ```yaml
    `key`: `voip-environment`
    `value`: `edge`
    ```
  * Node taints: 
    ```yaml
    `key`: `voip-edge`
    `value`: `true`
    `effect`: `NO_SCHEDULE`
    ```

#### media-nodes
Node pool for RTP protocol handling, at least 3 `e2-standard-4` instances distributed across 3 availability zones are required. Nodes must have public IPs assigned to each instance for direct external access. To isolate RTP workloads, the node pool must have the following label and taint applied:
* Name: `media-nodes`
* Number of nodes (per zone): `1`
* Networking:
  * Network Tags: `media-nodes`
* Metadata:
   * Kubernetes labels:
     ```yaml
     `key`: `media-environment`
     `value`: `edge`
     ```
   * Node taints:
     ```yaml
     `key`: `media-edge`
     `value`: `true`
     `effect`: `NO_SCHEDULE`
     ```

## kubeIP Deployment 
As required by majority of SIP Trunk providers, SIP nodes must have public static IPs. In GKE, public IPs attached to the nodes are volatile and change during node pools and cluster upgrades. To overcome this limitation we use [kubeIP](https://github.com/doitintl/kubeip) deployment to keep static IPs attached to both `voip-nodes` and ` media-nodes` node pools. 

Deploy kubeIP into the cluster following the steps below, refer to official [kubeIP installation documentation](https://github.com/doitintl/kubeip/blob/master/README.md) for further details: 
1. Clone the project:
```bash
git clone git@github.com:doitintl/kubeip.git
cd kubeip
```
2. Set environment variables, replace `<...>` blockers with your values:
```bash
gcloud config set project <YOUR_PROJECT_ID>
export GCP_REGION=<YOUR_GCP_REGION>
export GCP_ZONE=<YOUR_GCP_REGION>
export GKE_CLUSTER_NAME=<YOUR_CLUSTER_NAME>
export PROJECT_ID=$(gcloud config list --format 'value(core.project)')
export KUBEIP_NODEPOOL=voip-nodes
export KUBEIP_SELF_NODEPOOL=default-pool
export KUBEIP_ADDITIONALNODEPOOLS=media-nodes
export KUBEIP_LABELKEY=kubeip
```
3. Obtain your GKE cluster credentials:
```bash
gcloud container clusters get-credentials $GKE_CLUSTER_NAME \
    --region $GCP_REGION \
    --project $PROJECT_ID
```
4. Create a Service Account for kubeIP:
```bash
gcloud iam service-accounts create kubeip-service-account --display-name "kubeIP"
```
5. Create and attach a custom kubeIP role to the service account:
```bash
gcloud iam roles create kubeip --project $PROJECT_ID --file roles.yaml
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member=serviceAccount:kubeip-service-account@$PROJECT_ID.iam.gserviceaccount.com \
    --role=projects/$PROJECT_ID/roles/kubeip \
    --condition=None
```
6. Generate the Key for kubeIP service account:
```bash
gcloud iam service-accounts keys create key.json \
    --iam-account kubeip-service-account@$PROJECT_ID.iam.gserviceaccount.com
```
7. Create Kubernetes Secret and ClusteRoleBinding for kubeIP:
```bash
kubectl create secret generic kubeip-key --from-file=key.json -n kube-system
kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole cluster-admin --user `gcloud config list --format 'value(core.account)'`
```
8. Create static reserved IP Addresses for `voip-nodes` and `media-nodes`. Set number of IPs equal to nodes in `voip-nodes` and `media-nodes` respectively (3 by default for each node pools):
```bash
# IPs for voip-nodes
for i in {1..3}; do gcloud compute addresses create voip-nodes-ip$i --project=$PROJECT_ID --region=$GCP_REGION; done

# IPs for media-nodes
for i in {1..3}; do gcloud compute addresses create media-nodes-ip$i --project=$PROJECT_ID --region=$GCP_REGION; done
```
9. Add labels to reserved IP addresses. We assign unique value per cluster here:

```bash
# IPs for voip-nodes
for i in {1..3}; do gcloud beta compute addresses update voip-nodes-ip$i --update-labels kubeip=$GKE_CLUSTER_NAME --region $GCP_REGION; done

# IPs for media-nodes
for i in {1..3}; do gcloud beta compute addresses update media-nodes-ip$i --update-labels $KUBEIP_LABELKEY-node-pool=media-nodes,kubeip=$GKE_CLUSTER_NAME --region $GCP_REGION; done
```
10. Patch `kubeip-configmap.yaml` ConfigMap with env variables: 
```bash
# on Linux
sed -i -e "/^\([[:space:]]*KUBEIP_LABELVALUE: \).*/s//\1\"$GKE_CLUSTER_NAME\"/" \
       -e "/^\([[:space:]]*KUBEIP_NODEPOOL: \).*/s//\1\"$KUBEIP_NODEPOOL\"/" \
       -e "/^\([[:space:]]*KUBEIP_LABELKEY: \).*/s//\1\"$KUBEIP_LABELKEY\"/" \
       -e "/^\([[:space:]]*KUBEIP_ADDITIONALNODEPOOLS: \).*/s//\1\"$KUBEIP_ADDITIONALNODEPOOLS\"/" deploy/kubeip-configmap.yaml

# on MacOS
sed -i '' -e "/^\([[:space:]]*KUBEIP_LABELVALUE: \).*/s//\1\"$GKE_CLUSTER_NAME\"/" \
          -e "/^\([[:space:]]*KUBEIP_NODEPOOL: \).*/s//\1\"$KUBEIP_NODEPOOL\"/" \
          -e "/^\([[:space:]]*KUBEIP_LABELKEY: \).*/s//\1\"$KUBEIP_LABELKEY\"/" \
          -e "/^\([[:space:]]*KUBEIP_ADDITIONALNODEPOOLS: \).*/s//\1\"$KUBEIP_ADDITIONALNODEPOOLS\"/" deploy/kubeip-configmap.yaml
```
Make sure `deploy/kubeip-configmap.yaml` file contains the correct values:
* The KUBEIP_LABELVALUE: must be your GKE cluster name
* The KUBEIP_NODEPOOL: must be equal to "voip-nodes"
* The KUBEIP_ADDITIONALNODEPOOLS: must be equal to "media-nodes"
* The KUBEIP_FORCEASSIGNMENT: controls whether kubeIP should assign static IPs to existing nodes in the node-pool and defaults to `true`
11. Patch `deploy/kubeip-deployment.yaml` with the env variable:
```bash
# on Linux
sed -i -e  "s/pool-kubip/$KUBEIP_SELF_NODEPOOL/g" deploy/kubeip-deployment.yaml
# on MacOS
sed -i '' -e "s/pool-kubip/$KUBEIP_SELF_NODEPOOL/g" deploy/kubeip-deployment.yaml
```
Make sure `deploy/kubeip-deployment.yaml` file contains the correct value:
* `nodeSelector.cloud.google.com/gke-nodepool`: `default-pool`
12. Deploy kubeIP by running:
```bash
kubectl apply -f deploy/.
```
13. Check the deployment is up and running:
```bash
kubectl get -n=kube-system deployment kubeip  
```
14. Check the static IPs are assigned to the `voip-nodes`: 
```bash
kubectl get nodes -l=kubip_assigned -o wide
```
Check if these static IPs correspond to `voip-nodes-ip` static IPs created in the GCP Project under `VPC Network -> IP addresses`
15. Note down these static IPs of the `voip_nodes`, you will need them to configure SBC SIP Nodes in your SIP Trunk provider. 


## Network Firewall Rules

In order for SIP and RTP protocols to operate properly, additional firewall rules must be attached to `voip-nodes` and `media-nodes` node pools
allowing communication for both protocols. In case you need to limit external access to a particular SIP trunk provider(s), replace `0.0.0.0/0` IP range below according to your requirements.

#### Firewall Rules for VOIP-Nodes (SIP)
| Type     | Protocol | Port range  | Source       | Description           |
|----------|----------|-------------|--------------|-----------------------|
| inbound  | TCP      | 5060 - 5061 | `0.0.0.0/0`  | Allow SIP TCP traffic |
| inbound  | UDP      | 5060 - 5061 | `0.0.0.0/0`  | Allow SIP UDP traffic |
| inbound  | TCP      | 8443        | `0.0.0.0/0`  | Allow WSS SIP traffic |

#### Firewall Rules for Media-Nodes (RTP)
| Type     | Protocol | Port range     | Source       | Description       |
|----------|----------|----------------|--------------|-------------------|
| inbound  | UDP      | 40000 - 60000  | `0.0.0.0/0`  | Allow RTP traffic |


To create the aforementioned firewall rules execute following commands (replace `--network` and `--source-ranges` parameters according to your installation):
```bash
gcloud compute firewall-rules create allow-sip-ingress-traffic \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --source-ranges=0.0.0.0/0 \
    --action=ALLOW \
    --rules=tcp:5060,tcp:5061,tcp:8443,udp:5060,udp:5061 \
    --target-tags=voip-nodes

gcloud compute firewall-rules create allow-rtp-ingress-traffic \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --source-ranges=0.0.0.0/0 \
    --action=ALLOW \
    --rules=udp:40000-60000 \
    --target-tags=media-nodes
```