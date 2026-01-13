
# ============================================================
# Script: Creates a Bot Channel Registration + Python Agents SDK bot on Azure App Service (Linux)
# ============================================================

# Summary:
# - Logs in and sets the subscription
# - Creates Resource Group, Linux App Service plan and Web App (WebSockets, Python runtime)
# - Registers Entra app + secret (1-week expiry)
# - Sets app settings for Bot Service auth
# - Creates Azure Bot (channel registration)
# - (Best-effort) captures Direct Line secret
# - Clones a Python Agents SDK quickstart bot sample, zips, and deploys to App Service
#
# Required parameters: SubscriptionId, RG, Location, Suffix (derives PlanName, WebAppName, BotName, AppRegName)
# Optional: DLSecret (if captured), used only by the test page (do not use in production)

# ============================================================
# 0) Fixed parameters. Edit ONLY subscription and suffix for uniqueness.
# ============================================================
$SubscriptionId = "xxxxxx-xxxxx-xxxx-xxxx-xxxxxxx"

$RG             = "BotResourceGroup"
$Location       = "westeurope"
$Suffix         = "124"

$PlanName       = "dlaseecho-linux-plan" + $Suffix
$WebAppName     = "dlaseagentspyapp" + $Suffix     # MUST be globally unique; change if taken
$Runtime        = "PYTHON:3.11"

$BotName        = "dlaseagents-bot" + $Suffix
$AppRegName     = "dlaseagents-aad" + $Suffix

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
# 3) Create Linux App Service Plan + WebApp + WebSockets
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
  --runtime $Runtime

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
echo "End date for secret: $END_DATE"

$Secret     = az ad app credential reset --id "$AppId" --display-name "agentsbot-secret" --end-date "$END_DATE" | ConvertFrom-Json
$AppSecret  = $Secret.password
$TenantId   = (az account show | ConvertFrom-Json).tenantId

Write-Host "Azure AppId: $AppId"
Write-Host "TenantId:    $TenantId"
Write-Host "AppSecret:   $AppSecret"

# ============================================================
# 5) Set Web App settings (Bot auth + Python build runtime hints), restart
# ============================================================
# NOTE: For Linux/Python built-in images, Oryx builds automatically when SCM_DO_BUILD_DURING_DEPLOYMENT=true
# For FastAPI/Flask, we typically bind to port 8000; you can adjust if your sample uses a different port
az webapp config appsettings set `
  --resource-group $RG `
  --name $WebAppName `
  --settings `
  "MicrosoftAppType=SingleTenant" `
  "MicrosoftAppId=$AppId" `
  "MicrosoftAppPassword=$AppSecret" `
  "MicrosoftAppTenantId=$TenantId" `
  "SCM_DO_BUILD_DURING_DEPLOYMENT=true" `
  "ENABLE_ORYX_BUILD=true" `
  "WEBSITES_PORT=8000"

# Recommended: set a startup command suitable for your framework.
# - FastAPI (Uvicorn):  python -m uvicorn app:app --host 0.0.0.0 --port 8000
# - Flask (Gunicorn):   gunicorn --bind=0.0.0.0:8000 app:app
az webapp config set `
  --resource-group $RG `
  --name $WebAppName `
  --startup-file "python -m uvicorn app:app --host 0.0.0.0 --port 8000"

az webapp restart --resource-group $RG --name $WebAppName

# ============================================================
# 6) Create Azure Bot (registration)
# ============================================================
# az extension add --name botservice --only-show-errors

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
# 6b) Capture Azure Bot Direct Line secret (best-effort)
# ============================================================
$ApiVersion = '2023-09-15-preview'
$BaseUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$RG/providers/Microsoft.BotService/botServices/$BotName/channels/DirectLineChannel"
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
# 7) Build + deploy Python Agents quickstart (Agents repo; agent.py in /src)
#    Repo: https://github.com/microsoft/Agents/tree/main/samples/python/quickstart
# ============================================================

$ORIGINAL_WD = (Get-Location).Path

# --- Clone / update repo ---
$RepoUrl    = "https://github.com/microsoft/Agents.git"
$RepoFolder = "Agents"
$LocalRepo  = Join-Path $ORIGINAL_WD $RepoFolder

Set-Location $ORIGINAL_WD
git clone $RepoUrl
Set-Location $LocalRepo

# --- Quickstart paths ---
$BotPath = Join-Path $LocalRepo "samples/python/quickstart"
if (-not (Test-Path $BotPath)) { throw "Quickstart not found: $BotPath" }

$SrcDir   = Join-Path $BotPath "src"
$AgentPy  = Join-Path $SrcDir "agent.py"
if (-not (Test-Path $AgentPy)) { throw "agent.py not found at: $AgentPy" }

Write-Host "BotPath: $BotPath"
Write-Host "SrcDir : $SrcDir"

# --- Detect framework to choose server/command ---
$agentCode  = Get-Content $AgentPy -Raw
$useFastAPI = $agentCode -match '\b(from|import)\s+fastapi\b'
$useAiohttp = $agentCode -match '\b(from|import)\s+aiohttp\b'

# --- requirements: prefer repo's file; write minimal fallback if missing ---
$ReqPath = Join-Path $BotPath "requirements.txt"
if (-not (Test-Path $ReqPath)) {
  $req = @("python-dotenv>=1.0","pydantic>=2.0")
  if ($useFastAPI -or -not $useAiohttp) {
    # default to FastAPI if uncertain
    $req += @("fastapi==0.115.0","uvicorn==0.30.0")
  } else {
    $req += @("aiohttp==3.9.5","gunicorn==23.0.0")
  }
  $req -join "`n" | Set-Content -Path $ReqPath -Encoding utf8
  Write-Host "Wrote fallback requirements.txt -> $ReqPath"
} else {
  Write-Host "Using repository requirements.txt -> $ReqPath"
}

# --- App Service build/runtime hints for Oryx ---
az webapp config appsettings set `
  --resource-group $RG `
  --name $WebAppName `
  --settings `
    SCM_DO_BUILD_DURING_DEPLOYMENT=true `
    ENABLE_ORYX_BUILD=true `
    WEBSITES_PORT=8000 `
    PYTHONUNBUFFERED=1 | Out-Null

# --- Startup command (ensure Python can import from ./src) ---
if ($useAiohttp) {
  # AIOHTTP via Gunicorn; chdir into src so 'agent:app' resolves
  $Startup = "gunicorn --worker-class aiohttp.worker.GunicornWebWorker -b 0.0.0.0:8000 agent:app --chdir src"
} else {
  # FastAPI via Uvicorn; add src to module search path with --app-dir
  $Startup = "python -m uvicorn --app-dir src agent:app --host 0.0.0.0 --port 8000"
}

az webapp config set `
  --resource-group $RG `
  --name $WebAppName `
  --startup-file "$Startup" | Out-Null

Write-Host "Startup command set -> $Startup"

# --- ZIP deploy (triggers remote Oryx build) ---
Set-Location $BotPath
$ZipPath = Join-Path $ORIGINAL_WD "bot.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path (Join-Path $BotPath "*") -DestinationPath $ZipPath
$ZipPath = (Resolve-Path $ZipPath).Path
Set-Location $ORIGINAL_WD

az webapp deploy --resource-group $RG --name $WebAppName --src-path $ZipPath --type zip | Out-Null
az webapp restart --resource-group $RG --name $WebAppName | Out-Null

Write-Host "✅ Deployment complete. Check Log Stream for Oryx build + startup."



# ============================================================
# ===== REPLAY VARS OUTPUT (single one-liner for copy/paste) =====
# Emits one PowerShell command with all assignments; easier to reuse.
# WARNING: Contains secrets (e.g., AppSecret, DLSecret). Handle with care.
# To save: redirect output (e.g., '> vars.ps1') and dot-source: '. .\vars.ps1'.
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
$pairs += Build-AssignPair 'Runtime' $Runtime
$pairs += Build-AssignPair 'BotName' $BotName
$pairs += Build-AssignPair 'AppRegName' $AppRegName

$pairs += Build-AssignPair 'WebAppUrl' $WebAppUrl
$pairs += Build-AssignPair 'BotEndpoint' $BotEndpoint

$pairs += Build-AssignPair 'AppId' $AppId
$pairs += Build-AssignPair 'TenantId' $TenantId
$pairs += Build-AssignPair 'END_DATE' $END_DATE
$pairs += Build-AssignPair 'AppSecret' $AppSecret   # Sensitive

$pairs += Build-AssignPair 'BotResourceId' $BotResourceId

$pairs += Build-AssignPair 'AgentRepoUrl' $AgentRepoUrl
$pairs += Build-AssignPair 'AgentSampleRelPath' $AgentSampleRelPath
$pairs += Build-AssignPair 'BotPath' $BotPath
$pairs += Build-AssignPair 'IndexDir' $IndexDir
$pairs += Build-AssignPair 'ZipPath' $ZipPath
$pairs += Build-AssignPair 'ORIGINAL_WD' $ORIGINAL_WD

# Placeholder used in index.html; may be unset in this script
$pairs += Build-AssignPair 'DLSecret' $DLSecret      # Sensitive if set

Write-Output ($pairs -join '; ')
