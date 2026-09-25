#!/usr/bin/env bash
set -euo pipefail

public_hostname=''
github_environment='poc'
name='LLM OAuth POC - Agentgateway UI'
access_group='aifabriken-dev'
output_file='deploy/azure/generated/agentgateway-ui-entra.env'
secret_days=180

usage() {
  cat <<'EOF'
Usage: bootstrap-agentgateway-ui-entra.sh --public-hostname HOSTNAME [options]

Options:
  --public-hostname HOSTNAME     Agentgateway UI HTTPS hostname (required)
  --github-environment NAME      GitHub environment (default: poc)
  --name TEXT                    Entra display name
  --access-group NAME            Entra security group to assign
  --output-file PATH             Generated secret environment file
  --secret-days DAYS             Client-secret lifetime (default: 180)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-hostname) public_hostname=$2; shift 2 ;;
    --github-environment) github_environment=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --access-group) access_group=$2; shift 2 ;;
    --output-file) output_file=$2; shift 2 ;;
    --secret-days) secret_days=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$public_hostname" =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf -- '--public-hostname must be a DNS hostname without scheme or path.\n' >&2
  exit 2
fi
if [[ ! "$secret_days" =~ ^[0-9]+$ || "$secret_days" -lt 1 ]]; then
  printf -- '--secret-days must be a positive integer.\n' >&2
  exit 2
fi

for command in az python3 openssl date; do
  command -v "$command" >/dev/null || { printf '%s is required.\n' "$command" >&2; exit 1; }
done
az account show >/dev/null

existing=$(az ad app list --filter "displayName eq '$name'" --query 'length(@)' --output tsv)
if [[ "$existing" != '0' ]]; then
  printf 'An app registration named %s already exists. Remove it or use --name.\n' "$name" >&2
  exit 1
fi

tenant_id=$(az account show --query tenantId --output tsv)
redirect_uri="https://${public_hostname}/oauth/callback"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

app_json=$(az ad app create \
  --display-name "$name" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "$redirect_uri" \
  --output json)
app_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["appId"])' <<<"$app_json")
app_object_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$app_json")

cat > "$temp_dir/application.json" <<'EOF'
{
  "optionalClaims": {
    "accessToken": [],
    "idToken": [
      {
        "additionalProperties": [],
        "essential": false,
        "name": "email",
        "source": null
      }
    ],
    "saml2Token": []
  },
  "notes": "OIDC client for the read-only Agentgateway management UI in the demo-llm-oauth POC."
}
EOF
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${app_object_id}" \
  --headers 'Content-Type=application/json' \
  --body "@$temp_dir/application.json" \
  --output none

az ad sp create --id "$app_id" --output none
sp_object_id=$(az ad sp show --id "$app_id" --query id --output tsv)
sp_notes=$(python3 -c 'import json; print(json.dumps({"notes":"Enterprise application for the SSO-protected, read-only Agentgateway UI. Access is limited to assigned users and groups."}))')
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_object_id}" \
  --headers 'Content-Type=application/json' \
  --body "$sp_notes" \
  --output none
az ad sp update --id "$app_id" --set appRoleAssignmentRequired=true --output none

secret_end_date=$(date -u -d "+${secret_days} days" '+%Y-%m-%dT%H:%M:%SZ')
credential_file="$temp_dir/credential.json"
az ad app credential reset \
  --id "$app_id" \
  --append \
  --display-name 'Agentgateway UI POC' \
  --end-date "$secret_end_date" \
  --output json > "$credential_file"
client_secret=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["password"])' "$credential_file")
cookie_secret=$(openssl rand -hex 32)

group_assignment_pending=false
group_id=$(az ad group show --group "$access_group" --query id --output tsv)
assignment_body=$(GROUP_ID="$group_id" SP_ID="$sp_object_id" python3 -c 'import json,os; print(json.dumps({"principalId":os.environ["GROUP_ID"],"resourceId":os.environ["SP_ID"],"appRoleId":"00000000-0000-0000-0000-000000000000"}))')
if ! az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_object_id}/appRoleAssignedTo" \
    --headers 'Content-Type=application/json' \
    --body "$assignment_body" \
    --output none 2>/dev/null; then
  group_assignment_pending=true
fi

install -d -m 0700 "$(dirname "$output_file")"
umask 077
{
  printf 'AGENTGATEWAY_UI_CLIENT_ID=%q\n' "$app_id"
  printf 'AGENTGATEWAY_UI_CLIENT_SECRET=%q\n' "$client_secret"
  printf 'AGENTGATEWAY_UI_COOKIE_SECRET=%q\n' "$cookie_secret"
  printf 'AGENTGATEWAY_UI_HOSTNAME=%q\n' "$public_hostname"
  printf 'AGENTGATEWAY_UI_REDIRECT_URI=%q\n' "$redirect_uri"
  printf 'AGENTGATEWAY_UI_SP_OBJECT_ID=%q\n' "$sp_object_id"
  printf 'CLIENT_SECRET_END_DATE=%q\n' "$secret_end_date"
  printf 'GROUP_ASSIGNMENT_PENDING=%q\n' "$group_assignment_pending"
} > "$output_file"
chmod 0600 "$output_file"

cat <<EOF

Agentgateway UI Entra bootstrap complete.
Client ID: $app_id
Redirect URI: $redirect_uri
Client secret expires: $secret_end_date
Secrets written once to: $output_file
EOF

if [[ "$group_assignment_pending" == true ]]; then
  cat <<EOF

ACTION REQUIRED: assign the Entra group '$access_group' to the '$name' enterprise application.
EOF
fi

cat <<EOF

Configure GitHub with:
  set -a
  source '$output_file'
  set +a
  gh variable set AGENTGATEWAY_UI_CLIENT_ID --env '$github_environment' --body "\$AGENTGATEWAY_UI_CLIENT_ID"
  gh variable set AGENTGATEWAY_UI_HOSTNAME --env '$github_environment' --body "\$AGENTGATEWAY_UI_HOSTNAME"
  gh secret set AGENTGATEWAY_UI_CLIENT_SECRET --env '$github_environment' --body "\$AGENTGATEWAY_UI_CLIENT_SECRET"
  gh secret set AGENTGATEWAY_UI_COOKIE_SECRET --env '$github_environment' --body "\$AGENTGATEWAY_UI_COOKIE_SECRET"
EOF
