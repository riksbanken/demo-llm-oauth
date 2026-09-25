#!/usr/bin/env bash
set -euo pipefail

public_hostname=''
github_environment='poc'
name_prefix='LLM OAuth POC'
output_file='deploy/azure/generated/entra-bootstrap.env'
secret_days=180

usage() {
  cat <<'EOF'
Usage: bootstrap-entra.sh --public-hostname HOSTNAME [options]

Options:
  --public-hostname HOSTNAME     HTTPS hostname used by Open WebUI (required)
  --github-environment NAME      GitHub environment (default: poc)
  --name-prefix TEXT             Entra display-name prefix (default: LLM OAuth POC)
  --output-file PATH             Generated secret environment file
  --secret-days DAYS             Open WebUI client-secret lifetime (default: 180)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-hostname) public_hostname=$2; shift 2 ;;
    --github-environment) github_environment=$2; shift 2 ;;
    --name-prefix) name_prefix=$2; shift 2 ;;
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

tenant_id=$(az account show --query tenantId --output tsv)
gateway_display_name="$name_prefix - LLM Gateway"
webui_display_name="$name_prefix - Open WebUI"
redirect_uri="https://${public_hostname}/oauth/oidc/callback"

for display_name in "$gateway_display_name" "$webui_display_name"; do
  count=$(az ad app list --filter "displayName eq '$display_name'" --query 'length(@)' --output tsv)
  if [[ "$count" != '0' ]]; then
    printf 'An app registration named %s already exists. Remove it or use --name-prefix.\n' "$display_name" >&2
    exit 1
  fi
done

scope_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

printf 'Creating the gateway API registration...\n'
gateway_json=$(az ad app create \
  --display-name "$gateway_display_name" \
  --sign-in-audience AzureADMyOrg \
  --requested-access-token-version 2 \
  --output json)
gateway_app_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["appId"])' <<<"$gateway_json")
gateway_object_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$gateway_json")
set_graph_notes applications "$gateway_object_id" \
  'Protected API registration for the demo-llm-oauth POC. Exposes llm.invoke so approved Open WebUI users can call the LLM gateway.'

az ad app update \
  --id "$gateway_app_id" \
  --identifier-uris "api://${gateway_app_id}" \
  --output none

cat > "$temp_dir/gateway-api.json" <<EOF
{
  "api": {
    "requestedAccessTokenVersion": 2,
    "oauth2PermissionScopes": [
      {
        "adminConsentDescription": "Allow Open WebUI to invoke the protected LLM gateway on behalf of the signed-in user.",
        "adminConsentDisplayName": "Invoke the LLM gateway",
        "id": "$scope_id",
        "isEnabled": true,
        "type": "Admin",
        "userConsentDescription": null,
        "userConsentDisplayName": null,
        "value": "llm.invoke"
      }
    ]
  }
}
EOF
az rest \
  --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${gateway_object_id}" \
  --headers 'Content-Type=application/json' \
  --body "@$temp_dir/gateway-api.json" \
  --output none
az ad sp create --id "$gateway_app_id" --output none
gateway_sp_object_id=$(az ad sp show --id "$gateway_app_id" --query id --output tsv)
set_graph_notes servicePrincipals "$gateway_sp_object_id" \
  'Enterprise application for the protected LLM Gateway API used by the demo-llm-oauth POC.'

printf 'Creating the Open WebUI registration...\n'
webui_json=$(az ad app create \
  --display-name "$webui_display_name" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "$redirect_uri" \
  --output json)
webui_app_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["appId"])' <<<"$webui_json")
webui_object_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$webui_json")
set_graph_notes applications "$webui_object_id" \
  'Confidential web client for the demo-llm-oauth POC. Signs users in with Entra and requests delegated llm.invoke access.'

cat > "$temp_dir/webui-claims.json" <<'EOF'
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
  }
}
EOF
az rest \
  --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${webui_object_id}" \
  --headers 'Content-Type=application/json' \
  --body "@$temp_dir/webui-claims.json" \
  --output none
az ad sp create --id "$webui_app_id" --output none
webui_sp_object_id=$(az ad sp show --id "$webui_app_id" --query id --output tsv)
set_graph_notes servicePrincipals "$webui_sp_object_id" \
  'Enterprise application for Open WebUI in the demo-llm-oauth POC. Access is limited to assigned users and groups.'

printf 'Adding the delegated gateway permission and granting admin consent...\n'
for attempt in $(seq 1 12); do
  if az ad app permission add \
      --id "$webui_app_id" \
      --api "$gateway_app_id" \
      --api-permissions "${scope_id}=Scope" \
      --output none 2>/dev/null; then
    break
  fi
  if [[ "$attempt" == '12' ]]; then
    printf 'Unable to add the delegated permission after waiting for directory replication.\n' >&2
    exit 1
  fi
  sleep 5
done

admin_consent_pending=false
for attempt in $(seq 1 12); do
  if az ad app permission admin-consent --id "$webui_app_id" --output none 2>/dev/null; then
    break
  fi
  if [[ "$attempt" == '12' ]]; then
    admin_consent_pending=true
    break
  fi
  sleep 5
done

for attempt in $(seq 1 12); do
  if az ad sp update \
      --id "$webui_app_id" \
      --set appRoleAssignmentRequired=true \
      --output none 2>/dev/null; then
    break
  fi
  if [[ "$attempt" == '12' ]]; then
    printf 'Unable to require enterprise-application assignment after waiting for directory replication.\n' >&2
    exit 1
  fi
  sleep 5
done

webui_secret_key=$(openssl rand -hex 32)
secret_end_date=$(date -u -d "+${secret_days} days" '+%Y-%m-%dT%H:%M:%SZ')
credential_file="$temp_dir/webui-credential.json"
az ad app credential reset \
  --id "$webui_app_id" \
  --append \
  --display-name 'Open WebUI POC' \
  --end-date "$secret_end_date" \
  --output json > "$credential_file"
webui_client_secret=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["password"])' "$credential_file")

install -d -m 0700 "$(dirname "$output_file")"
umask 077
{
  printf 'ENTRA_TENANT_ID=%q\n' "$tenant_id"
  printf 'GATEWAY_APP_ID=%q\n' "$gateway_app_id"
  printf 'WEBUI_CLIENT_ID=%q\n' "$webui_app_id"
  printf 'WEBUI_CLIENT_SECRET=%q\n' "$webui_client_secret"
  printf 'WEBUI_SECRET_KEY=%q\n' "$webui_secret_key"
  printf 'PUBLIC_HOSTNAME=%q\n' "$public_hostname"
  printf 'OPENID_REDIRECT_URI=%q\n' "$redirect_uri"
  printf 'ADMIN_CONSENT_PENDING=%q\n' "$admin_consent_pending"
} > "$output_file"
chmod 0600 "$output_file"

cat <<EOF

Entra bootstrap complete.
Gateway app ID: $gateway_app_id
Open WebUI app ID: $webui_app_id
Redirect URI: $redirect_uri
Client secret expires: $secret_end_date
Secrets written once to: $output_file
EOF

if [[ "$admin_consent_pending" == true ]]; then
  cat <<EOF

ACTION REQUIRED: tenant-wide admin consent could not be granted by the signed-in identity.
Ask an Entra administrator to run:

  az ad app permission admin-consent --id '$webui_app_id'
EOF
fi

cat <<EOF

Configure GitHub with:
  set -a
  source '$output_file'
  set +a
  gh variable set ENTRA_TENANT_ID --env '$github_environment' --body "\$ENTRA_TENANT_ID"
  gh variable set GATEWAY_APP_ID --env '$github_environment' --body "\$GATEWAY_APP_ID"
  gh variable set WEBUI_CLIENT_ID --env '$github_environment' --body "\$WEBUI_CLIENT_ID"
  gh secret set WEBUI_CLIENT_SECRET --env '$github_environment' --body "\$WEBUI_CLIENT_SECRET"
  gh secret set WEBUI_SECRET_KEY --env '$github_environment' --body "\$WEBUI_SECRET_KEY"

Final tenant-admin step: assign the allowed POC users or groups to the
'$webui_display_name' enterprise application before they sign in.
EOF
