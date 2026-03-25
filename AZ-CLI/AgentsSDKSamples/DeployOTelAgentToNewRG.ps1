# ============================================================
# Script: Creates a Bot Channel Registration + .NET Agents SDK OTelAgent sample on Azure App Service (Windows)
#         with optional Application Insights for OpenTelemetry export
# ============================================================

# Summary:
# - Logs in and sets the subscription
# - Creates Resource Group, Windows App Service plan and Web App (WebSockets, .NET runtime)
# - Creates Application Insights resource (for OpenTelemetry export)
# - Registers Entra app + secret (1-week expiry)
# - Sets app settings for Bot Service auth and App Insights connection string
# - Creates Azure Bot (channel registration)
# - (Best-effort) captures Direct Line secret
# - Clones the Agents-for-net repo, builds the OTelAgent sample, and deploys to App Service
#
# Required parameters: SubscriptionId, RG, Location, Suffix (derives PlanName, WebAppName, BotName, AppRegName)
# Optional: DLSecret (if captured), used only by the test page (do not use in production)
#
# OTelAgent sample repo: https://github.com/microsoft/Agents-for-net
# Sample path:           src/samples/OTelAgent

# ============================================================
# 0) Fixed parameters. Edit ONLY subscription and suffix for uniqueness.
# ============================================================
$SubscriptionId = "xxxxxx-xxxxxxxx-xxxxxxxxxxxxxx"

$RG             = "OTelBotResourceGroup"
$Location       = "westeurope"
$Suffix         = "124"

$PlanName       = "otelagent-win-plan" + $Suffix
$WebAppName     = "otelagentnetapp" + $Suffix       # MUST be globally unique; change if taken
$DotNetVersion  = "v8.0"                            # .NET 8.0

$BotName        = "otelagent-bot" + $Suffix
$AppRegName     = "otelagent-aad" + $Suffix
$AppInsightsName = "otelagent-ai" + $Suffix         # Application Insights resource name

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
# 3b) Create Application Insights resource (for OpenTelemetry export)
# ============================================================
Write-Host "Creating Application Insights resource..."

# Create a Log Analytics workspace (required for workspace-based App Insights)
$WorkspaceName = "otelagent-law" + $Suffix
az monitor log-analytics workspace create `
  --resource-group $RG `
  --workspace-name $WorkspaceName `
  --location $Location

$WorkspaceId = (az monitor log-analytics workspace show `
  --resource-group $RG `
  --workspace-name $WorkspaceName `
  --query id -o tsv)

# Create workspace-based Application Insights
az monitor app-insights component create `
  --app $AppInsightsName `
  --location $Location `
  --resource-group $RG `
  --workspace $WorkspaceId `
  --kind web `
  --application-type web

$AppInsightsConnString = (az monitor app-insights component show `
  --app $AppInsightsName `
  --resource-group $RG `
  --query connectionString -o tsv)

Write-Host "Application Insights Connection String: $AppInsightsConnString"

# ============================================================
# 4) Create Entra App Registration + SP + Secret (1-week expiry)
# ============================================================
$App       = az ad app create --display-name $AppRegName | ConvertFrom-Json
$AppId     = $App.appId
az ad sp create --id $AppId | Out-Null

$END_DATE = (Get-Date).ToUniversalTime().AddDays(7).ToString("yyyy-MM-ddTHH:mm:ssZ")
echo "End date for secret: $END_DATE"

$Secret     = az ad app credential reset --id "$AppId" --display-name "otelagent-secret" --end-date "$END_DATE" | ConvertFrom-Json
$AppSecret  = $Secret.password
$TenantId   = (az account show | ConvertFrom-Json).tenantId

Write-Host "Azure AppId: $AppId"
Write-Host "TenantId:    $TenantId"
Write-Host "AppSecret:   $AppSecret"

# ============================================================
# 5) Set Web App settings (logging, diagnostics, and App Insights connection string)
# ============================================================
# NOTE: For Agents SDK, authentication is configured via appsettings.json (Connections section)
# NOT via Azure App Settings. Do not set MicrosoftAppId/Password here.
# The App Insights connection string is set as env var so the OTel exporter picks it up.
az webapp config appsettings set `
  --resource-group $RG `
  --name $WebAppName `
  --settings `
  "ASPNETCORE_ENVIRONMENT=Production" `
  "ASPNETCORE_DETAILEDERRORS=true" `
  "Logging__LogLevel__Default=Information" `
  "Logging__LogLevel__Microsoft.AspNetCore=Warning" `
  "APPLICATIONINSIGHTS_CONNECTION_STRING=$AppInsightsConnString"

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
# 7) Build + deploy .NET OTelAgent sample (Agents-for-net repo)
#    Repo: https://github.com/microsoft/Agents-for-net
#    Path: src/samples/OTelAgent
# ============================================================

$ORIGINAL_WD = (Get-Location).Path

# --- Clone / update repo ---
$RepoUrl    = "https://github.com/microsoft/Agents-for-net.git"
$RepoFolder = "Agents-for-net"
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

# --- OTelAgent sample path ---
$BotPath = Join-Path $LocalRepo "src\samples\OTelAgent"
if (-not (Test-Path $BotPath)) { throw "OTelAgent sample not found: $BotPath" }

Write-Host "BotPath: $BotPath"

# --- Find .csproj file ---
$CsProjFiles = Get-ChildItem -Path $BotPath -Filter "*.csproj" -Recurse
if ($CsProjFiles.Count -eq 0) { throw "No .csproj file found in: $BotPath" }

$CsProjFile = $CsProjFiles[0].FullName
Write-Host "Found project file: $CsProjFile"

# --- Create appsettings.json with bot credentials (Agents SDK format) + OTel config ---
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
  "AllowedHosts": "*",
  "OpenTelemetry": {
    "ServiceName": "OTelAgent",
    "ServiceVersion": "1.0.0",
    "EnableConsoleExporter": false,
    "EnableApplicationInsightsExporter": true,
    "EnableHttpClient": true,
    "TracingSamplingRatio": 1.0,
    "MetricsExportInterval": 5000,
    "LogsExportInterval": 5000
  },
  "ApplicationInsights": {
    "ConnectionString": "$AppInsightsConnString"
  },
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
        "AuthorityEndpoint": "https://login.microsoftonline.com/$TenantId",
        "ClientId": "$AppId",
        "ClientSecret": "$AppSecret",
        "Scopes": [
          "https://api.botframework.com/.default"
        ]
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
  }
}
"@

$appSettingsContent | Set-Content -Path $AppSettingsPath -Encoding utf8
Write-Host "Created appsettings.json at: $AppSettingsPath"
Write-Host ""
Write-Host "Verifying appsettings.json content:"
Write-Host "  - TokenValidation.Enabled: true"
Write-Host "  - TokenValidation.Audiences[0]: $AppId"
Write-Host "  - TokenValidation.TenantId: $TenantId"
Write-Host "  - Connections.ServiceConnection.Settings.ClientId: $AppId"
Write-Host "  - ApplicationInsights.ConnectionString: (set)"
Write-Host "  - OpenTelemetry.EnableApplicationInsightsExporter: true"
Write-Host ""
Write-Host "Full appsettings.json content:"
Get-Content $AppSettingsPath | ForEach-Object { Write-Host "  $_" }
Write-Host ""

# --- Build and publish .NET project ---
# NOTE: The OTelAgent.csproj uses ProjectReferences to libraries within the Agents-for-net repo,
#       so we must build from within the repo structure. The project references resolve relative
#       to src/samples/OTelAgent (e.g., ../../libraries/...).
Write-Host "Building .NET project..."
Set-Location $ProjectDir

# Restore NuGet packages (including transitive ProjectReferences)
Write-Host "Running dotnet restore..."
dotnet restore
if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed" }

# Build the project
Write-Host "Running dotnet build..."
dotnet build --configuration Release
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed" }

# Publish to a folder (self-contained not needed; the App Service has .NET 8 runtime)
$PublishPath = Join-Path $ORIGINAL_WD "publish-otel"
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
  Write-Host "✓ Ensured appsettings.json has correct credentials and OTel config"
}

# List published files for verification
Write-Host ""
Write-Host "Published files:"
Get-ChildItem $PublishPath -File | Select-Object -First 15 | ForEach-Object { Write-Host "  - $($_.Name)" }
if ((Get-ChildItem $PublishPath -File).Count -gt 15) {
  Write-Host "  ... and $((Get-ChildItem $PublishPath -File).Count - 15) more files"
}
Write-Host ""

Write-Host "✅ Build and publish completed successfully"

# --- ZIP deploy .NET application to Windows App Service ---
Set-Location $PublishPath
$ZipPath = Join-Path $ORIGINAL_WD "otelagent-bot.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

Write-Host "Creating deployment package from published output..."
Compress-Archive -Path (Join-Path $PublishPath "*") -DestinationPath $ZipPath -Force
$ZipPath = (Resolve-Path $ZipPath).Path
Set-Location $ORIGINAL_WD

Write-Host "Deploying OTelAgent application to Windows App Service..."
az webapp deploy --resource-group $RG --name $WebAppName --src-path $ZipPath --type zip

Write-Host "Restarting web app..."
az webapp restart --resource-group $RG --name $WebAppName

Write-Host ""
Write-Host "✅ Deployment complete!"
Write-Host ""
Write-Host "📋 Resources created:"
Write-Host "   - Resource Group:       $RG"
Write-Host "   - App Service Plan:     $PlanName"
Write-Host "   - Web App:              $WebAppName"
Write-Host "   - Azure Bot:            $BotName"
Write-Host "   - App Registration:     $AppRegName"
Write-Host "   - Application Insights: $AppInsightsName"
Write-Host "   - Log Analytics:        $WorkspaceName"
Write-Host ""
Write-Host "📋 Next steps:"
Write-Host "   1. Wait 30-60 seconds for app to start"
Write-Host "   2. Check logs: az webapp log tail --resource-group $RG --name $WebAppName"
Write-Host "   3. View Log Stream in Azure Portal: https://portal.azure.com"
Write-Host "   4. Test endpoint: $BotEndpoint"
Write-Host "   5. View OpenTelemetry data in Application Insights:"
Write-Host "      - Go to Azure Portal > Application Insights > $AppInsightsName"
Write-Host "      - Check Transaction Search, Live Metrics, or Performance tabs"
Write-Host "   6. Test in WebChat: Azure Portal > Bot Services > $BotName > Test in Web Chat"
Write-Host ""
Write-Host "📊 OpenTelemetry features in this sample:"
Write-Host "   - Custom traces: agent.process_message, agent.message_handler, agent.welcome_message"
Write-Host "   - Custom metrics: agent.messages.processed, agent.routes.executed"
Write-Host "   - Histograms: agent.message.processing.duration, agent.route.execution.duration"
Write-Host "   - UpDownCounter: agent.conversations.active"
Write-Host "   - ASP.NET Core + HttpClient instrumentation"
Write-Host "   - Azure Monitor export via Application Insights"
Write-Host ""
Write-Host "⚠️  Known Issues:"
Write-Host "   - If you see authentication errors, verify the appsettings.json credentials"
Write-Host "   - The OTelAgent sample uses ProjectReferences; ensure the full repo was cloned"
Write-Host "   - Check that the repository sample at: https://github.com/microsoft/Agents-for-net/tree/main/src/samples/OTelAgent"
Write-Host "   - If Application Insights data is delayed, allow 2-5 minutes for telemetry to appear"
Write-Host ""

# ============================================================
# ===== REPLAY VARS OUTPUT (single one-liner for copy/paste) =====
# Emits one PowerShell command with all assignments; easier to reuse.
# WARNING: Contains secrets (e.g., AppSecret, DLSecret, AppInsightsConnString). Handle with care.
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
$pairs += Build-AssignPair 'AppInsightsName' $AppInsightsName
$pairs += Build-AssignPair 'WorkspaceName' $WorkspaceName

$pairs += Build-AssignPair 'WebAppUrl' $WebAppUrl
$pairs += Build-AssignPair 'BotEndpoint' $BotEndpoint

$pairs += Build-AssignPair 'AppId' $AppId
$pairs += Build-AssignPair 'TenantId' $TenantId
$pairs += Build-AssignPair 'END_DATE' $END_DATE
$pairs += Build-AssignPair 'AppSecret' $AppSecret                   # Sensitive
$pairs += Build-AssignPair 'AppInsightsConnString' $AppInsightsConnString  # Sensitive

$pairs += Build-AssignPair 'BotResourceId' $BotResourceId

$pairs += Build-AssignPair 'RepoUrl' $RepoUrl
$pairs += Build-AssignPair 'LocalRepo' $LocalRepo
$pairs += Build-AssignPair 'BotPath' $BotPath
$pairs += Build-AssignPair 'CsProjFile' $CsProjFile
$pairs += Build-AssignPair 'PublishPath' $PublishPath
$pairs += Build-AssignPair 'ZipPath' $ZipPath
$pairs += Build-AssignPair 'ORIGINAL_WD' $ORIGINAL_WD

# Placeholder used in test pages; may be unset in this script
$pairs += Build-AssignPair 'DLSecret' $DLSecret                     # Sensitive if set

Write-Output ($pairs -join '; ')
