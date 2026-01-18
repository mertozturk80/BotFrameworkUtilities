# ============================================================
# Script: Creates a Bot Channel Registration + .NET Agents SDK bot on Azure App Service (Windows)
# ============================================================

# Summary:
# - Logs in and sets the subscription
# - Creates Resource Group, Windows App Service plan and Web App (WebSockets, .NET runtime)
# - Registers Entra app + secret (1-week expiry)
# - Sets app settings for Bot Service auth
# - Creates Azure Bot (channel registration)
# - (Best-effort) captures Direct Line secret
# - Clones a .NET Agents SDK quickstart bot sample, builds, and deploys to App Service
#
# Required parameters: SubscriptionId, RG, Location, Suffix (derives PlanName, WebAppName, BotName, AppRegName)
# Optional: DLSecret (if captured), used only by the test page (do not use in production)

# ============================================================
# 0) Fixed parameters. Edit ONLY subscription and suffix for uniqueness.
# ============================================================
$SubscriptionId = "xxxxxx-xxxxxxxx-xxxxxxxxxxxxxx"

$RG             = "BotResourceGroup"
$Location       = "westeurope"
$Suffix         = "124"

$PlanName       = "dlaseecho-win-plan" + $Suffix
$WebAppName     = "dlaseagentsnetapp" + $Suffix     # MUST be globally unique; change if taken
$DotNetVersion  = "v8.0"                          # .NET 8.0

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
# 3) Create Windows App Service Plan + WebApp + WebSockets
# ============================================================
az appservice plan create `
  --resource-group $RG `
  --name $PlanName `
  --location $Location `
  --sku S1

az webapp create `
  --resource-group $RG `
  --name $WebAppName `
  --plan $PlanName

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
# 5) Set Web App settings (logging and diagnostics only)
# ============================================================
# NOTE: For Agents SDK, authentication is configured via appsettings.json (Connections section)
# NOT via Azure App Settings. Do not set MicrosoftAppId/Password here.
az webapp config appsettings set `
  --resource-group $RG `
  --name $WebAppName `
  --settings `
  "ASPNETCORE_ENVIRONMENT=Production" `
  "ASPNETCORE_DETAILEDERRORS=true" `
  "Logging__LogLevel__Default=Information" `
  "Logging__LogLevel__Microsoft.AspNetCore=Warning"

# Enable detailed error messages and logging
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
# 7) Build + deploy .NET Agents quickstart (Agents repo)
#    Repo: https://github.com/microsoft/Agents/tree/main/samples/dotnet/quickstart
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

# --- Quickstart paths ---
$BotPath = Join-Path $LocalRepo "samples\dotnet\quickstart"
if (-not (Test-Path $BotPath)) { throw "Quickstart not found: $BotPath" }

Write-Host "BotPath: $BotPath"

# --- Find .csproj file ---
$CsProjFiles = Get-ChildItem -Path $BotPath -Filter "*.csproj" -Recurse
if ($CsProjFiles.Count -eq 0) { throw "No .csproj file found in: $BotPath" }

$CsProjFile = $CsProjFiles[0].FullName
Write-Host "Found project file: $CsProjFile"

# --- Create appsettings.json with bot credentials (Agents SDK format) ---
$ProjectDir = Split-Path $CsProjFile -Parent
$AppSettingsPath = Join-Path $ProjectDir "appsettings.json"

# Backup existing appsettings.json if it exists
if (Test-Path $AppSettingsPath) {
  $BackupPath = Join-Path $ProjectDir "appsettings.json.bak"
  Copy-Item $AppSettingsPath $BackupPath -Force
  Write-Host "Backed up existing appsettings.json"
}

$appSettingsContent = @"
{
  "TokenValidation": {
    "Enabled": true,
    "Audiences": [
      "$AppId"
    ],
    "TenantId": "$TenantId"
  },
  "AgentApplication": {
    "StartTypingTimer": false,
    "RemoveRecipientMention": false,
    "NormalizeMentions": false
  },
  "Connections": {
    "ServiceConnection": {
      "Settings": {
        "AuthType": "ClientSecret",
        "ClientId": "$AppId",
        "ClientSecret": "$AppSecret",
        "TenantId": "$TenantId",
        "Scopes": [
          "https://api.botframework.com/.default"
        ],
        "MicrosoftAppType": "SingleTenant"
      }
    }
  },
  "ConnectionsMap": [
    {
      "ServiceUrl": "*",
      "Connection": "ServiceConnection"
    }
  ],
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "AllowedHosts": "*"
}
"@

$appSettingsContent | Set-Content -Path $AppSettingsPath -Encoding utf8
Write-Host "Created appsettings.json at: $AppSettingsPath"
Write-Host ""
Write-Host "Verifying appsettings.json content:"
Write-Host "  - TokenValidation.Enabled: false"
Write-Host "  - TokenValidation.Audiences[0]: $AppId"
Write-Host "  - TokenValidation.TenantId: $TenantId"
Write-Host "  - Connections.ServiceConnection.Settings.MicrosoftAppId: $AppId"
Write-Host ""
Write-Host "Full appsettings.json content:"
Get-Content $AppSettingsPath | ForEach-Object { Write-Host "  $_" }
Write-Host ""

# --- Build and publish .NET project ---
Write-Host "Building .NET project..."
Set-Location $ProjectDir

# Restore NuGet packages
Write-Host "Running dotnet restore..."
dotnet restore
if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed" }

# Build the project
Write-Host "Running dotnet build..."
dotnet build --configuration Release
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed" }

# Publish to a folder
$PublishPath = Join-Path $ORIGINAL_WD "publish"
if (Test-Path $PublishPath) { Remove-Item $PublishPath -Recurse -Force }

Write-Host "Publishing to: $PublishPath"
dotnet publish --configuration Release --output $PublishPath
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

# Ensure appsettings.json is in the publish folder
$PublishedAppSettings = Join-Path $PublishPath "appsettings.json"
if (-not (Test-Path $PublishedAppSettings)) {
  Write-Host "WARNING: appsettings.json not found in publish output, copying manually..."
  Copy-Item $AppSettingsPath $PublishedAppSettings -Force
} else {
  Write-Host "✓ appsettings.json found in publish output"
  # Overwrite with our configured version to be sure
  Copy-Item $AppSettingsPath $PublishedAppSettings -Force
  Write-Host "✓ Ensured appsettings.json has correct credentials"
}

# List published files for verification
Write-Host ""
Write-Host "Published files:"
Get-ChildItem $PublishPath -File | Select-Object -First 10 | ForEach-Object { Write-Host "  - $($_.Name)" }
if ((Get-ChildItem $PublishPath -File).Count -gt 10) {
  Write-Host "  ... and $((Get-ChildItem $PublishPath -File).Count - 10) more files"
}
Write-Host ""

Write-Host "✅ Build and publish completed successfully"

# --- ZIP deploy .NET application to Windows App Service ---
Set-Location $PublishPath
$ZipPath = Join-Path $ORIGINAL_WD "bot.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

Write-Host "Creating deployment package from published output..."
Compress-Archive -Path (Join-Path $PublishPath "*") -DestinationPath $ZipPath -Force
$ZipPath = (Resolve-Path $ZipPath).Path
Set-Location $ORIGINAL_WD

Write-Host "Deploying .NET application to Windows App Service..."
az webapp deploy --resource-group $RG --name $WebAppName --src-path $ZipPath --type zip

Write-Host "Restarting web app..."
az webapp restart --resource-group $RG --name $WebAppName

Write-Host ""
Write-Host "✅ Deployment complete!"
Write-Host "📋 Next steps:"
Write-Host "   1. Wait 30-60 seconds for app to start"
Write-Host "   2. Check logs: az webapp log tail --resource-group $RG --name $WebAppName"
Write-Host "   3. View Log Stream in Azure Portal: https://portal.azure.com"
Write-Host "   4. Test endpoint: $BotEndpoint"
Write-Host "   5. If HTTP 500 persists, check Application Insights or enable remote debugging"
Write-Host ""
Write-Host "⚠️  Known Issues:"
Write-Host "   - If you see authentication errors, the quickstart sample might need additional configuration"
Write-Host "   - Check that the repository sample at: https://github.com/microsoft/Agents/tree/main/samples/dotnet/quickstart"
Write-Host "   - is a complete, runnable sample with proper Agents SDK setup"
Write-Host ""


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
$pairs += Build-AssignPair 'DotNetVersion' $DotNetVersion
$pairs += Build-AssignPair 'BotName' $BotName
$pairs += Build-AssignPair 'AppRegName' $AppRegName

$pairs += Build-AssignPair 'WebAppUrl' $WebAppUrl
$pairs += Build-AssignPair 'BotEndpoint' $BotEndpoint

$pairs += Build-AssignPair 'AppId' $AppId
$pairs += Build-AssignPair 'TenantId' $TenantId
$pairs += Build-AssignPair 'END_DATE' $END_DATE
$pairs += Build-AssignPair 'AppSecret' $AppSecret   # Sensitive

$pairs += Build-AssignPair 'BotResourceId' $BotResourceId

$pairs += Build-AssignPair 'RepoUrl' $RepoUrl
$pairs += Build-AssignPair 'LocalRepo' $LocalRepo
$pairs += Build-AssignPair 'BotPath' $BotPath
$pairs += Build-AssignPair 'CsProjFile' $CsProjFile
$pairs += Build-AssignPair 'PublishPath' $PublishPath
$pairs += Build-AssignPair 'ZipPath' $ZipPath
$pairs += Build-AssignPair 'ORIGINAL_WD' $ORIGINAL_WD

# Placeholder used in index.html; may be unset in this script
$pairs += Build-AssignPair 'DLSecret' $DLSecret      # Sensitive if set

Write-Output ($pairs -join '; ')
