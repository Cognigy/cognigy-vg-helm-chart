# VG Team Secrets Integration

## Overview

The VoiceGateway Helm chart has been updated to support the new `vg-team-credentials` sealed secret, which contains:
- Team member email addresses
- SMTP credentials for email notifications
- Cognigy managed environment flag

This allows for centralized management of team member credentials and SMTP settings in Cognigy-managed environments.

## Secret Structure

The `vg-team-credentials` sealed secret contains the following keys:

| Key | Description | Example Value |
|-----|-------------|---------------|
| `VG_TEAM_MEMBER_EMAILS` | Comma-separated list of team member email addresses | `markus.frindt@nice.com,...` |
| `SMTP_USERNAME` | SMTP username for sending emails | `AKIAWOXXXXXXXXXXXXX` |
| `SMTP_PASSWORD` | SMTP password for sending emails | `BAU94XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX` |
| `COGNIGY_MANAGED_ENV` | Flag indicating if this is a Cognigy-managed environment | `true` |

## Helm Chart Changes

### 1. values.yaml

Added a new unified `vgTeam` configuration section that consolidates team member and email notification settings:

```yaml
api:
  vgTeam:
    ## Secret containing SMTP credentials and optionally team member emails
    ## Default: "cognigy-service-ai-smtp-email-creds" (for non-Cognigy environments)
    ## Cognigy-managed: "vg-team-credentials" (contains SMTP + team members)
    existingSecret: "vg-team-credentials"
    ## Team member configuration
    teamMembers:
      ## Secret key for team member emails (comma-separated list)
      emailsKey: "VG_TEAM_MEMBER_EMAILS"
      ## Secret key for Cognigy managed environment flag
      managedEnvKey: "COGNIGY_MANAGED_ENV"
    ## Email notification SMTP configuration    
```

**Key Benefits:**
- **Unified Configuration**: Single `existingSecret` setting at the root for both team members and SMTP
- **Clear Hierarchy**: All team-related configuration is under `api.vgTeam`
- **Flexible**: Supports both Cognigy-managed and customer-managed secrets with different key names

### 2. api-server/deployment.yaml

Updated the deployment template to:
- Use a single `$vgTeamSecret` variable for all team-related secrets
- Support configurable secret keys for SMTP credentials
- Add environment variables for team member emails and Cognigy managed environment flag
- Include checksum annotations to trigger pod restarts when the secret changes

**Template Variables:**
```yaml
{{- $vgTeamSecret := include "common.secretName.render" ( dict "existingSecret" $.Values.api.vgTeam.existingSecret "defaultSecret" "cognigy-service-ai-smtp-email-creds") }}
```

**New Environment Variables:**
- `VG_TEAM_MEMBER_EMAILS` - sourced from `$vgTeamSecret` using `emailsKey`
- `COGNIGY_MANAGED_ENV` - sourced from `$vgTeamSecret` using `managedEnvKey`

Both are marked as `optional: true` to maintain backward compatibility with non-Cognigy-managed environments.

## Configuration for Cognigy-Managed Environments

For Cognigy-managed environments (voicegateway-dev, vg-staging), override the following values:

```yaml
api:
  vgTeam:
    existingSecret: "vg-team-credentials"
    emailNotification:
      smtpUsernameKey: "SMTP_USERNAME"
      smtpPasswordKey: "SMTP_PASSWORD"
```

This configuration:
- Uses the `vg-team-credentials` sealed secret for all team-related credentials
- Uses the Cognigy key names (`SMTP_USERNAME` and `SMTP_PASSWORD`)
- Automatically provides team member emails to the API server
- Reuses the same secret for both SMTP and team member data (more efficient)

## Backward Compatibility

The changes maintain full backward compatibility:

1. **Default Configuration**: The default `existingSecret` still points to `cognigy-service-ai-smtp-email-creds` with the legacy key names (`smtp-email-basic-username` and `smtp-email-basic-password`)
2. **Optional Environment Variables**: `VG_TEAM_MEMBER_EMAILS` and `COGNIGY_MANAGED_ENV` are marked as optional, so they won't cause errors if the secret doesn't contain them
3. **Existing Deployments**: Non-Cognigy-managed environments and customer installations continue to work without any changes
4. **Gradual Migration**: Environments can be migrated to the new secret structure one at a time

## Key Design Principles

1. **Single Source of Truth**: The `vgTeam.existingSecret` defines one secret for all team-related credentials
2. **Flexible Key Names**: Secret key names are configurable to support different secret structures
3. **Clear Naming**: The `vgTeam` parent makes it obvious this is for VG team management
4. **No Duplication**: Eliminates the need to specify the same secret name in multiple places

## Secret Generation

The `vg-team-credentials` sealed secret is generated using the script located at:
```
other-files/vg-credentials/main.py
```

To generate or update the sealed secret:
1. Update team member emails in `other-files/vg-credentials/vg-credentials.yaml`
2. Update SMTP credentials in `other-files/vg-credentials/vg-credentials-crypt.yaml` (git-crypt protected)
3. Run the script: `python main.py` and select "Generate team emails sealed secret (for API server)"

The script will:
- Generate a sealed secret at `common/voicegateway/vg-team-credentials-sealed.yaml`
- Update kustomization files in specified VG environments (voicegateway-dev, vg-staging)

## Deployment

### Prerequisites
- The `vg-team-credentials-sealed.yaml` must exist in the kustomization resources
- The API server must support the new environment variables

### Rollout
1. Ensure the sealed secret is applied to the cluster
2. Update the values files to use the new secret configuration
3. Deploy the updated Helm chart

The pod will automatically restart when the secret changes due to the checksum annotation.

## Testing

To verify the integration:

1. Check that the secret exists:
   ```bash
   kubectl get secret vg-team-credentials -n voicegateway
   ```

2. Verify the secret contains all required keys:
   ```bash
   kubectl get secret vg-team-credentials -n voicegateway -o jsonpath='{.data}' | jq 'keys'
   ```

3. Check that the API server pod has the environment variables:
   ```bash
   kubectl get pod -n voicegateway -l app=api-server -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="VG_TEAM_MEMBER_EMAILS")]}' | jq
   ```

4. Verify team member creation on API server startup by checking logs:
   ```bash
   kubectl logs -n voicegateway -l app=api-server --tail=100 | grep -i "team member"
   ```

## Troubleshooting

### Secret Not Found
If the API server fails to start due to missing secret:
- Verify the sealed secret is in the kustomization resources
- Check that FluxCD has reconciled the resources: `flux reconcile kustomization voicegateway`

### Team Members Not Created
- Verify `VG_TEAM_MEMBER_EMAILS` environment variable is set in the pod
- Check API server logs for errors related to user creation
- Verify `enablePrepareCognigyData` is set to `true` in values

### SMTP Errors
- Verify SMTP credentials are correct in the sealed secret
- Check that the secret keys match the configuration (`SMTP_USERNAME`, `SMTP_PASSWORD`)
- Test SMTP connectivity from the API server pod

## Related Files

### Helm Chart
- `~/Workspace/voicegateway-app/values.yaml`
- `~/Workspace/voicegateway-app/templates/api-server/deployment.yaml`
- `~/Workspace/voicegateway-app/templates/api-server/vg-team-default-password.yaml`

### Flux Configuration
- `~/Workspace/flux-fleet-non-prod/common/voicegateway/vg-team-credentials-sealed.yaml`
- `~/Workspace/flux-fleet-non-prod/aws/eu-central-1/voicegateway-dev/voicegateway/voicegateway-values.yaml`
- `~/Workspace/flux-fleet-non-prod/azure/north-europe/vg-staging/voicegateway/voicegateway-values.yaml`

### Secret Generation
- `~/Workspace/flux-fleet-non-prod/other-files/vg-credentials/main.py`
- `~/Workspace/flux-fleet-non-prod/other-files/vg-credentials/scripts/sealed_secrets/generate_team_secret.py`
- `~/Workspace/flux-fleet-non-prod/other-files/vg-credentials/vg-credentials.yaml`
- `~/Workspace/flux-fleet-non-prod/other-files/vg-credentials/vg-credentials-crypt.yaml`

