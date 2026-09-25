# Azure POC deployment

This deployment runs the existing Docker Compose stack on one Ubuntu VM in
Azure. This is intentionally a POC architecture: it preserves Open WebUI's
local SQLite database and Docker named volume, avoids unsupported Compose
translation, and keeps operational complexity low.

The deployment creates:

- one Ubuntu 24.04 `Standard_B2s` VM in Sweden Central;
- a Standard public Load Balancer with separate static public IPs and Azure
  hostnames for Open WebUI and the Agentgateway management UI;
- a private-only VM NIC behind the Load Balancer;
- an NSG allowing inbound TCP 80 and 443 only;
- Caddy for automatic HTTPS and hostname-based reverse proxying;
- a read-only Agentgateway management UI protected by Entra OIDC SSO;
- an Azure Key Vault read by the VM's managed identity;
- a regional Azure OpenAI `gpt-4.1-mini` deployment at 10K TPM, consumed through
  Azure's OpenAI-compatible `/openai/v1` endpoint; and
- GitHub Actions deployment through Entra workload identity federation.

No VM password, SSH private key, Azure client secret, or Azure OpenAI key is
stored in GitHub. SSH is not publicly exposed.

All Azure resources are tagged with the application, environment, owner,
repository, management method, purpose, and a resource-specific description.
The GitHub deployment identity and all SSO applications also receive Entra
management notes describing their POC purpose.

## Prerequisites

You need:

- an Azure subscription with permission to create resource groups, app
  registrations, role assignments, and the resources in `main.bicep`;
- Azure OpenAI access and at least 10K TPM of regional `gpt-4.1-mini` Standard
  quota in Sweden Central;
- an Entra administrator able to create applications and grant tenant-wide
  admin consent in the same tenant as the selected Azure subscription;
- Azure CLI, GitHub CLI, Python 3, OpenSSL, and a Bash environment; and
- a break-glass SSH public key. The matching private key is not used by the
  workflow and port 22 remains closed.

Sign in and select the intended subscription:

```bash
az login
az account set --subscription '<subscription-id-or-name>'
```

Validate the repository before configuring cloud resources:

```bash
./deploy/azure/validate.sh
```

## 1. Bootstrap Azure and GitHub OIDC

Choose a globally recognizable DNS label of at most 40 lowercase characters.
Public-IP DNS labels need only be unique within the Azure region.

```bash
./deploy/azure/bootstrap-github-oidc.sh \
  --dns-label '<unique-poc-label>' \
  --ssh-public-key-file "$HOME/.ssh/id_ed25519.pub"
```

The script:

1. registers the required Azure providers;
2. creates `rg-demo-llm-oauth-poc` in Sweden Central;
3. reserves the static public IP and Azure hostname;
4. creates the GitHub deployment app/service principal;
5. grants it Contributor only on the POC resource group; and
6. creates an OIDC federated credential using GitHub's immutable organization
   and repository IDs for the `poc` environment.

It writes non-secret values to
`deploy/azure/generated/github-bootstrap.env`. The directory is gitignored.

Create the GitHub environment before running the printed `gh variable set`
commands:

```bash
gh api \
  --method PUT \
  repos/riksbanken/demo-llm-oauth/environments/poc
```

Then run the commands printed by the script. In the GitHub UI, protect the
`poc` environment so only `main` can deploy and add a required reviewer if
appropriate for the POC.

## 2. Create the Entra SSO registrations

Load the confirmed public hostname and create new app registrations:

```bash
set -a
source deploy/azure/generated/github-bootstrap.env
set +a

./deploy/azure/bootstrap-entra.sh \
  --public-hostname "$PUBLIC_HOSTNAME"
```

The script creates:

- **LLM OAuth POC - LLM Gateway**, exposing the admin-only delegated
  `llm.invoke` scope and issuing v2 access tokens; and
- **LLM OAuth POC - Open WebUI**, with the exact HTTPS callback URI, the
  optional ID-token `email` claim, delegated permission to `llm.invoke`,
  admin consent, and user assignment required.

It also creates a 180-day Open WebUI client secret and a persistent random
WebUI signing key. These are written once to
`deploy/azure/generated/entra-bootstrap.env` with mode `0600`.

Run the printed `gh variable set` and `gh secret set` commands immediately,
then protect or securely archive the generated file.

### Create the Agentgateway UI SSO registration

Create the dedicated OIDC client after reserving the UI hostname:

```bash
./deploy/azure/bootstrap-agentgateway-ui-entra.sh \
  --public-hostname "$AGENTGATEWAY_UI_HOSTNAME" \
  --access-group aifabriken-dev
```

This creates **LLM OAuth POC - Agentgateway UI**, registers the exact
`/oauth/callback` URI, requests only the delegated Microsoft Graph `openid`,
`profile`, and `email` scopes, requires enterprise-application assignment,
assigns the specified Entra group when permitted, and generates both the client
secret and the persistent OIDC cookie-encryption secret. If tenant policy blocks
user consent, an Entra administrator must grant consent using the command
printed by the script. Run the printed GitHub variable and secret commands
immediately.

The Agentgateway UI is configured globally read-only because GitHub and Bicep
own the deployed configuration. The unauthenticated local admin interface on
port 15000 remains bound to loopback and is never exposed.

### Assign POC users or groups

In the Azure portal:

1. Open **Microsoft Entra ID > Enterprise applications**.
2. Select **LLM OAuth POC - Open WebUI**.
3. Open **Users and groups**.
4. Assign only the users or groups allowed to use the POC.

The first assigned user to sign in becomes the initial Open WebUI
administrator. Sign in with the intended administrator first.

## 3. Check GitHub environment configuration

The `poc` environment must contain these variables:

| Variable | Source |
| --- | --- |
| `AZURE_CLIENT_ID` | GitHub OIDC bootstrap |
| `AZURE_TENANT_ID` | GitHub OIDC bootstrap |
| `AZURE_SUBSCRIPTION_ID` | GitHub OIDC bootstrap |
| `AZURE_RESOURCE_GROUP` | GitHub OIDC bootstrap |
| `AZURE_LOCATION` | `swedencentral` |
| `AZURE_DNS_LABEL` | GitHub OIDC bootstrap |
| `AZURE_UI_DNS_LABEL` | GitHub OIDC bootstrap |
| `VM_ADMIN_USERNAME` | GitHub OIDC bootstrap |
| `VM_ADMIN_SSH_PUBLIC_KEY` | GitHub OIDC bootstrap |
| `ENTRA_TENANT_ID` | Entra SSO bootstrap |
| `GATEWAY_APP_ID` | Entra SSO bootstrap |
| `WEBUI_CLIENT_ID` | Entra SSO bootstrap |
| `AGENTGATEWAY_UI_CLIENT_ID` | Agentgateway UI Entra bootstrap |
| `AGENTGATEWAY_UI_HOSTNAME` | Agentgateway UI Entra bootstrap |

It must contain these secrets:

- `WEBUI_CLIENT_SECRET`
- `WEBUI_SECRET_KEY`
- `AGENTGATEWAY_UI_CLIENT_SECRET`
- `AGENTGATEWAY_UI_COOKIE_SECRET`

Do not create an `AZURE_CLIENT_SECRET`; the workflow uses OIDC.

## 4. Deploy

Run **Deploy Azure POC** from the GitHub Actions UI. The workflow:

1. validates Compose, shell, and Bicep sources;
2. signs in to Azure through GitHub OIDC;
3. deploys the VM, networking, Key Vault, and Azure OpenAI model;
4. stores the application secrets and generated Azure OpenAI key in Key
   Vault;
5. sends the checked-out Compose files to the VM through Azure Run Command;
6. starts the stack and verifies local health; and
7. waits for Caddy to issue a certificate and verifies public HTTPS health.

After initial setup, relevant pushes to `main` redeploy automatically. Only one
POC deployment runs at a time.

Open the Open WebUI URL reported in the workflow summary, sign in through
Entra, select `llm`, and send a message. Open the Agentgateway UI URL and verify
that it redirects through Entra before serving the read-only management UI.

## Deployment behavior

The VM keeps releases under `/opt/llm-oauth/releases/<git-sha>` and runs all
releases with the stable Compose project name `llm-oauth`. Docker named volumes
therefore survive workflow deployments.

A deployment validates Compose before changing containers and recreates the
containers so embedded Compose config changes are always applied. Named volumes
preserve Open WebUI and Caddy state. Agentgateway request logs are stored in the
persistent host directory `/opt/llm-oauth/data/agentgateway` as SQLite. If Open
WebUI does not become healthy after an update, the script reapplies the previous
release. The newest three release directories are retained.

Open WebUI data is stored on the VM OS disk. It survives container replacement
and VM reboot, but it is not highly available and is lost if the VM/OS disk or
resource group is deleted. Back up the `llm-oauth_openwebui-data` Docker volume
before teardown if conversations or accounts must be retained.

## Security boundaries

- The Standard Load Balancer owns separate public IPs for Open WebUI and the
  Agentgateway UI and forwards only TCP 80 and 443 to the VM's private NIC.
- The Load Balancer also provides explicit outbound SNAT through the same
  static IP; no public IP is attached to the VM NIC.
- The NSG exposes only TCP 80 and 443 and permits the Load Balancer health
  probe on 443.
- Caddy is the only public container and separates the two applications by
  hostname.
- The Agentgateway management UI listener is protected by OIDC and operates in
  read-only configuration mode; the unauthenticated port-15000 admin interface
  remains loopback-only.
- Agentgateway stores request metadata, timing, token usage, status, and cost in
  a local SQLite database. Prompt and completion content is not persisted.
- Authenticated request logs use the signed Entra access-token identity:
  `email -> oid -> sub` for the user label, with tenant ID, object ID, and email
  retained as separate log attributes.
- Open WebUI and Agentgateway host ports remain bound to loopback.
- Open WebUI exposes the configured models to every authenticated user; Entra
  enterprise-application assignment controls who can enter the POC.
- Agentgateway validates tenant, issuer, audience, expiry, and `llm.invoke` on
  every inference request.
- The Azure OpenAI public endpoint accepts traffic only from the Load
  Balancer's static outbound public IP.
- The VM managed identity can read, but not manage, the three Key Vault
  secrets.
- GitHub's deployment identity is scoped to the POC resource group.

The Azure-provided hostname is convenient for a POC but shares an ACME
registered domain with other Azure users. If certificate issuance repeatedly
hits a shared-domain rate limit, move to an organizational custom hostname and
update Caddy, the Entra callback URI, and the GitHub/Compose hostname values.

## Verification

Check the public health endpoint:

```bash
curl -i "https://$PUBLIC_HOSTNAME/health"
```

Verify that the Agentgateway UI redirects to Entra:

```bash
curl -sS -o /dev/null -D- \
  "https://$AGENTGATEWAY_UI_HOSTNAME/ui" \
  | grep -i '^location: https://login.microsoftonline.com/'
```

The LLM data gateway is deliberately not public. To test it on the VM without
opening SSH, use Azure Run Command:

```bash
az vm run-command invoke \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "${AZURE_DNS_LABEL}-vm" \
  --command-id RunShellScript \
  --scripts 'curl -i http://127.0.0.1:4000/v1/models'
```

The unauthenticated request must return 401.

Inspect service state without exposing SSH:

```bash
az vm run-command invoke \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "${AZURE_DNS_LABEL}-vm" \
  --command-id RunShellScript \
  --scripts 'cd /opt/llm-oauth/current && docker compose -p llm-oauth --env-file .env -f compose.yaml -f compose.production.yaml -f compose.azure.yaml ps'
```

Common failures:

- **Azure OpenAI deployment failure:** verify regional Standard quota and model
  version availability in Sweden Central. The template intentionally does not
  fall back to a global deployment.
- **Key Vault 403 during VM deployment:** wait for the VM access policy to
  propagate and rerun the workflow.
- **OIDC login failure:** ensure the GitHub job environment is exactly `poc`
  and the federated credential subject matches it.
- **Entra sign-in denied:** assign the user/group to the Open WebUI enterprise
  application.
- **OAuth callback mismatch:** compare the registered redirect URI with
  `https://<hostname>/oauth/oidc/callback` exactly.
- **Caddy certificate failure:** verify public DNS, NSG ports 80/443, and ACME
  logs with `docker compose logs caddy` through Run Command.

## Cost controls

The main idle cost is the `Standard_B2s` VM. The repository includes
`.github/workflows/manage-azure-poc.yml`, which deallocates the VM every day at
18:07 Stockholm time and runs a second safety shutdown at 23:37. The schedule
uses `Europe/Stockholm`, so daylight-saving changes are automatic. Both the
management and deployment workflows share the same concurrency group, so a
scheduled shutdown cannot interrupt an active deployment.

Deallocation stops CPU/RAM billing but preserves the VM, Docker data, SQLite
databases, certificates, and hostnames. These resources still have independent
idle costs:

| Resource | Cost while VM is deallocated |
| --- | --- |
| 64 GiB Standard SSD OS disk | Continues to incur storage cost |
| Two Standard public IPs | Continue to incur hourly IP cost |
| Standard Load Balancer | Configured rules continue to incur the applicable hourly cost |
| Key Vault | No meaningful idle compute charge; operations are billed |
| Azure OpenAI Standard deployment | Pay-per-token; no inference charge while unused |
| VNet, NIC, and NSG | No direct hourly compute charge |
| Bandwidth | Charged only when traffic is transferred |

Use the **Manage Azure POC** workflow for manual control, or run:

```bash
gh workflow run manage-azure-poc.yml -f action=start
gh workflow run manage-azure-poc.yml -f action=status
gh workflow run manage-azure-poc.yml -f action=stop
```

`stop` uses Azure **deallocate**, not a guest operating-system shutdown. A VM
that is merely stopped but still allocated continues to incur compute charges.
`start` waits for both public endpoints to become healthy. Running the normal
deployment workflow also starts a deallocated VM before applying Compose.

GitHub notes that scheduled workflows can be delayed under load. The later
safety run reduces the chance that the VM remains allocated overnight. For zero
idle infrastructure cost, delete the resource group using the teardown process;
that also removes the persistent application data unless it is backed up first.

## Rotate Open WebUI secrets

Create a new base64url-safe client secret, add it to the existing Open WebUI
registration, and update GitHub:

```bash
NEW_SECRET=$(openssl rand -base64 48 | tr -d '\r\n=' | tr '+/' '-_')
END_DATE=$(date -u -d '+180 days' '+%Y-%m-%dT%H:%M:%SZ')
az ad app credential reset \
  --id "$WEBUI_CLIENT_ID" \
  --append \
  --display-name 'Open WebUI POC rotation' \
  --end-date "$END_DATE" \
  --password "$NEW_SECRET" \
  --output none

gh secret set WEBUI_CLIENT_SECRET --env poc --body "$NEW_SECRET"
unset NEW_SECRET
```

Run the deployment workflow, verify sign-in, and then remove the expired/old
credential from the app registration. Rotate `WEBUI_SECRET_KEY` only when
invalidating all existing sessions and stored OAuth tokens is acceptable.

Bicep retrieves the current primary Azure OpenAI account key and copies it to
Key Vault. After regenerating that key, rerun the deployment workflow so the
stored key and running gateway are refreshed together.

## Teardown

Back up Open WebUI data first if needed. Capture the soft-deletable resource
names, then delete the resource group:

```bash
KEY_VAULT_NAME=$(az keyvault list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query '[0].name' --output tsv)
OPENAI_ACCOUNT_NAME=$(az cognitiveservices account list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[?kind=='OpenAI'].name | [0]" --output tsv)

az group delete \
  --name "$AZURE_RESOURCE_GROUP" \
  --yes
```

If the same deterministic names may be reused, purge the soft-deleted
resources after group deletion. This is irreversible and requires purge
permissions:

```bash
az keyvault purge \
  --name "$KEY_VAULT_NAME" \
  --location "$AZURE_LOCATION"
az cognitiveservices account purge \
  --name "$OPENAI_ACCOUNT_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --location "$AZURE_LOCATION"
```

Delete the three app registrations separately; resource-group deletion does
not remove Entra applications:

```bash
set -a
source deploy/azure/generated/github-bootstrap.env
source deploy/azure/generated/entra-bootstrap.env
set +a

az ad app delete --id "$GATEWAY_APP_ID"
az ad app delete --id "$WEBUI_CLIENT_ID"
az ad app delete --id "$AZURE_CLIENT_ID"
```

Finally delete the GitHub `poc` environment or remove its variables and
secrets.
