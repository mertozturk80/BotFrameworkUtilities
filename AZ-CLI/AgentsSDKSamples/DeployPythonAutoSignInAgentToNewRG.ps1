# ============================================================
# Script: Creates a Bot Channel Registration + Python Agents SDK auto-signin bot on Azure App Service (Linux)
# ============================================================

# Summary:
# - Logs in and sets the subscription
# - Creates Resource Group, Linux App Service plan and Web App (Python runtime)
# - Registers Entra app + secret (1-week expiry)
# - Creates two OAuth connections (Graph + GitHub) on the Azure Bot
# - Sets app settings for Bot Service auth (env-var style for Python SDK)
# - Creates Azure Bot (channel registration)
# - (Best-effort) captures Direct Line secret
# - Clones the Python auto-signin Agents SDK sample, deploys to App Service
#
# Required parameters: SubscriptionId, RG, Location, Suffix
# You MUST supply GraphOAuthConnectionName and GitHubOAuthConnectionName
# (the names of the OAuth connections you configure on the Azure Bot).
# Optional: DLSecret (if captured)

# ============================================================
# 0) Fixed parameters. Edit ONLY subscription, suffix, and OAuth connection names.
# ============================================================
$SubscriptionId = "YOUR_SUBSCRIPTION_ID"

$RG             = "BotResourceGroup"
$Location       = "westeurope"
$Suffix         = "1234"

$PlanName       = "pyautosignin-lin-plan" + $Suffix
$WebAppName     = "pyautosigninagent" + $Suffix       # MUST be globally unique; change if taken
$PythonVersion  = "3.11"                               # Python 3.11

$BotName        = "pyautosignin-bot" + $Suffix
$AppRegName     = "pyautosignin-aad" + $Suffix
$OAuthAppRegName = "pyautosignin-oauth-aad" + $Suffix   # Separate app reg for OAuth connections

# Regional Direct Line endpoint — use the region closest to your bot.
# Available regions: https://learn.microsoft.com/azure/bot-service/rest-api/bot-framework-rest-direct-line-3-0-api-reference
#   Global (default):  https://directline.botframework.com
#   Europe:            https://europe.directline.botframework.com
#   India:             https://india.directline.botframework.com
#   Japan:             https://japaneast.directline.botframework.com
$DirectLineEndpoint = "https://europe.directline.botframework.com"

# OAuth connection names – these will be registered on the Azure Bot
# and referenced by the Python agent's env vars.
$GraphOAuthConnectionName  = "GraphConnection"
$GitHubOAuthConnectionName = "GitHubConnection"

# GitHub OAuth App credentials (required for the GitHub OAuth connection)
# Create at: https://github.com/settings/developers -> OAuth Apps
# Callback URL: https://token.botframework.com/.auth/web/redirect
$GitHubClientId     = "YOUR_GITHUB_OAUTH_CLIENT_ID"
$GitHubClientSecret = "YOUR_GITHUB_OAUTH_CLIENT_SECRET"

# ============================================================
# 1) Login + set subscription
# ============================================================
az login
az account set --subscription $SubscriptionId

# ============================================================
# 2) Create RG
# ============================================================
az group create --name $RG --location $Location

# ============================================================
# 3) Create Linux App Service Plan + WebApp (Python)
# ============================================================
az appservice plan create `
  --resource-group $RG `
  --name $PlanName `
  --location $Location `
  --sku S1 `
  --is-linux

az webapp create `
  --resource-group $RG `
  --name $WebAppName `
  --plan $PlanName `
  --runtime "PYTHON:$PythonVersion"

# Enable WebSockets (useful for Bot Service and Web Chat)
az webapp config set `
  --resource-group $RG `
  --name $WebAppName `
  --web-sockets-enabled true

# Keep the app warm (recommended for bots; requires Basic+ SKUs)
az webapp config set `
  --resource-group $RG `
  --name $WebAppName `
  --always-on true

$WebAppUrl   = "https://$WebAppName.azurewebsites.net"
$BotEndpoint = "$WebAppUrl/api/messages"

Write-Host "WebAppUrl:   $WebAppUrl"
Write-Host "BotEndpoint: $BotEndpoint"

# ============================================================
# 4) Create Entra App Registration + SP + Secret (1-week expiry)
# ============================================================
$App       = az ad app create --display-name $AppRegName | ConvertFrom-Json
$AppId     = $App.appId
az ad sp create --id $AppId | Out-Null

$END_DATE = (Get-Date).ToUniversalTime().AddDays(7).ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Host "End date for secret: $END_DATE"

$Secret     = az ad app credential reset --id "$AppId" --display-name "autosignin-secret" --end-date "$END_DATE" | ConvertFrom-Json
$AppSecret  = $Secret.password
$TenantId   = (az account show | ConvertFrom-Json).tenantId

Write-Host "Azure AppId: $AppId"
Write-Host "TenantId:    $TenantId"
Write-Host "AppSecret:   $AppSecret"

# ============================================================
# 5) Set Web App settings (Python Agents SDK env-var style)
# ============================================================
# The Python Agents SDK reads configuration from environment variables
# using double-underscore (__) as the separator for nested config.
az webapp config appsettings set `
  --resource-group $RG `
  --name $WebAppName `
  --settings `
  "SCM_DO_BUILD_DURING_DEPLOYMENT=true" `
  "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$AppId" `
  "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=$AppSecret" `
  "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$TenantId" `
  "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__GRAPH__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME=$GraphOAuthConnectionName" `
  "AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__GITHUB__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME=$GitHubOAuthConnectionName" `
  "PORT=8000"

# Configure the startup command — run main.py directly (avoids module-path issues with Oryx)
az webapp config set `
  --resource-group $RG `
  --name $WebAppName `
  --startup-file "python src/main.py"

# Enable logging
az webapp log config `
  --resource-group $RG `
  --name $WebAppName `
  --application-logging filesystem `
  --detailed-error-messages true `
  --failed-request-tracing true `
  --web-server-logging filesystem

az webapp restart --resource-group $RG --name $WebAppName

# ============================================================
# 6) Create Azure Bot (registration)
# Location Can be also "global" for Bot registration, but keep same as RG for simplicity
# ============================================================
az bot create `
  --resource-group $RG `
  --name $BotName `
  --location $Location `
  --appid $AppId `
  --app-type SingleTenant `
  --tenant-id $TenantId `
  --endpoint $BotEndpoint `
  --sku S1

$BotResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$RG/providers/Microsoft.BotService/botServices/$BotName"
az resource show --ids $BotResourceId | Out-Null

Write-Host "BotResourceId: $BotResourceId"

# ============================================================
# 6a) Create a SEPARATE Entra App Registration for OAuth connections
#     Ref: https://learn.microsoft.com/azure/bot-service/bot-builder-authentication
#     Section: "Create the Microsoft Entra ID identity provider"
#
#     Key guidelines:
#       - Do NOT reuse the bot's AppId.
#       - Set supported account types (sign-in audience).
#       - Add Web redirect URIs for the Bot Framework token service.
#       - Explicitly add Microsoft Graph delegated API permissions.
#       - Create a client secret.
# ============================================================
Write-Host "Creating separate Entra App Registration for OAuth: $OAuthAppRegName"

# Create the app with explicit sign-in audience.
# Use "AzureADMyOrg" for single-tenant (only users in this tenant).
# Use "AzureADMultipleOrgs" for multi-tenant (any AAD directory).
# Use "AzureADandPersonalMicrosoftAccount" for AAD + personal MSAs.
# If you chose multi-tenant or personal, set tenantId to "common" in the OAuth connection below.
$OAuthApp = az ad app create `
  --display-name $OAuthAppRegName `
  --sign-in-audience "AzureADMyOrg" | ConvertFrom-Json
$OAuthAppId = $OAuthApp.appId
az ad sp create --id $OAuthAppId | Out-Null

Write-Host "OAuth AppId: $OAuthAppId"

# --- Configure Web platform redirect URIs ---
# The Bot Framework token service uses these endpoints for the OAuth flow.
# These are the default public-cloud redirect URIs (no data-residency requirements).
# See: https://learn.microsoft.com/azure/bot-service/ref-oauth-redirect-urls
$RedirectUri1 = "https://token.botframework.com"
$RedirectUri2 = "https://token.botframework.com/.auth/web/redirect"
$RedirectUri3 = "https://europe.token.botframework.com/.auth/web/redirect"

Write-Host "Setting Web redirect URIs on OAuth app: $RedirectUri1, $RedirectUri2, $RedirectUri3"
az ad app update --id $OAuthAppId `
  --web-redirect-uris $RedirectUri1 $RedirectUri2 $RedirectUri3

Write-Host "OAuth App redirect URIs configured successfully."

# --- Create a client secret for the OAuth app (1-week expiry) ---
$OAuthSecretObj  = az ad app credential reset --id "$OAuthAppId" --display-name "oauth-secret" --end-date "$END_DATE" | ConvertFrom-Json
$OAuthAppSecret  = $OAuthSecretObj.password

Write-Host "OAuth AppSecret: $OAuthAppSecret"

# --- Add Microsoft Graph delegated API permissions ---
# Per the docs: "It's a best practice to explicitly set the API permissions for the app."
# Microsoft Graph API app ID: 00000003-0000-0000-c000-000000000000
# Delegated permission GUIDs (from MS Graph):
#   openid   = 37f7f235-527c-4136-accd-4a02d197296e
#   profile  = 14dad69e-099b-42c9-810b-d002981feec1
#   User.Read = e1fe6dd8-ba31-4d61-89e7-88639da4683d
$GraphApiId = "00000003-0000-0000-c000-000000000000"

Write-Host "Adding Microsoft Graph delegated permissions (openid, profile, User.Read)..."
az ad app permission add --id $OAuthAppId `
  --api $GraphApiId `
  --api-permissions `
  "37f7f235-527c-4136-accd-4a02d197296e=Scope" `
  "14dad69e-099b-42c9-810b-d002981feec1=Scope" `
  "e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope"

# Grant admin consent for the permissions (optional — end users can also consent at first login)
Write-Host "Granting admin consent for Microsoft Graph permissions..."
az ad app permission admin-consent --id $OAuthAppId 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "WARN: Admin consent failed (you may not be a tenant admin). Users will be prompted to consent at first login."
}

Write-Host "OAuth App Registration complete."
Write-Host "  AppId:          $OAuthAppId"
Write-Host "  Sign-in audience: AzureADMyOrg (single-tenant)"
Write-Host "  Redirect URIs:  $RedirectUri1, $RedirectUri2"
Write-Host "  Graph perms:    openid, profile, User.Read"

# ============================================================
# 6b) Create OAuth Connection Settings on the Azure Bot
# ============================================================
# --- Graph (Azure AD v2) OAuth Connection ---
# Uses the dedicated OAuth app (OAuthAppId / OAuthAppSecret), NOT the bot's identity.
# The scopes field is a space-separated, case-sensitive list of delegated permissions.
Write-Host "Creating Graph OAuth connection: $GraphOAuthConnectionName"
az bot authsetting create `
  --resource-group $RG `
  --name $BotName `
  --setting-name $GraphOAuthConnectionName `
  --provider-scope-string "openid profile User.Read" `
  --client-id $OAuthAppId `
  --client-secret $OAuthAppSecret `
  --service "Aadv2" `
  --parameters "tenantId=$TenantId"

# --- GitHub OAuth Connection ---
Write-Host "Creating GitHub OAuth connection: $GitHubOAuthConnectionName"
Write-Host "NOTE: You must supply valid GitHub OAuth App credentials (GitHubClientId / GitHubClientSecret)."
Write-Host "      Create one at: https://github.com/settings/developers -> OAuth Apps"
Write-Host "      Callback URL:  https://token.botframework.com/.auth/web/redirect"
az bot authsetting create `
  --resource-group $RG `
  --name $BotName `
  --setting-name $GitHubOAuthConnectionName `
  --client-id $GitHubClientId `
  --client-secret $GitHubClientSecret `
  --service "GitHub" `
  --provider-scope-string "user repo"

# ============================================================
# 6c) OPTIONAL - 
#     Enable enhanced authentication on Direct Line channel
#     Required for OAuth sign-in to work in "Test in Web Chat"
#     Without this, the token exchange / magic code flow fails
#     and the sign-in popup shows an empty page.
#     Ref: https://learn.microsoft.com/azure/bot-service/bot-builder-concept-authentication
# ============================================================
$ApiVersion = '2023-09-15-preview'
$BaseUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$RG/providers/Microsoft.BotService/botServices/$BotName/channels/DirectLineChannel"

Write-Host "Enabling enhanced authentication on Direct Line channel..."
$enhancedAuthBody = @{
  properties = @{
    channelName = "DirectLineChannel"
    properties = @{
      enhancedAuthenticationEnabled = $true
      sites = @(
        @{
          siteName = "Default Site"
          isEnabled = $true
          isWebChatSpeechEnabled = $false
          isWebchatPreviewEnabled = $true
          trustedOrigins = @(
            "https://portal.azure.com",
            "https://ms.portal.azure.com",
            "http://localhost:8080"
          )
        }
      )
    }
  }
} | ConvertTo-Json -Depth 5 -Compress

# Write body to a temp file to avoid shell escaping issues with az rest
$enhancedAuthFile = Join-Path $env:TEMP "enhanced-auth-body.json"
$enhancedAuthBody | Set-Content -Path $enhancedAuthFile -Encoding utf8

# Use PUT to create/replace the Direct Line channel with enhanced auth enabled
az rest --method put `
  --uri "$BaseUri`?api-version=$ApiVersion" `
  --body "@$enhancedAuthFile" `
  --headers "Content-Type=application/json" `
  -o json | Out-Null

Remove-Item $enhancedAuthFile -ErrorAction SilentlyContinue

if ($LASTEXITCODE -eq 0) {
  Write-Host "Enhanced authentication enabled on Direct Line with trusted origins for Azure Portal."
} else {
  Write-Host "WARN: Failed to enable enhanced authentication. You can enable it manually in the Azure Portal:"
  Write-Host "      Bot resource -> Channels -> Direct Line -> Enhanced authentication"
}

# ============================================================
# 6d) Capture Azure Bot Direct Line secret (best-effort)
# ============================================================
$ListKeysUrl = "$BaseUri/listChannelWithKeys?api-version=$ApiVersion"

$DLSecret = $null
try {
  $responseJson = az rest `
    --method post `
    --uri $ListKeysUrl `
    --body '{}' `
    -o json

  $response = $responseJson | ConvertFrom-Json
  $sites = $response.properties.properties.sites
  $site = $sites | Select-Object -First 1
  if ($site) {
    $DLSecret = $site.key
  }
} catch {
  Write-Host "WARN: listChannelWithKeys failed: $($_.Exception.Message)"
}

if ($DLSecret) {
  Write-Host "Captured DLSecret (keep secure): $DLSecret"
} else {
  Write-Host "DLSecret not retrievable via API. Regenerate in Portal and store in Key Vault, or set DLSecret manually."
  $DLSecret = "ToBeSetManually"
}

# ============================================================
# 7) Clone + deploy Python auto-signin sample
#    Repo: https://github.com/microsoft/Agents
#    Sample: samples/python/auto-signin
# ============================================================

$ORIGINAL_WD = (Get-Location).Path

# --- Clone / update repo ---
$RepoUrl    = "https://github.com/microsoft/Agents.git"
$RepoFolder = "Agents"
$LocalRepo  = Join-Path $ORIGINAL_WD $RepoFolder

Set-Location $ORIGINAL_WD
if (Test-Path $LocalRepo) {
  Write-Host "Repository folder exists, pulling latest changes..."
  Set-Location $LocalRepo
  git pull
} else {
  Write-Host "Cloning repository..."
  git clone $RepoUrl
  Set-Location $LocalRepo
}

# --- Sample paths ---
$BotPath = Join-Path $LocalRepo "samples\python\auto-signin"
if (-not (Test-Path $BotPath)) { throw "Auto-signin sample not found: $BotPath" }

Write-Host "BotPath: $BotPath"

# --- Verify requirements.txt exists ---
$RequirementsFile = Join-Path $BotPath "requirements.txt"
if (-not (Test-Path $RequirementsFile)) { throw "requirements.txt not found in: $BotPath" }
Write-Host "Found requirements.txt: $RequirementsFile"

# --- Create .env file with bot credentials ---
# On Azure App Service the env vars are set via App Settings (step 5),
# but we also include a .env for completeness (dotenv is loaded by the sample).
$EnvFilePath = Join-Path $BotPath ".env"
$envContent = @"
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=$AppId
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET=$AppSecret
CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID=$TenantId

AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__GRAPH__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME=$GraphOAuthConnectionName
AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__GITHUB__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME=$GitHubOAuthConnectionName
"@

$envContent | Set-Content -Path $EnvFilePath -Encoding utf8
Write-Host "Created .env at: $EnvFilePath"

# --- Patch start_server.py to bind to 0.0.0.0 and cast PORT to int (required for App Service) ---
$StartServerFile = Join-Path $BotPath "src\start_server.py"
if (Test-Path $StartServerFile) {
  $content = Get-Content $StartServerFile -Raw
  # Replace host="localhost" with host="0.0.0.0" so App Service can route traffic
  if ($content -match 'host="localhost"') {
    $content = $content -replace 'host="localhost"', 'host="0.0.0.0"'
    Write-Host "Patched start_server.py: host changed from localhost to 0.0.0.0"
  }
  # Cast PORT env var to int — environ.get returns a string, but aiohttp run_app requires int
  if ($content -match 'port=environ\.get\("PORT",\s*3978\)') {
    $content = $content -replace 'port=environ\.get\("PORT",\s*3978\)', 'port=int(environ.get("PORT", 3978))'
    Write-Host "Patched start_server.py: PORT cast to int"
  }
  $content | Set-Content -Path $StartServerFile -Encoding utf8
}

# --- Ensure src/__init__.py exists (required for 'python -m src.main') ---
$InitPyFile = Join-Path $BotPath "src\__init__.py"
if (-not (Test-Path $InitPyFile)) {
  Write-Host "Creating src/__init__.py (required for Python package resolution)..."
  "" | Set-Content -Path $InitPyFile -Encoding utf8
}

# --- Patch main.py to add enhanced logging configuration ---
$MainPyFile = Join-Path $BotPath "src\main.py"
if (Test-Path $MainPyFile) {
  Write-Host "Patching main.py with enhanced logging configuration..."
  $mainPyContent = @'
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

import logging
import os
import sys

# Ensure the app root (parent of src/) is on sys.path so absolute imports work
# when running directly via 'python src/main.py' (required for Oryx deployments)
_app_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _app_root not in sys.path:
    sys.path.insert(0, _app_root)

def configure_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout
    )

    # Agents SDK python packages — verbose debug logging
    logging.getLogger("microsoft_agents").setLevel(logging.DEBUG)

    # aiohttp internals + access logs
    logging.getLogger("aiohttp.access").setLevel(logging.INFO)
    logging.getLogger("aiohttp.server").setLevel(logging.INFO)
    logging.getLogger("aiohttp.web").setLevel(logging.INFO)

    # Optional: uncomment for very verbose HTTP-level details:
    # logging.getLogger("aiohttp.client").setLevel(logging.DEBUG)
    # logging.getLogger("aiohttp.internal").setLevel(logging.DEBUG)

configure_logging()

from src.agent import AGENT_APP, CONNECTION_MANAGER
from src.start_server import start_server

start_server(
    agent_application=AGENT_APP,
    auth_configuration=CONNECTION_MANAGER.get_default_connection_configuration(),
)
'@
  $mainPyContent | Set-Content -Path $MainPyFile -Encoding utf8
  Write-Host "Patched main.py: enhanced logging for microsoft_agents + aiohttp"
}

# --- Display sample contents ---
Write-Host ""
Write-Host "Sample files:"
Get-ChildItem $BotPath -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($BotPath.Length + 1)
  Write-Host "  - $rel"
}
Write-Host ""

# --- ZIP deploy Python application to Linux App Service ---
Set-Location $BotPath
$ZipPath = Join-Path $ORIGINAL_WD "bot.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

Write-Host "Creating deployment package from sample..."
Compress-Archive -Path (Join-Path $BotPath "*") -DestinationPath $ZipPath -Force
$ZipPath = (Resolve-Path $ZipPath).Path
Set-Location $ORIGINAL_WD

Write-Host "Deploying Python application to Linux App Service..."
# SCM_DO_BUILD_DURING_DEPLOYMENT=true triggers Oryx to run pip install -r requirements.txt
az webapp deploy --resource-group $RG --name $WebAppName --src-path $ZipPath --type zip

Write-Host "Restarting web app..."
az webapp restart --resource-group $RG --name $WebAppName

Write-Host ""
Write-Host "Deployment complete!"
Write-Host ""
Write-Host "Next steps:"
Write-Host "   1. Wait 60-90 seconds for the app to install dependencies and start"
Write-Host "   2. Check logs: az webapp log tail --resource-group $RG --name $WebAppName"
Write-Host "   3. View Log Stream in Azure Portal: https://portal.azure.com"
Write-Host "   4. Test endpoint: $BotEndpoint"
Write-Host "   5. Test in Web Chat from the Azure Bot resource in the Portal"
Write-Host ""
Write-Host "OAuth Connections:"
Write-Host "   - Graph connection:  $GraphOAuthConnectionName (Azure AD v2)"
Write-Host "   - GitHub connection: $GitHubOAuthConnectionName (GitHub)"
Write-Host ""
Write-Host "Bot Commands:"
Write-Host "   /status  - Check auth status for Graph and GitHub"
Write-Host "   /me      - Show your Microsoft Graph profile (triggers Graph OAuth)"
Write-Host "   /prs     - Show your GitHub pull requests (triggers GitHub OAuth)"
Write-Host "   /logout  - Sign out of all connections"
Write-Host ""
Write-Host "IMPORTANT:"
Write-Host "   - If the GitHub OAuth connection fails, ensure you set valid GitHubClientId"
Write-Host "     and GitHubClientSecret at the top of this script (from github.com/settings/developers)."
Write-Host "   - The callback URL for the GitHub OAuth App must be:"
Write-Host "     https://token.botframework.com/.auth/web/redirect"
Write-Host ""

# ============================================================
# ===== REPLAY VARS OUTPUT (single one-liner for copy/paste) =====
# ============================================================
function Build-AssignPair {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter()][object]$Value
  )
  $text = [string]$Value
  $escaped = $text -replace "'", "''"
  return ("`$" + $Name + "='" + $escaped + "'")
}

$pairs = @()
$pairs += Build-AssignPair 'SubscriptionId' $SubscriptionId
$pairs += Build-AssignPair 'RG' $RG
$pairs += Build-AssignPair 'Location' $Location
$pairs += Build-AssignPair 'Suffix' $Suffix
$pairs += Build-AssignPair 'PlanName' $PlanName
$pairs += Build-AssignPair 'WebAppName' $WebAppName
$pairs += Build-AssignPair 'PythonVersion' $PythonVersion
$pairs += Build-AssignPair 'BotName' $BotName
$pairs += Build-AssignPair 'AppRegName' $AppRegName

$pairs += Build-AssignPair 'WebAppUrl' $WebAppUrl
$pairs += Build-AssignPair 'BotEndpoint' $BotEndpoint

$pairs += Build-AssignPair 'AppId' $AppId
$pairs += Build-AssignPair 'TenantId' $TenantId
$pairs += Build-AssignPair 'END_DATE' $END_DATE
$pairs += Build-AssignPair 'AppSecret' $AppSecret   # Sensitive

$pairs += Build-AssignPair 'BotResourceId' $BotResourceId

$pairs += Build-AssignPair 'GraphOAuthConnectionName' $GraphOAuthConnectionName
$pairs += Build-AssignPair 'GitHubOAuthConnectionName' $GitHubOAuthConnectionName

$pairs += Build-AssignPair 'OAuthAppRegName' $OAuthAppRegName
$pairs += Build-AssignPair 'OAuthAppId' $OAuthAppId       # Separate OAuth app
$pairs += Build-AssignPair 'OAuthAppSecret' $OAuthAppSecret # Sensitive

$pairs += Build-AssignPair 'RepoUrl' $RepoUrl
$pairs += Build-AssignPair 'LocalRepo' $LocalRepo
$pairs += Build-AssignPair 'BotPath' $BotPath
$pairs += Build-AssignPair 'ZipPath' $ZipPath
$pairs += Build-AssignPair 'ORIGINAL_WD' $ORIGINAL_WD

$pairs += Build-AssignPair 'DLSecret' $DLSecret      # Sensitive if set

Write-Output ($pairs -join '; ')
