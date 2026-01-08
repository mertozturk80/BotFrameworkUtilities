# ============================================================
# Script Creates a bot channel registration only
# ============================================================


# Summary: Provisions an Echo Bot on Azure — logs in and sets the subscription, creates a resource group, App Service plan and Web App (WebSockets), registers an Entra app and secret, configures app settings, creates a Bot Service registration, builds and deploys the BotBuilder echo sample, and writes a test index.html for classic Direct Line.
# Required parameters: `SubscriptionId`, `RG`, `Location`, `Suffix` (derives `PlanName`, `WebAppName`, `BotName`, `AppRegName`); optional `DLSecret` to let the test page request a Direct Line token.


# ============================================================
# Fixed parameters. Edit ONLY Subscripton name and Suffix for uniqueness.
# ============================================================
$SubscriptionId = "xxxxxx-xxxxxxxx-xxxxxxxxxxxxxx"

$RG             = "BotResourceGroup"
$Location       = "westeurope"
$Suffix = "124"

$PlanName       = "dlaseecho-plan" + $Suffix
$WebAppName     = "dlaseechoapp" + $Suffix         # MUST be globally unique; change if taken
$Runtime        = "DOTNET:8"

$BotName        = "dlaseecho-bot" + $Suffix
$AppRegName     = "dlaseecho-aad" + $Suffix


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
  --plan $PlanName `
  --runtime $Runtime

az webapp config set `
  --resource-group $RG `
  --name $WebAppName `
  --web-sockets-enabled true

$WebAppUrl   = "https://$WebAppName.azurewebsites.net"
$BotEndpoint = "$WebAppUrl/api/messages"

Write-Host "WebAppUrl:   $WebAppUrl"
Write-Host "BotEndpoint: $BotEndpoint"

# ============================================================
# 4) Create Entra App Registration + SP + Secret
# ============================================================

$App       = az ad app create --display-name $AppRegName | ConvertFrom-Json
$AppId     = $App.appId
az ad sp create --id $AppId | Out-Null
$END_DATE = (Get-Date).ToUniversalTime().AddDays(7).ToString("yyyy-MM-ddTHH:mm:ssZ")
echo "End date for secret: $END_DATE"

# Reset app credential with 1-week expiry
$Secret = az ad app credential reset --id "$AppId" --display-name "echobot-secret"  --end-date "$END_DATE"  | ConvertFrom-Json
$AppSecret = $Secret.password
$TenantId  = (az account show | ConvertFrom-Json).tenantId


Write-Host "Azure AppId:   $AppId"
Write-Host "TenantId: $TenantId"
Write-Host "AppSecret: $AppSecret"

# ============================================================
# 5) Set App settings + bot auth settings, restart
#     Required settings: 
# ============================================================

az webapp config appsettings set `
  --resource-group $RG `
  --name $WebAppName `
  --settings `
  "MicrosoftAppType=SingleTenant" `
  "MicrosoftAppId=$AppId" `
  "MicrosoftAppPassword=$AppSecret" `
  "MicrosoftAppTenantId=$TenantId"

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

az resource show --ids $BotResourceId 

Write-Host "WebAppUrl:   $AppId"
Write-Host "TenantId: $TenantId"

# ============================================================
# 6) Capture Azure Bot DL Secret (best-effort)
# ============================================================
# Keys are redacted on GET; attempt management action listChannelWithKeys, else instruct manual/Key Vault.

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
# 7) Build + deploy Echo Bot sample.
# ============================================================

#Clone the samples repo to the work directory. 
Set-Location -Path $PWD 
git clone https://github.com/microsoft/BotBuilder-Samples.git 

#set the bot applications path, and get a copy of startup file..

$BotPath = Join-Path  $PWD  "BotBuilder-Samples\samples\csharp_dotnetcore\02.echo-bot"
$Startup = Join-Path $BotPath "Startup.cs"
Echo $BotPath
Echo $Startup

# Optional: add OutOfProcess hosting model (helps avoid some ANCM issues)

$Csproj = Get-ChildItem $BotPath -Filter "*.csproj" | Select-Object -First 1
$cs     = Get-Content $Csproj.FullName -Raw
if ($cs -notmatch "AspNetCoreHostingModel") {
  $cs = $cs -replace "(\<PropertyGroup\>\s*)", "`$1`r`n    <AspNetCoreHostingModel>OutOfProcess</AspNetCoreHostingModel>`r`n"
  Set-Content -Path $Csproj.FullName -Value $cs -Encoding utf8
}

# --- Add test client: wwwroot/index.html ---
$IndexDir  = Join-Path $BotPath "wwwroot"
New-Item -ItemType Directory -Force -Path $IndexDir | Out-Null

#Final HTML , with the secret and web app url setup :

$IndexHtml = @"
<!DOCTYPE html>
<html lang="en-US">
  <head>
    <title>Web Chat (Direct Line)</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <script crossorigin="anonymous" src="https://cdn.botframework.com/botframework-webchat/latest/webchat.js"></script>
    <style>
      html, body {
        background-color: #f7f7f7;
        height: 100%;
      }
      body { margin: 0; }
      #webchat {
        box-shadow: 0 0 10px rgba(0, 0, 0, 0.05);
        height: 100%;
        margin: auto;
        max-width: 480px;
        min-width: 360px;
      }
    </style>
  </head>
  <body>
    <div id="webchat" role="main"></div>
    <script>
      (async function () {
        // NOTE: For TEST ONLY — do not expose Direct Line secrets in client code in production!
        // Classical Direct Line: request a token from the Direct Line service using your Direct Line secret.
        const res = await fetch('https://directline.botframework.com/v3/directline/tokens/generate', {
          method: 'POST',
          headers: {
            'Authorization': 'Bearer ' + '$DLSecret',
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({ user: { id: 'my_test_id', name: 'my_test_name' } })
        });

        const { token } = await res.json();

        window.WebChat.renderWebChat(
          {
            directLine: await window.WebChat.createDirectLine({ token })
          },
          document.getElementById('webchat')
        );

        document.querySelector('#webchat > *').focus();
      })().catch(err => console.error(err));
    </script>
  </body>
</html>
"@

Set-Content -Path (Join-Path $IndexDir "index.html") -Value $IndexHtml -Encoding utf8

$ORIGINAL_WD = $PWD
Set-Location $BotPath

#Build and zip deploy

dotnet restore
dotnet publish -c Release -o (Join-Path $PWD "publish")

$ZipPath = Join-Path $ORIGINAL_WD "bot.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path (Join-Path $PWD "publish\*") -DestinationPath $ZipPath

$ZipPath = (Resolve-Path $ZipPath).Path
Echo $ZipPath

#Go back to the root folder, where we have the deploying zip file.
Set-Location $ORIGINAL_WD

az webapp deploy `
  --resource-group $RG `
  --name $WebAppName `
  --src-path "$ZipPath" `
  --type zip


az webapp restart --resource-group $RG --name $WebAppName


# ============================================================
# ===== REPLAY VARS OUTPUT (single one-liner for copy/paste) =====
# Emits one PowerShell command with all assignments; easier to reuse.
# WARNING: Contains secrets (e.g., AppSecret, DLSecret). Handle with care.
# To save: redirect output (e.g., `> vars.ps1`) and dot-source: `. .\vars.ps1`.
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

$pairs += Build-AssignPair 'BotPath' $BotPath
$pairs += Build-AssignPair 'Startup' $Startup
$pairs += Build-AssignPair 'Csproj'  $Csproj.FullName
$pairs += Build-AssignPair 'IndexDir' $IndexDir
$pairs += Build-AssignPair 'ZipPath' $ZipPath
$pairs += Build-AssignPair 'ORIGINAL_WD' $ORIGINAL_WD

# Placeholder used in index.html; may be unset in this script
$pairs += Build-AssignPair 'DLSecret' $DLSecret      # Sensitive if set

Write-Output ($pairs -join '; ')

