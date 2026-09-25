#!/usr/bin/env bash
set -euo pipefail

repository='riksbanken/demo-llm-oauth'
github_environment='poc'
location='swedencentral'
resource_group='rg-demo-llm-oauth-poc'
dns_label=''
vm_admin_username='azureadmin'
ssh_public_key_file=''
output_file='deploy/azure/generated/github-bootstrap.env'

usage() {
  cat <<'EOF'
Usage: bootstrap-github-oidc.sh --dns-label LABEL --ssh-public-key-file PATH [options]

Options:
  --repository OWNER/REPO          GitHub repository (default: riksbanken/demo-llm-oauth)
  --github-environment NAME        GitHub environment (default: poc)
  --location REGION                Azure region (default: swedencentral)
  --resource-group NAME            Azure resource group
  --dns-label LABEL                Azure Public IP DNS label (required, max 40 characters)
  --vm-admin-username NAME         Break-glass VM administrator username
  --ssh-public-key-file PATH       Break-glass SSH public key file (required)
  --output-file PATH               Generated non-secret environment file
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) repository=$2; shift 2 ;;
    --github-environment) github_environment=$2; shift 2 ;;
    --location) location=$2; shift 2 ;;
    --resource-group) resource_group=$2; shift 2 ;;
    --dns-label) dns_label=$2; shift 2 ;;
    --vm-admin-username) vm_admin_username=$2; shift 2 ;;
    --ssh-public-key-file) ssh_public_key_file=$2; shift 2 ;;
    --output-file) output_file=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$repository" =~ ^[^/]+/[^/]+$ ]]; then
  printf -- '--repository must be OWNER/REPO.\n' >&2
  exit 2
fi
if [[ ! "$dns_label" =~ ^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$ ]]; then
  printf -- '--dns-label must be 3-40 lowercase letters, digits, or hyphens and cannot start/end with a hyphen.\n' >&2
  exit 2
fi
if [[ -z "$ssh_public_key_file" || ! -f "$ssh_public_key_file" ]]; then
  printf -- '--ssh-public-key-file must name an existing public key file.\n' >&2
  exit 2
fi

for command in az gh python3; do
  command -v "$command" >/dev/null || { printf '%s is required.\n' "$command" >&2; exit 1; }
done
az account show >/dev/null

set_graph_notes() {
  local resource_type=$1
  local object_id=$2
  local notes=$3
  local body
  body=$(NOTES="$notes" python3 -c 'import json,os; print(json.dumps({"notes": os.environ["NOTES"]}))')
  az rest \
    --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/${resource_type}/${object_id}" \
    --headers 'Content-Type=application/json' \
    --body "$body" \
    --output none
}

subscription_id=$(az account show --query id --output tsv)
tenant_id=$(az account show --query tenantId --output tsv)
ssh_public_key=$(tr -d '\r\n' < "$ssh_public_key_file")

printf 'Checking Azure resource providers...\n'
for provider in Microsoft.Compute Microsoft.Network Microsoft.KeyVault Microsoft.CognitiveServices; do
  provider_state=$(az provider show --namespace "$provider" --query registrationState --output tsv)
  if [[ "$provider_state" != 'Registered' ]]; then
    az provider register --namespace "$provider" --wait --only-show-errors
  fi
done

if [[ "$(az group exists --name "$resource_group")" == 'true' ]]; then
  resource_group_location=$(az group show --name "$resource_group" --query location --output tsv)
  printf 'Using existing resource group %s (metadata location: %s).\n' \
    "$resource_group" "$resource_group_location"
else
  az group create \
    --name "$resource_group" \
    --location "$location" \
    --output none
fi

az group update \
  --name "$resource_group" \
  --set \
    tags.Application='demo-llm-oauth' \
    tags.Environment='POC' \
    tags.Owner='aifabriken-dev' \
    tags.Purpose='Entra OAuth protected LLM proof of concept' \
    tags.ManagedBy='GitHub Actions and Bicep' \
    tags.Repository='https://github.com/riksbanken/demo-llm-oauth' \
    tags.Description='Dedicated resource group for the LLM OAuth POC' \
    tags.RB_ApplicationName='Development Services' \
    tags.RB_Creator='Johan.Carlin@riksbank.se' \
    tags.RB_Environment='Utv' \
    tags.RB_FO='Analysis' \
    tags.RB_Owner='Johan.Carlin@riksbank.se' \
    tags.RB_StartDate='2026-09-22' \
  --output none

public_ip_name="${dns_label}-pip"
printf 'Reserving Azure hostname %s.%s.cloudapp.azure.com...\n' "$dns_label" "$location"
az network public-ip create \
  --resource-group "$resource_group" \
  --name "$public_ip_name" \
  --location "$location" \
  --sku Standard \
  --allocation-method Static \
  --version IPv4 \
  --dns-name "$dns_label" \
  --tags \
    Application='demo-llm-oauth' \
    Environment='POC' \
    Owner='aifabriken-dev' \
    Purpose='Entra OAuth protected LLM proof of concept' \
    ManagedBy='GitHub Actions and Bicep' \
    Repository='https://github.com/riksbanken/demo-llm-oauth' \
    Description='Stable public HTTPS endpoint and Azure OpenAI egress allowlist address' \
    RB_ApplicationName='Development Services' \
    RB_Creator='Johan.Carlin@riksbank.se' \
    RB_Environment='Utv' \
    RB_FO='Analysis' \
    RB_Owner='Johan.Carlin@riksbank.se' \
    RB_StartDate='2026-09-22' \
  --output none

public_hostname=$(az network public-ip show \
  --resource-group "$resource_group" \
  --name "$public_ip_name" \
  --query dnsSettings.fqdn \
  --output tsv)

app_display_name="github-${repository//\//-}-${github_environment}"
app_count=$(az ad app list --filter "displayName eq '$app_display_name'" --query 'length(@)' --output tsv)
if [[ "$app_count" == '0' ]]; then
  app_json=$(az ad app create --display-name "$app_display_name" --sign-in-audience AzureADMyOrg --output json)
elif [[ "$app_count" == '1' ]]; then
  app_json=$(az ad app list --filter "displayName eq '$app_display_name'" --query '[0]' --output json)
else
  printf 'More than one app registration is named %s; remove duplicates before continuing.\n' "$app_display_name" >&2
  exit 1
fi

deployer_client_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["appId"])' <<<"$app_json")
deployer_object_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$app_json")
set_graph_notes applications "$deployer_object_id" \
  'GitHub OIDC identity used only to deploy the demo-llm-oauth POC into its dedicated Azure resource group.'

if ! az ad sp show --id "$deployer_client_id" --output none 2>/dev/null; then
  az ad sp create --id "$deployer_client_id" --output none
fi
deployer_sp_object_id=$(az ad sp show --id "$deployer_client_id" --query id --output tsv)
set_graph_notes servicePrincipals "$deployer_sp_object_id" \
  'Tenant service principal for GitHub Actions OIDC deployments of the demo-llm-oauth POC; access is scoped to the POC resource group.'

resource_group_scope="/subscriptions/${subscription_id}/resourceGroups/${resource_group}"
role_assignment_count=$(az role assignment list \
  --assignee-object-id "$deployer_sp_object_id" \
  --scope "$resource_group_scope" \
  --role Contributor \
  --query 'length(@)' \
  --output tsv)
role_assignment_pending=false
if [[ "$role_assignment_count" == '0' ]]; then
  if ! az role assignment create \
      --assignee-object-id "$deployer_sp_object_id" \
      --assignee-principal-type ServicePrincipal \
      --role Contributor \
      --scope "$resource_group_scope" \
      --output none 2>/dev/null; then
    role_assignment_pending=true
  fi
fi

repository_owner=${repository%%/*}
repository_name=${repository#*/}
repository_owner_id=$(gh api "repos/${repository}" --jq '.owner.id')
repository_id=$(gh api "repos/${repository}" --jq '.id')
credential_name="github-${github_environment}-immutable"
credential_subject="repo:${repository_owner}@${repository_owner_id}/${repository_name}@${repository_id}:environment:${github_environment}"
existing_credential=$(az ad app federated-credential list \
  --id "$deployer_object_id" \
  --query "[?name=='${credential_name}'] | [0]" \
  --output json)

if [[ "$existing_credential" == 'null' || -z "$existing_credential" ]]; then
  credential_file=$(mktemp)
  trap 'rm -f "$credential_file"' EXIT
  cat > "$credential_file" <<EOF
{
  "name": "$credential_name",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "$credential_subject",
  "description": "GitHub Actions immutable repository subject for environment $github_environment",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
  az ad app federated-credential create \
    --id "$deployer_object_id" \
    --parameters "$credential_file" \
    --output none
else
  existing_subject=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["subject"])' <<<"$existing_credential")
  if [[ "$existing_subject" != "$credential_subject" ]]; then
    printf 'Federated credential %s exists with subject %s, expected %s.\n' \
      "$credential_name" "$existing_subject" "$credential_subject" >&2
    exit 1
  fi
fi

install -d -m 0700 "$(dirname "$output_file")"
umask 077
{
  printf 'AZURE_CLIENT_ID=%q\n' "$deployer_client_id"
  printf 'AZURE_PRINCIPAL_OBJECT_ID=%q\n' "$deployer_sp_object_id"
  printf 'AZURE_TENANT_ID=%q\n' "$tenant_id"
  printf 'AZURE_SUBSCRIPTION_ID=%q\n' "$subscription_id"
  printf 'AZURE_RESOURCE_GROUP=%q\n' "$resource_group"
  printf 'AZURE_LOCATION=%q\n' "$location"
  printf 'AZURE_DNS_LABEL=%q\n' "$dns_label"
  printf 'VM_ADMIN_USERNAME=%q\n' "$vm_admin_username"
  printf 'VM_ADMIN_SSH_PUBLIC_KEY=%q\n' "$ssh_public_key"
  printf 'PUBLIC_HOSTNAME=%q\n' "$public_hostname"
  printf 'GITHUB_ENVIRONMENT=%q\n' "$github_environment"
  printf 'ROLE_ASSIGNMENT_PENDING=%q\n' "$role_assignment_pending"
} > "$output_file"
chmod 0600 "$output_file"

cat <<EOF

Bootstrap complete.
Public URL: https://$public_hostname
OIDC subject: $credential_subject
Values written to: $output_file
EOF

if [[ "$role_assignment_pending" == true ]]; then
  cat <<EOF

ACTION REQUIRED: the signed-in identity cannot create role assignments.
Ask a User Access Administrator or Owner to run:

  az role assignment create \\
    --assignee-object-id '$deployer_sp_object_id' \\
    --assignee-principal-type ServicePrincipal \\
    --role Contributor \\
    --scope '$resource_group_scope'
EOF
fi

cat <<EOF

Configure the GitHub environment variables with:
  set -a
  source '$output_file'
  set +a
  gh variable set AZURE_CLIENT_ID --env '$github_environment' --body "\$AZURE_CLIENT_ID"
  gh variable set AZURE_TENANT_ID --env '$github_environment' --body "\$AZURE_TENANT_ID"
  gh variable set AZURE_SUBSCRIPTION_ID --env '$github_environment' --body "\$AZURE_SUBSCRIPTION_ID"
  gh variable set AZURE_RESOURCE_GROUP --env '$github_environment' --body "\$AZURE_RESOURCE_GROUP"
  gh variable set AZURE_LOCATION --env '$github_environment' --body "\$AZURE_LOCATION"
  gh variable set AZURE_DNS_LABEL --env '$github_environment' --body "\$AZURE_DNS_LABEL"
  gh variable set VM_ADMIN_USERNAME --env '$github_environment' --body "\$VM_ADMIN_USERNAME"
  gh variable set VM_ADMIN_SSH_PUBLIC_KEY --env '$github_environment' --body "\$VM_ADMIN_SSH_PUBLIC_KEY"
EOF
