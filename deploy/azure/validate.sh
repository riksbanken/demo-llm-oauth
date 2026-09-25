#!/usr/bin/env bash
set -euo pipefail

export ENTRA_TENANT_ID='00000000-0000-0000-0000-000000000001'
export GATEWAY_APP_ID='00000000-0000-0000-0000-000000000002'
export WEBUI_CLIENT_ID='00000000-0000-0000-0000-000000000003'
export WEBUI_CLIENT_SECRET='validation-client-secret'
export WEBUI_SECRET_KEY='validation-webui-secret'
export WEBUI_URL='https://validation.swedencentral.cloudapp.azure.com'
export PUBLIC_HOSTNAME='validation.swedencentral.cloudapp.azure.com'
export UPSTREAM_PROVIDER='openAI'
export UPSTREAM_MODEL='gpt-4.1-mini'
export UPSTREAM_BASE_URL='https://validation.openai.azure.com/openai/v1'
export UPSTREAM_API_KEY='validation-api-key'
export AZURE_RESOURCE_NAME='validation'
export AZURE_RESOURCE_TYPE='openAI'
export AZURE_API_VERSION='v1'

docker compose \
  --file compose.yaml \
  --file compose.production.yaml \
  --file compose.azure.yaml \
  config --quiet

for script in deploy/azure/*.sh; do
  bash -n "$script"
done

if command -v az >/dev/null 2>&1; then
  az bicep build --file deploy/azure/main.bicep --stdout >/dev/null
else
  printf 'Azure CLI not found; skipped Bicep compilation.\n' >&2
fi
