# Azure AKS Cluster Setup

This article is only for customers who have an on-premises Cognigy.AI installation.

In addition to Cognigy.AI, you can install the VoiceGateway (VG) product. To do that, you need to provide a dedicated Azure AKS cluster. Create an AKS Cluster following [Official AKS Documentation](https://learn.microsoft.com/en-us/azure/aks/).

This article provides an example of using the [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) to set up an AKS cluster and all its dependencies. However, you may use your preferred tool for cluster provisioning.

## Installation Tools
Install the [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) on your local environment. In this article, all commands are tested on macOS.

## Prerequisites 
Make sure you have Azure CLI configured on your local environment and have the minimum following quota available in the region of your choice:

- Minimum 40x Standard DS Family vCPUs
- 6x Static Public IP Addresses

## How to set up Azure AKS Cluster
AKS Cluster for VG operation must meet following requirements, set them during cluster creation accordingly:

### Cluster Basics

1. Set the following environment variables for provisioning an AKS cluster and its dependencies. Set the name of the variable as per your choice.
```bash
# Name of the resource group
export resourceGroup=cognigy-vg-aks
# Azure region
export location=westeurope
# Name of the AKS cluster
export clusterName=cognigy-vg
# tags for all the resources
export tags="environment=cognigy-vg"
```

2. Create a new resource group using the `az group create` command.
```bash
az group create \
  --name $resourceGroup \
  --location $location \
  --tags $tags
```

3. Create a new virtual network in the newly created resource group. Change the values if you need to do virtual network peering. Otherwise, leave the default value.
```bash
export vnetName=${clusterName}-vnet
export vnetAddressPrefix=10.0.0.0/16
export subnetName=${clusterName}-snet
export subnetAddressPrefix=10.0.0.0/18

az network vnet create \
  --name $vnetName \
  --resource-group $resourceGroup \
  --address-prefixes $vnetAddressPrefix \
  --subnet-name $subnetName \
  --subnet-prefixes $subnetAddressPrefix \
  --tags $tags
```

4. Create a static public IP address. It will be used as the load balancer outbound IP address.
```bash
export egress01PublicIPName=${clusterName}-aks-egress-01

az network public-ip create \
  --resource-group $resourceGroup \
  --name $egress01PublicIPName \
  --allocation-method Static \
  --sku Standard \
  --version IPv4 \
  --location $location \
  --zone {1,2,3} \
  --tags $tags
```

5. Create a public IP prefix of length 31 (CIDR). These IPs will be assigned to the VoIP node pool.

> Note: The number of IPs in this IP prefix must equal the number of nodes in the VoIP node pool. Due to the design of Azure, static public IPs can be booked in CIRD format only. Keep this in mind while deciding the number of nodes in the VoIP node pool, as it may affect the service if the number of nodes and the number of static public IPs in this IP prefix differ.

```bash
export sipIngressPublicIPPrefix=${clusterName}-aks-sip-ingress

az network public-ip prefix create \
  --resource-group $resourceGroup \
  --name $sipIngressPublicIPPrefix \
  --version IPv4 \
  --length 31 \
  --location $location \
  --zone {1,2,3} \
  --tags $tags
```

6. Create a public IP prefix of length 31 (CIDR). These IPs will be assigned to the media node pool.
```bash
export rtpIngressPublicIPPrefix=${clusterName}-aks-media-ingress

az network public-ip prefix create \
  --resource-group $resourceGroup \
  --name $rtpIngressPublicIPPrefix \
  --version IPv4 \
  --length 31 \
  --location $location \
  --zone {1,2,3} \
  --tags $tags
```

### Provision an AKS cluster
To create an AKS cluster, use the `az aks create command`. The following commands create a cluster named `cognigy-vg` with six nodes in the default node pool and enable a system-assigned managed identity. The default node pool is for the common workloads.

> Note: It is mandatory to use Azure CNI.

```bash
export kubernetesVersion=1.23.12
export defaultNodepoolName=defaultpool
export defaultNodepoolNodeCount=6
export vmSize=Standard_D4s_v4
export serviceCidr="10.252.0.0/14"
export dnsServiceIp="10.252.0.10"
export dockerBridgeAddress="172.17.0.1/16"
export vnetSubnetId=$(az network vnet subnet show --resource-group $resourceGroup --name $subnetName --vnet-name $vnetName --query 'id' -o tsv)
export loadBalancerOutboudIpId=$(az network public-ip show --resource-group $resourceGroup --name $egress01PublicIPName --query 'id' -o tsv)

az aks create \
  --name $clusterName \
  --resource-group $resourceGroup \
  --location $location \
  --kubernetes-version $kubernetesVersion \
  --dns-name-prefix $clusterName \
  --uptime-sla \
  --nodepool-name $defaultNodepoolName \
  --node-count $defaultNodepoolNodeCount \
  --node-vm-size $vmSize \
  --vnet-subnet-id "${vnetSubnetId}" \
  --zones {1,2,3} \
  --enable-azure-rbac \
  --load-balancer-sku standard \
  --network-plugin azure \
  --service-cidr $serviceCIRD \
  --dns-service-ip $dnsServiceIp \
  --docker-bridge-address $dockerBridgeAddress \
  --load-balancer-outbound-ips "${loadBalancerOutboudIpId}" \
  --enable-managed-identity \
  --enable-aad \
  --tags $tags
```

### VoIP Node Pool
Node pool for SIP protocol handling, a minimum of two instances distributed across availability zones are required. Each node must have a static public IP that cannot be changed even during cluster updates or node failure. This IP is assigned for direct external access. To isolate SIP workloads, the node pool must have the below-defined label and taint applied:

```bash
export voipNodepoolName=voip
export sipIngressPublicIPPrefixID=$(az network public-ip prefix show --name ${sipIngressPublicIPPrefix} --resource-group ${resourceGroup} --query 'id' -o tsv)

az aks nodepool add \
  --resource-group $resourceGroup \
  --cluster-name $clusterName \
  --name $voipNodepoolName \
  --node-count 2 \
  --enable-node-public-ip \
  --kubernetes-version $kubernetesVersion \
  --labels voip-environment=edge\
  --node-taints voip-edge=true:NoSchedule \
  --node-public-ip-prefix-id "${sipIngressPublicIPPrefixID}" \
  --node-vm-size $vmSize \
  --vnet-subnet-id "${vnetSubnetId}" \
  --zones {1,2,3} \
  --tags $tags
```

### Media Node Pool
Node pool for RTP protocol handling, a minimum of two instances distributed across availability zones are required. Each node must have a static public IP assigned for direct external access. To isolate RTP workloads, the node pool must have the following label and taint applied:

```bash
export mediaNodepoolName=media
export rtpIngressPublicIPPrefixID=$(az network public-ip prefix show --name ${rtpIngressPublicIPPrefix} --resource-group ${resourceGroup} --query 'id' -o tsv)

az aks nodepool add \
  --resource-group $resourceGroup \
  --cluster-name $clusterName \
  --name $mediaNodepoolName \
  --node-count 2 \
  --enable-node-public-ip \
  --kubernetes-version $kubernetesVersion \
  --labels media-environment=edge\
  --node-taints media-edge=true:NoSchedule \
  --node-public-ip-prefix-id "${rtpIngressPublicIPPrefixID}" \
  --node-vm-size $vmSize \
  --vnet-subnet-id "${vnetSubnetId}" \
  --zones {1,2,3} \
  --tags $tags
```

### Network Firewall Rules

By default, AKS creates a network security group (NSG) with some default rules. For SIP and RTP protocols to operate properly, additional firewall rules must be attached to `voip` and `media` node pools allowing communication for both protocols. If you need to limit external access to a particular SIP trunk provider(s), replace `"*"` below with the IP range according to your requirements.

#### Firewall Rules for VOIP-Nodes (SIP)
| Type     | Protocol | Port range  | Source       | Description           |
|----------|----------|-------------|--------------|-----------------------|
| inbound  | TCP      | 5060 - 5061 | `"*"` (All)  | Allow SIP TCP traffic  |
| inbound  | UDP      | 5060 - 5061 | `"*"` (All)  | Allow SIP UDP traffic  |
| inbound  | TCP      | 8443        | `"*"` (All)  | Allow WSS SIP traffic  |

#### Firewall Rules for Media-Nodes (RTP)
| Type     | Protocol | Port range     | Source       | Description       |
|----------|----------|----------------|--------------|-------------------|
| inbound  | UDP      | 40000 - 60000  | `"*"` (All)  | Allow RTP traffic  |


To create the firewall rules mentioned above, execute the following commands:

1. List all the NSG in the resource group of the Kubernetes cluster and note down the name of the default NSG.
```bash
az network nsg list --resource-group MC_${resourceGroup}_${clusterName}_${location} -o table

Location    Name                        ProvisioningState    ResourceGroup                              ResourceGuid
----------  --------------------------  -------------------  -----------------------------------------  ------------------------------------
westeurope  aks-agentpool-32669720-nsg  Succeeded            MC_cognigy-vg2-aks_cognigy-vg2_westeurope  b77c3940-52fd-4e81-a700-db1426526736
```

Note down the default NSG name ( `aks-agentpool-32669720-nsg` in this case) from the output of the above command and set it to the variable `nsgName` as shown below
```bash
export nsgName=<nsg_name>
```

2. Create a NSG rule for VoIP traffic
```bash
export nodeResourceGroup=$(az aks show --resource-group $resourceGroup --name $clusterName --query nodeResourceGroup -o tsv)
export sipIngressPublicIPPrefixCIRD=$(az network public-ip prefix show --name ${sipIngressPublicIPPrefix} --resource-group ${resourceGroup} --query 'ipPrefix' -o tsv)

az network nsg rule create \
  --name AllowSipIngressTrafficTcp \
  --nsg-name $nsgName \
  --priority 1000 \
  --resource-group ${nodeResourceGroup} \
  --access Allow \
  --description "allow TCP sip ingress traffic" \
  --source-address-prefixes '*' \
  --destination-port-ranges 5060 5061 8443 \
  --protocol Tcp \
  --destination-address-prefixes $subnetAddressPrefix

az network nsg rule create \
  --name AllowSipIngressTrafficUdp \
  --nsg-name $nsgName \
  --priority 1001 \
  --resource-group ${nodeResourceGroup} \
  --access Allow \
  --description "allow UDP sip ingress traffic" \
  --source-address-prefixes '*' \
  --destination-port-ranges 5060 5061 \
  --protocol Udp \
  --destination-address-prefixes $subnetAddressPrefix
```

3. Create an NSG rule for media traffic
```bash

az network nsg rule create \
  --name AllowRtpIngressTrafficUdp \
  --nsg-name $nsgName \
  --priority 1002 \
  --resource-group ${nodeResourceGroup} \
  --access Allow \
  --description "allow UDP rtp ingress traffic" \
  --source-address-prefixes '*' \
  --destination-port-ranges 40000-60000 \
  --protocol Udp \
  --destination-address-prefixes $subnetAddressPrefix
```

### Connect to the cluster
Get the kubeconfig file for connecting to the cluster

```bash
az aks get-credentials --resource-group ${resourceGroup} --name ${clusterName}
```

Alternatively use the following command to get the kubeconfig file with static admin credentials
```bash
az aks get-credentials --resource-group ${resourceGroup} --name ${clusterName} --admin -f kubeconfig_${clusterName}_static_admin
```

## Optional configuration

### Use a static public IP address with the Azure Kubernetes Service (AKS) load balancer
By default, the public IP address assigned to a load balancer resource created by an AKS cluster is only valid for the lifespan of that resource. If you delete the Kubernetes service, the associated load balancer and IP address are also deleted. If you want to assign a specific IP address or retain an IP address for redeployed Kubernetes services, you can create and use a static public IP address.

Create a new static public IP address. This IP can be assigned to the ingress controller. We use [Treafik](https://traefik.io/) Ingress controller shipped with VoiceGateway Helm Chart. 
```bash
export ingress01PublicIPName=${clusterName}-aks-ingress-01

az network public-ip create \
  --resource-group $resourceGroup \
  --name $ingress01PublicIPName \
  --allocation-method Static \
  --sku Standard \
  --version IPv4 \
  --location $location \
  --zone {1,2,3} \
  --tags $tags
```

Before creating a service, ensure the cluster identity used by the AKS cluster has delegated permissions to the main resource group.

```bash
export aksManagedIdentityPrincipalId=$(az aks show --name ${clusterName} --resource-group ${resourceGroup} --query 'identity.principalId' -o tsv)
export resourceGroupId=$(az group show --name $resourceGroup --query 'id' -o tsv)
export loadBalancerInboudIpId=$(az network public-ip show --resource-group $resourceGroup --name $ingress01PublicIPName --query 'id' -o tsv)

az role assignment create \
    --assignee $aksManagedIdentityPrincipalId \
    --role "Network Contributor" \
    --scope $resourceGroupId

az role assignment create \
    --assignee $aksManagedIdentityPrincipalId \
    --role "Network Contributor" \
    --scope $loadBalancerInboudIpId
```
In your custom values file, define the following parameters:
  1. Replace the `<resource_group_name>` with the proper value, `cognigy-vg-aks` in this example.
  2. Replace the `<ingress_public_IP>` with static public IP created for the ingress. You can get the static public using the command `az network public-ip show --resource-group $resourceGroup --name $ingress01PublicIPName --query 'ipAddress' -o tsv`

```yaml
traefik:
  service:
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-resource-group: "<resource_group_name>"
    spec:
      externalTrafficPolicy: Local
      loadBalancerIP: "<ingress_public_IP>"
```

## Upgrade the AKS cluster
The AKS cluster lifecycle involves periodic upgrades to the latest Kubernetes version. You must apply for the latest security releases or upgrade to get the latest features. This article shows how to check for, configure, and apply upgrades to your Cognigy Voice Gateway AKS cluster.

> Note: This section does not apply to the deploying new version of Cognigy Voice Gateway. This section is only about updating the AKS cluster that is installing a new Kubernetes version in the cluster or patching the nodes with a newer image.


### Considerations for upgrading VoIP and Media node pools
By default, AKS configures upgrades to surge with one extra node. A default value of one for the max surge settings will enable AKS to minimize workload disruption by creating an extra node before the cordon/drain of existing applications to replace an older versioned node. The max surge value may be customized per node pool to enable a trade-off between upgrade speed and upgrade disruption.

Some special measures need to take in consideration for upgrading the VoIP and media node pool of the Cognigy VoiceGateway cluster. And due to the special requirements of the SIP protocol (No FQDN and no failover IP support) and the current limitations of the AKS it is not possible to update the cluster without any downtime. In order to reduce the downtime to its minimalist, please follow the below sequence

  1. Plan a maintenance window.
  2. Upgrade the control plane.
  3. Upgrade the default node pool.
  4. Scale down the VoIP node pool to n-1 nodes, where n is the number nodes you have in the VoIP node pool and 1 is the default value of the max surge.
  5. Upgrade the VoIP node pool.
  6. Scale up the VoIP node pool to n nodes.
  7. Repeat steps 4-6 for the media node pool.

### Upgrade the cluster
To check which Kubernetes releases are available for your cluster, use the `az aks get-upgrades` command. The following example checks for available upgrades to cognigy-vg in cognigy-vg-aks:

```bash
# Name of the resource group
export resourceGroup=cognigy-vg-aks
# Azure region
export location=westeurope
# Name of the AKS cluster
export clusterName=cognigy-vg


az aks get-upgrades --resource-group $resourceGroup --name $clusterName --output table
```
Example output
```bash
az aks get-upgrades --resource-group $resourceGroup --name $clusterName --output table

Name     ResourceGroup    MasterVersion    Upgrades
-------  ---------------  ---------------  ------------------------
default  cognigy-vg-aks   1.23.12          1.23.15, 1.24.6, 1.24.9
```

#### Upgrade the control plane
Upgrade the cluster control plane of the managed Kubernetes Cognigy VoiceGateway AKS cluster to Kubernetes version 1.23.15. This step involves no downtime.

```bash
az aks upgrade \
  --kubernetes-version 1.23.15 \
  --name $clusterName \
  --resource-group $resourceGroup \
  --control-plane-only
```

#### Upgrade the default node pool
Once the cluster control plane is upgraded, upgrade the default node pool in the managed Kubernetes Cognigy VoiceGateway AKS cluster to Kubernetes version 1.23.15.

```bash
export defaultNodepoolName=defaultpool

az aks nodepool upgrade
  --cluster-name $clusterName \
  --nodepool-name $defaultNodepoolName \
  --resource-group $resourceGroup \
  --kubernetes-version 1.23.15
```

#### Upgrade the VoIP Node Pool
Scale down the VoIP node pool to 1 node to accommodate the surge node.

```bash
export voipNodepoolName=voip

az aks nodepool scale \
  --cluster-name $clusterName \
  --nodepool-name $voipNodepoolName \
  --resource-group $resourceGroup \
  --node-count 1
```

Upgrade the VoIP node pool to Kubernetes version 1.23.15.

```bash
az aks nodepool upgrade
  --cluster-name $clusterName \
  --nodepool-name $voipNodepoolName \
  --resource-group $resourceGroup \
  --kubernetes-version 1.23.15
```

Once upgraded, scale up the VoIP node pool to 2 nodes.

```bash
az aks nodepool scale \
  --cluster-name $clusterName \
  --nodepool-name $voipNodepoolName \
  --resource-group $resourceGroup \
  --node-count 2
```

#### Upgrade the Media Node Pool
Repeat the steps performed while upgrading the VoIP node pool and upgrade the Media node pool to Kubernetes version 1.23.15.

Scale down the Media node pool to 1 node to accommodate the surge node.

```bash
export mediaNodepoolName=media

az aks nodepool scale \
  --cluster-name $clusterName \
  --nodepool-name $mediaNodepoolName \
  --resource-group $resourceGroup \
  --node-count 1
```

Upgrade the Media node pool to Kubernetes version 1.23.15.

```bash
az aks nodepool upgrade
  --cluster-name $clusterName \
  --nodepool-name $mediaNodepoolName \
  --resource-group $resourceGroup \
  --kubernetes-version 1.23.15
```

Once upgraded, scale up the Media node pool to 2 nodes.

```bash
az aks nodepool scale \
  --cluster-name $clusterName \
  --nodepool-name $mediaNodepoolName \
  --resource-group $resourceGroup \
  --node-count 2
```

