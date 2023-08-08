# AWS EKS Cluster Setup

In order to install Cognigy VoiceGateway product, you need to provision a dedicated AWS EKS cluster. 
Please, create an EKS Cluster in accordance with [Official AWS Documentation](https://docs.aws.amazon.com/eks/latest/userguide/create-cluster.html). You can use a tool of your choice for cluster provisioning. Please, follow AWS requirements and consideration for [VPC provisioning](https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html). We recommend placing k8s nodes into private subnets distributed across 3 Availability Zones (AZs). The cluster must meet the specification below.

## EKS Managed Node Groups
Your EKS cluster must have 3 [EKS managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html):
1. `worker_group`: Node group for generic workloads, at least 4 `c5.2xlarge` EC2 instances distributed across 3 availability zones are required. No additional taints or labels are required on this node group.
2. `voip_nodes`: Node Group for SIP protocol handling, at least 3 `c5.xlarge` EC2 instances distributed across 3 availability zones are required. **Nodes must have public IPs assigned to each instance for direct external access.** To isolate SIP workloads, the node group must have following:
    1. Kubernetes Label:
   ```yaml
   `key`: `voip-environment`
   `value`: `edge`
   ```
    2. Kubernetes Taint:
   ```yaml
   `key`: `voip-edge`
   `value`: `true`
   `effect`: `NoSchedule`
   ```

3. `media_nodes`: Node Group for RTP protocol handling, at least 3 `c5.xlarge` EC2 instances distributed across 3 availability zones are required. **Nodes must have public IPs assigned to each instance for direct external access.** To isolate RTP workloads, the node group must have following:
    1. Kubernetes Label:
   ```yaml
   `key`: `media-environment`
   `value`: `edge`
   ```
    2. Kubernetes Taint:
   ```yaml
   `key`: `media-edge`
   `value`: `true`
   `effect`: `NoSchedule`
   ```

## Network Security Rules

All node groups must have the following security rules attached in addition to standard EKS security rules. These additional
security rules must allow the nodes from different node groups to communicate with each other and to access the Internet. Replace `SG_NODES_NAME` with the name of the security group attached to all nodes in the cluster.

#### Network Security Rules for All Node Groups
| Type     | Protocol | Port range | Source          | Description                                  |
|----------|----------|------------|-----------------|----------------------------------------------|
| inbound  | All      | All        | `SG_NODES_NAME` | Allow ingress for node-to-node communication |
| outbound | All      | All        | `SG_NODES_NAME` | Allow egress for node-to-node communication  |
| outbound | All      | All        | `0.0.0.0/0`     | Allow egress for all nodes to Internet       |

In order for SIP and RTP protocols to operate properly. Additional security groups must be attached to SIP and RTP node groups
allowing communication for both protocols. In case you need to limit access to a particular SIP trunk provider(s), replace `0.0.0.0/0` 
IP range according to your requirements.

#### Network Security Rules for VOIP Nodes
| Type     | Protocol | Port range  | Source       | Description           |
|----------|----------|-------------|--------------|-----------------------|
| inbound  | TCP      | 5060 - 5061 | `0.0.0.0/0`  | Allow SIP TCP traffic |
| inbound  | UDP      | 5060 - 5061 | `0.0.0.0/0`  | Allow SIP UDP traffic |
| inbound  | TCP      | 8443        | `0.0.0.0/0`  | Allow WSS SIP traffic |

#### Network Security Rules for RTP Nodes
| Type     | Protocol | Port range     | Source       | Description       |
|----------|----------|----------------|--------------|-------------------|
| inbound  | UDP      | 40000 - 60000  | `0.0.0.0/0`  | Allow RTP traffic |

## Public IPs for SIP and RTP Nodes
For SIP and RTP protocols to operate properly, SIP and RTP nodes must have public IPs directly attached to k8s nodes in
`voip_nodes` and `media_nodes` node groups. Make sure you provision these node groups with `Public IP` option enabled. 

Additionally, public IPs of both SIP and RTP nodes must be static during operation lifecycle. Reconfiguring or upgrading the node group 
in EKS cluster recreates the nodes with new public IPs. Since the majority of SIP trunk providers require
static IPs on SIP endpoints, this will break SIP operation. To overcome this limitation we provision a separate set of 
[Elastic IPs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html) and attach these IPs to SIP and RTP nodes
during the SIP application startup phase. For this to work: 
1. Create a set of Elastic IPs with the size equal to the number of `voip_nodes` (3 by default) and `media_nodes` (3 by default).
2. Assign unique tag to the sets of Elastic IPs. For `voip_nodes` set the tag with `Key`: `role` and `Name`: `CLUSTER_NAME-sip-node` and for `media_nodes` 
set the tag with `Key`: `role` and `Name`: `CLUSTER_NAME-rtp-node`. Replace `CLUSTER_NAME` with the name of the EKS cluster being provisioned. 
3. The value of the tag must be used in Helm Chart configuration under `spec.values.sbc.ec2EipAllocator.sipEipGroupRole` variable for the `voip_nodes` and 
`spec.values.sbc.ec2EipAllocator.rtpEipGroupRole` variable for the `media_nodes`.

### AWS IAM Permission Policy
To perform remapping of EIPs for SIP and RTP nodes, a dedicated user with a static access key and a specific IAM
policy is required: 
1. Create a dedicated user in AWS account (e.g. `vg_operator`), disable MFA for the user.
2. Generate a static access key for the user, save the key ID and the value. You will need to provide the key ID and its value in `vg-operator-key` Secret in `awsKeyId` and `awsSecretKey` fields respectively. This secret must be created before instantiating a Helm release.
3. Create `eip_remappers_policy` IAM policy as follows:
   ```json
   {
    "Statement": [
        {
            "Action": [
                "ec2:DescribeAddresses",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DescribeTags",
                "ec2:DescribeAddressesAttribute",
                "ec2:AssociateAddress"
            ],
            "Effect": "Allow",
            "Resource": "*"
        }
    ],
    "Version": "2012-10-17"
   }
   ```
4. Attach `eip_remappers_policy` to the created user. The policy allows the user to dissociate and associate EIPs on SIP and RTP nodes based on the tag.
You can make `Resource` scope of the policy more restrictive according to your internal security guidelines.