#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 12 ]]; then
  printf 'Expected 12 positional deployment parameters, received %s.\n' "$#" >&2
  exit 2
fi

bundle_base64=$1
release_id=$2
key_vault_name=$3
public_hostname=$4
entra_tenant_id=$5
gateway_app_id=$6
webui_client_id=$7
upstream_model=$8
upstream_base_url=${9%/}
azure_resource_name=${10}
agentgateway_ui_hostname=${11}
agentgateway_ui_client_id=${12}

require_value() {
  local name=$1
  local value=$2
  if [[ -z "$value" ]]; then
    printf 'Missing required parameter: %s\n' "$name" >&2
    exit 2
  fi
}

require_value bundleBase64 "$bundle_base64"
require_value releaseId "$release_id"
require_value keyVaultName "$key_vault_name"
require_value publicHostname "$public_hostname"
require_value entraTenantId "$entra_tenant_id"
require_value gatewayAppId "$gateway_app_id"
require_value webuiClientId "$webui_client_id"
require_value upstreamModel "$upstream_model"
require_value upstreamBaseUrl "$upstream_base_url"
require_value azureResourceName "$azure_resource_name"
require_value agentgatewayUiHostname "$agentgateway_ui_hostname"
require_value agentgatewayUiClientId "$agentgateway_ui_client_id"

if [[ ! "$release_id" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  printf 'releaseId must be a Git commit SHA.\n' >&2
  exit 2
fi

exec 9>/var/lock/llm-oauth-deploy.lock
if ! flock -n 9; then
  printf 'Another llm-oauth deployment is already running.\n' >&2
  exit 1
fi

if [[ -f /var/lib/cloud/instance/boot-finished ]]; then
  :
else
  printf 'Waiting for cloud-init to finish...\n'
  timeout 900 bash -c 'until [[ -f /var/lib/cloud/instance/boot-finished ]]; do sleep 5; done'
fi

systemctl is-active --quiet docker

deployment_root=/opt/llm-oauth
release_dir="$deployment_root/releases/$release_id"
current_link="$deployment_root/current"
previous_release=''
if [[ -L "$current_link" ]]; then
  previous_release=$(readlink -f "$current_link" || true)
fi

rm -rf "$release_dir"
install -d -o root -g root -m 0750 "$release_dir"
printf '%s' "$bundle_base64" | base64 --decode | tar --extract --gzip --directory "$release_dir"

for required_file in compose.yaml compose.production.yaml compose.azure.yaml; do
  if [[ ! -f "$release_dir/$required_file" ]]; then
    printf 'Deployment bundle is missing %s.\n' "$required_file" >&2
    exit 1
  fi
done

get_managed_identity_token() {
  local response
  local token

  for attempt in $(seq 1 30); do
    response=$(curl --show-error --silent --noproxy '*' \
      --header 'Metadata: true' \
      'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fvault.azure.net' || true)
    if token=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' <<<"$response" 2>/dev/null) \
        && [[ -n "$token" ]]; then
      printf '%s\n' "$token"
      return 0
    fi
    sleep 5
  done

  printf 'Unable to obtain a managed identity token.\n' >&2
  return 1
}

managed_identity_token=$(get_managed_identity_token)

get_secret() {
  local secret_name=$1
  local response_file
  local status
  response_file=$(mktemp)

  for attempt in $(seq 1 30); do
    status=$(curl --show-error --silent --noproxy '*' \
      --output "$response_file" \
      --write-out '%{http_code}' \
      --header "Authorization: Bearer $managed_identity_token" \
      "https://${key_vault_name}.vault.azure.net/secrets/${secret_name}?api-version=7.4" || true)

    if [[ "$status" == '200' ]]; then
      python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["value"])' "$response_file"
      rm -f "$response_file"
      return 0
    fi

    if [[ "$status" == '401' ]]; then
      managed_identity_token=$(get_managed_identity_token)
    fi

    sleep 5
  done

  printf 'Unable to read Key Vault secret %s (last HTTP status %s).\n' "$secret_name" "$status" >&2
  rm -f "$response_file"
  return 1
}

webui_client_secret=$(get_secret webui-client-secret)
webui_secret_key=$(get_secret webui-secret-key)
upstream_api_key=$(get_secret azure-openai-api-key)
agentgateway_ui_client_secret=$(get_secret agentgateway-ui-client-secret)
agentgateway_ui_cookie_secret=$(get_secret agentgateway-ui-cookie-secret)

assert_single_line() {
  local name=$1
  local value=$2
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    printf '%s must not contain a newline.\n' "$name" >&2
    exit 1
  fi
}

for pair in \
  "WEBUI_CLIENT_SECRET:$webui_client_secret" \
  "WEBUI_SECRET_KEY:$webui_secret_key" \
  "UPSTREAM_API_KEY:$upstream_api_key" \
  "AGENTGATEWAY_UI_CLIENT_SECRET:$agentgateway_ui_client_secret" \
  "AGENTGATEWAY_UI_COOKIE_SECRET:$agentgateway_ui_cookie_secret"; do
  assert_single_line "${pair%%:*}" "${pair#*:}"
done

umask 077
cat > "$release_dir/.env" <<EOF
ENTRA_TENANT_ID=$entra_tenant_id
GATEWAY_APP_ID=$gateway_app_id
WEBUI_CLIENT_ID=$webui_client_id
WEBUI_CLIENT_SECRET=$webui_client_secret
WEBUI_SECRET_KEY=$webui_secret_key
WEBUI_URL=https://$public_hostname
PUBLIC_HOSTNAME=$public_hostname
UPSTREAM_PROVIDER=openAI
UPSTREAM_MODEL=$upstream_model
UPSTREAM_BASE_URL=$upstream_base_url/openai/v1
UPSTREAM_API_KEY=$upstream_api_key
AZURE_RESOURCE_NAME=$azure_resource_name
AZURE_RESOURCE_TYPE=openAI
AZURE_API_VERSION=v1
AGENTGATEWAY_UI_HOSTNAME=$agentgateway_ui_hostname
AGENTGATEWAY_UI_CLIENT_ID=$agentgateway_ui_client_id
AGENTGATEWAY_UI_CLIENT_SECRET=$agentgateway_ui_client_secret
AGENTGATEWAY_UI_COOKIE_SECRET=$agentgateway_ui_cookie_secret
EOF
chmod 0600 "$release_dir/.env"

compose_in() {
  local directory=$1
  shift
  docker compose \
    --project-name llm-oauth \
    --env-file "$directory/.env" \
    --file "$directory/compose.yaml" \
    --file "$directory/compose.production.yaml" \
    --file "$directory/compose.azure.yaml" \
    "$@"
}

rollback() {
  if [[ -n "$previous_release" && -d "$previous_release" && -f "$previous_release/.env" ]]; then
    printf 'Deployment failed; restoring previous release %s.\n' "$previous_release" >&2
    compose_in "$previous_release" up --detach --remove-orphans --force-recreate
  else
    printf 'Deployment failed and no previous release is available.\n' >&2
  fi
}

compose_in "$release_dir" config --quiet
compose_in "$release_dir" pull
if ! compose_in "$release_dir" up --detach --remove-orphans --force-recreate; then
  rollback
  exit 1
fi

healthy=false
for attempt in $(seq 1 36); do
  if curl --fail --show-error --silent --max-time 5 http://127.0.0.1:3000/health >/dev/null; then
    healthy=true
    break
  fi
  sleep 5
done

if [[ "$healthy" != true ]]; then
  printf 'Open WebUI did not become healthy.\n' >&2
  compose_in "$release_dir" ps >&2 || true
  compose_in "$release_dir" logs --tail 100 openwebui agentgateway caddy caddy-ui >&2 || true
  rollback
  exit 1
fi

gateway_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 5 http://127.0.0.1:4000/v1/models || true)
if [[ "$gateway_status" != '401' ]]; then
  printf 'Agentgateway unauthenticated check returned HTTP %s instead of 401.\n' "$gateway_status" >&2
  compose_in "$release_dir" logs --tail 100 agentgateway >&2 || true
  rollback
  exit 1
fi

ln --symbolic --force --no-dereference "$release_dir" "$current_link"

find "$deployment_root/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
  | sort --numeric-sort --reverse \
  | tail --lines=+4 \
  | cut --delimiter=' ' --fields=2- \
  | xargs --no-run-if-empty rm -rf --

docker image prune --force >/dev/null
printf 'Deployed release %s successfully.\n' "$release_id"
