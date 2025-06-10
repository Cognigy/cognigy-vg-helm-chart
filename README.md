![Cognigy.AI banner](./docs/assets/voicegateway.png)

# Cognigy VoiceGateway Helm Chart

[Cognigy.AI](https://www.cognigy.com/) is an Enterprise Conversational Automation Platform for building advanced, integrated Conversational Automation Solutions through the use of cognitive bots.

This chart installs a Cognigy VoiceGateway deployment on a [Kubernetes](https://kubernetes.io/) cluster using the [Helm](https://helm.sh/) package manager.

## Prerequisites

1. Kubernetes cluster running on AWS EKS or Azure AKS.
2. [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) utility installed on Linux or MacOS client and connected to the cluster with administrative permissions. **Windows clients are not supported by this installation guide.**
3. [Helm](https://helm.sh/docs/intro/install/) utility installed locally.
4. A valid SSL certificate for your domain that is not self-signed.
5. Access to the Cognigy Container Registry with valid credentials.
6. The versions of Kubernetes, kubectl, and Helm must be compatible with the specified versions of Cognigy Voice Gateway, as outlined in the [Version Compatibility Matrix](https://docs.cognigy.com/voice-gateway/installation/version-compatibility-matrix/).

### System Requirements

Requirements for a minimal setup to support up to 120 concurrent lines:

| Node Pool    | Node Count | vCPU per Node  | Total vCPUs | AWS Equivalent | Azure Equivalent   | Purpose        |
|--------------|:----------:|:--------------:|:-----------:|----------------|--------------------|----------------|
| Default      | 4          | 8              | 32          | c5.2xlarge     | Standard_F8s_v2    | Worker nodes   |
| Media        | 2          | 4              | 8           | m5.xlarge      | D4s_v5             | RTP nodes      |
| VoIP         | 2          | 4              | 8           | m5.xlarge      | D4s_v5             | SIP nodes      |


## Configuration

Provision a managed kubernetes provider following one of the following guides:
- [AWS EKS Cluster Setup](docs/aws-eks-cluster-setup.md)
- [Azure AKS Cluster Setup](docs/azure-aks-cluster-setup.md)
- [GCP GKE Cluster Setup (DEPRECATED)](docs/gcp-gke-cluster-setup.md)

### Release Values

To deploy a new Cognigy VoiceGateway setup you need to create a separate file with Helm release values. You can use `values_prod.yaml` as a baseline, we recommend to start with it:

1. Make a copy of `values_prod.yaml` into a new file and name it accordingly, we refer to it as `YOUR_VALUES_FILE.yaml` later in this document.
2. **Do not make** a copy of default `values.yaml` file as it contains hardcoded docker images references for all microservices, and in this case you will need to change all of them manually during upgrades. However, you can add some variables from default `values.yaml` file into your customized `YOUR_VALUES_FILE.yaml` later on, e.g. for tweaking CPU/RAM resources of Cognigy VoiceGateway microservices. We describe this process later in the document.

### Setting Essential Parameters

You need to set at least following parameters in `YOUR_VALUES_FILE.yaml`:

1. Cognigy.AI Image repository credentials: set `imageCredentials.username` and `imageCredentials.password` accordingly.
2. Cloud Provider: set `cloud` variable accordingly.

### Cognigy.VG DNS and TLS Settings

Cognigy VoiceGateway exposes three web services for which you will need to assign DNS records in a public domain operated by your organization. These DNS records must be added into your DNS system during the installation process. Replace `yourdomain.<tld>` according to the domain (subdomain) of your organization under `ingress` section as below:

  ```yaml
  ingress:
    api:
      host: "api-vg.yourdomain.<tld>"
    testCallManager:
      host: "tcm-vg.yourdomain.<tld>"
    webapp:
      host: "vg.yourdomain.<tld>"
  ```

Cognigy VoiceGateway relies on SSL-encrypted connection between the client and the services. You need to provide an SSL certificate for the domain in which DNS records for Cognigy VoiceGateway will be created, for this put the SSL certificate under `tls.crt` and its private key under `tls.key`. If you have a certificate chain, make sure you provide the whole certificate chain under `tls.crt` in [.pem format](https://www.digicert.com/kb/ssl-support/pem-ssl-creation.htm).

**Note: Make sure you install a publicly trusted TLS certificate signed by a Certificate Authority. Although using of self-signed certificates is possible in test environments, Cognigy does not recommend usage of self-signed certificates, does not guarantee full compatibility with our products and will not support such installations.**

## Installing the Chart

1. Download dependencies:

    ```bash
    helm dependency update
    ```

2. Install Cognigy VoiceGateway Helm release:

    - Installing from Cognigy Container Registry (recommended), specify proper `HELM_CHART_VERSION` and `YOUR_VALUES_FILE.yaml`:
        - Login into Cognigy helm registry (provide your Cognigy Container Registry credentials):

            ```bash
            helm registry login cognigy.azurecr.io \
            --username <your-username> \
            --password <your-password>
            ```

        - Install Helm Chart into a separate `voicegateway` namespace:

            ```bash
            helm upgrade --install --namespace voicegateway voicegateway oci://cognigy.azurecr.io/helm/voicegateway --version HELM_CHART_VERSION --values YOUR_VALUES_FILE.yaml --create-namespace
            ```

    - Alternatively you can install it from the local chart (not recommended):

        ```bash
        helm upgrade --install --namespace voicegateway --values YOUR_VALUES_FILE.yaml voicegateway . --create-namespace
        ```

3. Verify that all pods are in a ready state:

    ```bash
    kubectl get pods --namespace voicegateway
    ```

4. Get external IP/CNAME (EXTERNAL-IP) for DNS records of LoadBalancer Service for Traefik Ingress:

    ```bash
    kubectl get service -n=voicegateway traefik
    ```

5. Add DNS records provided in `YOUR_VALUES_FILE.yaml` into your DNS provider pointing to `EXTERNAL-IP` from the output of the previous command.

Proceed with logging in into Cognigy VoiceGateway WebApp under the host defined before: i.e.: `vg.yourdomain.<tld>`

## Post-Installation Tasks

### Save the Credentials

Save the following values from the log of the `api-server` pod:

- `admin-password`
- `cognigy-ai password`
- `[DEFAULT ACCOUNT] account sid`
- `[IP TEST CALL MANAGER] API key created`
- `[IP TEST CALL MANAGER] Service Provider created`

If you could not save the generated user credentials, SP ID, and token due to a pod restart or another issue, follow the steps mentioned in the [Reset the Initial User Credentials for Voice Gateway](#reset-the-initial-user-credentials-for-voice-gateway) section.

### Add DNS Entries

Add DNS entries for all ingresses. Point the webapp ingress to the Traefik public endpoint (ELB for EKS and ingress IP for AKS), and direct the remaining ingresses to the webapp ingress.

Add the following DNS records based on the number of nodes in the VoIP node pool. These records will be used for Interaction Panel Calls and SIP over TLS. The example illustrates a setup with two nodes in the VoIP node pool:

  ```sh
  sip-vg.yourdomain.<tld>     IN    A    <sip_node_ip_01>
  sip-vg.yourdomain.<tld>     IN    A    <sip_node_ip_02>
  ...
  ...

  sip-vg-1.yourdomain.<tld>    IN    A    <sip_node_ip_01>
  sip-vg-2.yourdomain.<tld>    IN    A    <sip_node_ip_02>
  ...
  ...

  _sips._tcp.sip-vg.yourdomain.<tld>   IN    SRV    1 1 5061 sip-vg-1.yourdomain.<tld>
  _sips._tcp.sip-vg.yourdomain.<tld>   IN    SRV    1 1 5061 sip-vg-2.yourdomain.<tld>
  ...
  ...
  ```

### Execute the Database Creation Job as a Helm Hook

After the initial deployment, enable the Helm hook for the `dbCreate` job. Add the following line in your `YOUR_VALUES_FILE.yaml` file:

  ```yaml
  dbCreate:
    hookEnabled: true
  ```

### Cognigy VoiceGateway WebApp Login

To log in for the first time, use the following credentials:

- username: `admin`
- password:  Value of the `admin-password` from in the [Save the Credentials](#save-the-credentials) step.

### Enable Interaction Panel Calls

Deploy the `test-call-manager`. This service requires either `id` and `apiKey` or `existingCredentials` as input.

1. Create a secret with the `[IP TEST CALL MANAGER] API key created` and `[IP TEST CALL MANAGER] Service Provider created` you saved in the [Save the Credentials](#save-the-credentials) step.

    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
      name: vg-default-interaction-panel-service-provider
      namespace: voicegateway
    type: Opaque
    data:
      apiKey: <base64 encoded value of the "[IP TEST CALL MANAGER] API key created">
      id: <base64 encoded value of the "[IP TEST CALL MANAGER] Service Provider created">
    ```

2. Add the following  configuration to your `YOUR_VALUES_FILE.yaml` file:

   ```yaml
   testCallManager:
     enabled: true
     interactionPanelServiceProvider:
       existingCredentials: "vg-default-interaction-panel-service-provider"
   ```

3. Upgrade the Helm chart

### Pair Cognigy.AI to Voice Gateway

1. To enable Voice Gateway and its features, add the following environment variables to your Cognigy.AI `YOUR_VALUES_FILE.yaml` file:

    ```yaml
    cognigyEnv:
      ## VoiceGateway
      ##
      # Enable VoiceGateway
      FEATURE_ENABLE_VOICEGATEWAY_2: "true"

      ## You can either whitelist dedicated organization Ids or allow all orgIds

      ## Comma-separated list of Org. IDs to have VoiceGateway enabled
      # FEATURE_ENABLE_VOICEGATEWAY_2_WHITELIST: "OrgID1,OrgID2"
      ## Comma-separated list of Org. IDs to have Interaction Panel Calls feature enabled
      # FEATURE_ENABLE_VOICECALL_WHITELIST: "OrgID1,OrgID2"

      # Enable VoiceGateway to all Org.
      FEATURE_ENABLE_VOICEGATEWAY_2_OVERRIDE_ALL_ORG_IDS: "true"
      # Enable Interaction Panel Calls feature to all Org.
      FEATURE_ENABLE_VOICECALL_OVERRIDE_ALL_ORG_IDS: "true"

      ## Interaction Panel call settings
      VOICE_GATEWAY_PREPARE_CALL_API: "/api/v2/call/prepare"
      VOICE_GATEWAY_BASE_URL_WITH_PROTOCOL: "https://tcm-vg.yourdomain.<tld>"  # URL of testCallManager
      VOICE_GATEWAY_SIP_WS_URI_WITH_PROTOCOL: "wss://sip-vg.yourdomain.<tld>:8443" # SIP DNS
      VOICE_TEST_CALL_API_SECRET: <Content of test-call-manager-api-secret secret from Cognigy.VG cluster>

      # Generic voice nodes
      FEATURE_TMP_ENABLE_GENERIC_VOICE_NODES: "true"
      # VG Silence Stream at the beginning of every call - [ default 1000 ]
      VG_SILENCE_IN_MS: "750"
      # Enable the Call Failover section for Voice Gateway Endpoints.
      FEATURE_ENABLE_ENDPOINT_CALL_FAILOVER: "true"
      # Enable Call events section in the VG Endpoint Editor
      FEATURE_ENABLE_ENDPOINT_CALL_EVENTS: "true"
    ```
2. Upgrade the Helm chart in Cognigy.AI.

### Enable Cognigy SSO Login via Cognigy.AI

Cognigy SSO Login establishes a one-to-one relationship between a Voice Gateway cluster and a Cognigy.AI cluster.

To implement this feature, you need to create two secrets:

1. `cognigy-vg-webapp-default-login-credentials` (AI)
2. `cognigy-login-client-secret` (VG)

#### Create an SSO Secret for Cognigy.AI

1. Create a new secret in the Cognigy.AI cluster. Use the value of `cognigy-ai password` from the [Save the Credentials](#save-the-credentials) step as `<cognigy-ai_user_password>`:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: cognigy-vg-webapp-default-login-credentials
     namespace: cognigy-ai
   type: Opaque
   data:
     vg-webapp-login-creds: <base64 encoded - {"username": "cognigy-ai", "password": "<cognigy-ai_user_password>"}>
   ```

2. Add the following configuration to your Cognigy.AI `YOUR_VALUES_FILE.yaml` file:

    ```yaml
    commonSecrets:
      vgWebappDefaultLoginCredentials:
        existingSecret: "cognigy-vg-webapp-default-login-credentials"

    cognigyEnv:
      # Enable SSO for Cognigy.AI in the Voice Gateway WebApp
      VG_WEBAPP_ACCESS_WHITELIST: "*"
      COGNIGY_VOICE_GATEWAY_WEB_BASE_URL_WITH_PROTOCOL: "https://vg.yourdomain.<tld>" # URL of Cognigy.VG webapp
      COGNIGY_VOICE_GATEWAY_APP_BASE_URL_WITH_PROTOCOL: "https://api-vg.yourdomain.<tld>" # URL of Cognigy.VG api
    ```
3. Upgrade the Helm chart in Cognigy.AI.

4. Restart the deployments in the Cognigy.AI cluster by replacing `cognigy-ai` with the corresponding namespace where Cognigy.AI is running.

   ```sh
   kubectl -n cognigy-ai rollout restart deployment service-api service-security
   # verify restart
   kubectl -n cognigy-ai get deployments service-api service-security
   kubectl -n cognigy-ai get pods | grep -E "service-(api|security)"
   ```

#### Create an SSO Secret for Voice Gateway

1. Create a secret `cognigy-login-client-secret` in Voice Gateway based on the content of the `cognigy-voicegateway-client-secret` from the Cognigy.AI cluster.

    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
      name: cognigy-login-client-secret
      namespace: voicegateway
    type: Opaque
    data:
      clientSecret: <base64 encoded value of the content of "cognigy-voicegateway-client-secret" secret from Cognigy.AI cluster>
    EOF
    ```
2. Add the following configuration to your Voice Gateway `YOUR_VALUES_FILE.yaml` file:

   ```yaml
   ###########################
   # VoiceGateway Components #
   ###########################
   webapp:
     enableCognigyLogin: true
     cognigyUrl: "https://<yoursubdomain>.yourdomain.<tld>" # URL of Cognigy.AI service-ui

   #################
   # Cognigy Login #
   #################
   cognigyLogin:
     enabled: true
     baseUrl: "https://api-<yoursubdomain>.yourdomain.<tld>"  # URL of Cognigy.AI service-api
     clientId: "voicegateway"
     secret: "cognigy-login-client-secret"
     secretKey: "clientSecret"
   ```

3. Upgrade the Helm chart in Voice Gateway.

#### Connect the Cognigy.AI Organization to the Voice Gateway Account

In a cluster, there can be multiple SSO (Single Sign-On) connections between the Cognigy.AI organization and the Voice Gateway Service Provider. However, each Voice Gateway Service Provider can only be connected to one Cognigy.AI organization.

To connect `organization-X` from the Cognigy.AI organization to the `default service provider` in Voice Gateway, follow these steps:
1. Log in to the Cognigy.AI `organization-X`.
2. Go to the **User Menu > Admin Center** and click **Set up Voice Gateway**. Enter the SID of the `default account` (the value of `[DEFAULT ACCOUNT] account SID` from the [Save the Credentials](#save-the-credentials) step).

#### Verify Cognigy.AI SSO Login

1. Go to the Voice Gateway WebApp.
2. Click **Sign in with Cognigy.AI Account**.
3. Log in using your Cognigy.AI credentials. You should be successfully logged in to the WebApp, linked to your account.

If you encounter any issues, restart `service-security` and `service-api` in the Cognigy.AI cluster before attempting to log in again.

## Reset the Initial User Credentials for Voice Gateway

>**Note**: Perform this process only during the initial Cognigy Voice Gateway setup.


If the generated user credentials, SP ID, and token are not collected from the logs, reset the admin credentials:

1. Retrieve the MySQL root password:
    ```bash
    kubectl get secret -n voicegateway voicegateway-mysql-password -o jsonpath="{.data.mysql-password}" | base64 -d && echo ""
    ```

2. Log in to the `mysql-0` Pod:
    ```bash
    kubectl exec -i -t -n voicegateway mysql-0 -c mysql -- sh -c "bash"
    ```

3. Run the following commands to delete the initially created credentials. Use the MySQL root password from step 1:

    ```sql
    mysql -u root -p
    show databases;
    use jambones;

    /* Delete users */
    DELETE FROM users WHERE name = "admin";
    DELETE FROM users WHERE name = "cognigy-ai";

    /* Delete related api_keys of the SP 'IP Test Call Manager' */
    DELETE api_keys.*
    FROM api_keys
    JOIN service_providers ON api_keys.service_provider_sid = service_providers.service_provider_sid
    WHERE service_providers.name = 'IP Test Call Manager';

    /* Delete the service_provider */
    DELETE FROM service_providers WHERE name = "IP Test Call Manager";
    ```

4. Restart the `api-server` Deployment:
    ```bash
    kubectl rollout restart deployment -n voicegateway api-server
    ```

5. Once the pods are restarted, check the log of the new pod:
    ```bash
    kubectl logs -n voicegateway deployments/api-server
    ```

## Upgrade the Helm Release

To upgrade the Voice Gateway platform to a newer version, you need to update the existing Helm release to a specific `HELM_CHART_VERSION`. To do this, execute the following command:

  ```bash
  helm upgrade --namespace voicegateway voicegateway oci://cognigy.azurecr.io/helm/voicegateway --version HELM_CHART_VERSION --values YOUR_VALUES_FILE.yaml
  ```

## Modifying Resources

Default resources for Cognigy.AI microservices specified in `values.yaml` are tailored to provide consistent performance for typical production use-cases. However, to meet particular demands, you can modify RAM/CPU resources or number of replicas for separate microservices in your Cognigy.AI installation. For this you need to copy specific variables from default `values.yaml` into `YOUR_VALUES_FILE.yaml` for a particular microservice and adjust the `Request/Limits` and `replicaCount` values accordingly.

**IMPORTANT:** Do not copy `image` value as you will need to modify it manually during upgrades!

For example, for `feature-server` microservice copy from `values.yaml` and adjust in `YOUR_VALUES_FILE.yaml` following variables:

  ```yaml
  feature-server:
    replicaCount: 3
    resources:
      requests:
        cpu: '3'
        memory: 2Gi
      limits:
        cpu: '4'
        memory: 3Gi
  ```

## Cognigy.VG Secrets Backup

During the installation process `dbinit-generate.sh` initialization script generates connection strings for Cognigy VoiceGateway microservices to Redis and stores these connection strings in form of [Kubernetes secrets](https://kubernetes.io/docs/concepts/configuration/secret/) in `voicegateway` installation namespace. In case you loose the cluster where Cognigy VoiceGateway is running or accidentally delete these secrets, there will be no possibility to connect to the existing databases anymore.

**Thus, it is crucial to make a consistent backup of the secrets in `voicegateway` namespace and to store them securely**. Execute this [script](scripts/backup_voicegateway_secrets.sh) to perform a backup of secrets. Store the folder with the secrets securely as it contains sensitive data.

## Uninstalling the Release

**IMPORTANT:** If you uninstall the Cognigy VoiceGateway Helm release, `traefik` Ingress deployment will also be removed. Consequently, a dynamically provisioned `External IP` of the cloud provider's load balancer (e.g. ELB on AWS) will also be freed up. It will affect static DNS settings configured during DNS setup and will cause a downtime of your installation. If you recreate a release you will also have to update DNS, make sure DNS timeouts are set properly, to avoid long outages.

To uninstall a release execute:

  ```bash
  helm uninstall --namespace voicegateway voicegateway
  ```

## Clean-up

Please keep in mind that Persistent Volume Claims (PVC) and Secrets are not removed when you delete the Helm release. However, please also keep in mind that:

- All data will be lost if PVCs are cleaned up

To fully remove PVCs and secrets you need to run the following command:

**IMPORTANT: If you run these commands, all data persisted in PVCs will be lost!**

**IMPORTANT: If you run these commands, all credentials will be lost!**

  ```bash
  kubectl delete --namespace voicegateway pvc --all
  kubectl delete --namespace voicegateway secrets --all
  ```
