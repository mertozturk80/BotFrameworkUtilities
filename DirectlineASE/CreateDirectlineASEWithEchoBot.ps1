# ============================================================
# Fixed parameters (NO suffix). Edit ONLY Subscripton name and Suffix for uniqueness.
# ============================================================
$SubscriptionId = "83454b68-9b7f-41a7-b08e-936b629f865b"
$RG             = "BotFrameworkASETest"
$Location       = "westeurope"
$Suffix = "123"

$VnetName       = "dlaseecho-vnet" + $Suffix
$AppSubnetName  = "apps"
$VmSubnetName   = "vms"
$VnetCidr       = "10.20.0.0/16"
$AppSubnetCidr  = "10.20.1.0/24"
$VmSubnetCidr   = "10.20.3.0/24"

$PlanName       = "dlaseecho-plan" + $Suffix
$WebAppName     = "dlaseechoapp" + $Suffix         # MUST be globally unique; change if taken
$Runtime        = "DOTNET:8"

$BotName        = "dlaseecho-bot" + $Suffix
$AppRegName     = "dlaseecho-aad" + $Suffix

# Available VM sizes can be listed with: 
# az vm list-skus --location centralus --size Standard_D --all --output table

$VmName         = "dlaseecho-vm" + $Suffix
$VmSize         = "Standard_D2s_v6"  
$VmAdminUser    = "azureuser"
$VmLocation       = "westeurope"



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
# 3) Create VNet + subnets
# ============================================================
az network vnet create `
  --resource-group $RG `
  --name $VnetName `
  --location $Location `
  --address-prefixes $VnetCidr `
  --subnet-name $AppSubnetName `
  --subnet-prefixes $AppSubnetCidr

az network vnet subnet create `
  --resource-group $RG `
  --vnet-name $VnetName `
  --name $VmSubnetName `
  --address-prefixes $VmSubnetCidr


# ============================================================
# 4) Create Windows App Service Plan + WebApp + WebSockets
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
# 5) Create Entra App Registration + SP + Secret
# ============================================================

$App       = az ad app create --display-name $AppRegName | ConvertFrom-Json
$AppId     = $App.appId

az ad sp create --id $AppId | Out-Null

$END_DATE = (Get-Date).ToUniversalTime().AddDays(7).ToString("yyyy-MM-ddTHH:mm:ssZ")

# Reset app credential with 1-week expiry
$Secret = az ad app credential reset --id "$AppId" --display-name "dlase-secret"  --end-date "$END_DATE"  | ConvertFrom-Json



 az ad app credential reset `   --id $AppId  --display-name "dlase-secret"  --end-date $EndDate   | ConvertFrom-Json


$Secret    = az ad app credential reset --id $AppId --display-name "dlase-secret" | ConvertFrom-Json

$AppSecret = $Secret.password
$TenantId  = (az account show | ConvertFrom-Json).tenantId


Write-Host "WebAppUrl:   $AppId"
Write-Host "TenantId: $TenantId"
Write-Host "AppSecret: $AppSecret"

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
# 7) Enable Direct Line channel (CLI preview) + wait
#     Syntax supports options like --disablev1/--site-name/--trusted-origins. [4](https://learn.microsoft.com/en-us/cli/azure/bot/directline?view=azure-cli-latest)
# ============================================================

# Required vars assumed: $SubscriptionId, $RG, $BotName
# by default DL channel is enabled (isEnabled   = $true, isV1Enabled = $false, isV3Enabled = $true), if you visit the created bot in the portal. 
# The only thing required is to store the DL Secret, to be used later: 


$DLExtensionKey = az bot directline show `
  --name $BotName `
  --resource-group $RG `
  --query "properties.properties.extensionKey1" `
  -o tsv

Write-Host "DLExtensionKey(primary channel key): $DLExtensionKey"

# Direct Line channel secrets are being suppressed (not returned) by the Azure CLI/API. This is a security feature.
# Get the DL Secret manually from DL channel. 

$DLSecret = "xxx"


# ============================================================
# 8) Set DL-ASE settings + bot auth settings, restart
#     Required settings: DirectLineExtensionKey + DIRECTLINE_EXTENSION_VERSION=latest + WebSockets. [1](https://learn.microsoft.com/en-us/azure/bot-service/bot-service-channel-directline-extension-net-bot?view=azure-bot-service-4.0)[2](https://learn.microsoft.com/en-us/azure/bot-service/bot-service-channel-directline-extension-net-bot?view=azure-bot-service-4.0)
# ============================================================

az webapp config appsettings set `
  --resource-group $RG `
  --name $WebAppName `
  --settings `
  "DirectLineExtensionKey=$DLExtensionKey" `
  "DIRECTLINE_EXTENSION_VERSION=latest" `
  "MicrosoftAppType=SingleTenant" `
  "MicrosoftAppId=$AppId" `
  "MicrosoftAppPassword=$AppSecret" `
  "MicrosoftAppTenantId=$TenantId"

az webapp restart --resource-group $RG --name $WebAppName

# ============================================================
# 9) Build + deploy Echo Bot sample with Named Pipes enabled (local commands)
#     Named pipes requirement: UseWebSockets + UseNamedPipes("<site>.directline"). [2](https://learn.microsoft.com/en-us/azure/bot-service/bot-service-channel-directline-extension-net-bot?view=azure-bot-service-4.0)[1](https://learn.microsoft.com/en-us/azure/bot-service/bot-service-channel-directline-extension-net-bot?view=azure-bot-service-4.0)
# ============================================================

#Clone the samples repo to the work directory. 
Set-Location -Path $PWD 
git clone https://github.com/microsoft/BotBuilder-Samples.git 

#set the bot applications path, and get a copy of startup file..

$BotPath = Join-Path  $PWD  "BotBuilder-Samples\samples\csharp_dotnetcore\02.echo-bot"
$Startup = Join-Path $BotPath "Startup.cs"
Echo $BotPath
Echo $Startup

$txt = Get-Content $Startup -Raw

# 1) Ensure required namespace (for ASP.NET Core adapter integrations)

if ($txt -notmatch "using\s+Microsoft\.Bot\.Builder\.Integration\.AspNet\.Core;") {
  $txt = $txt -replace "(using\s+Microsoft\.AspNetCore\.Mvc;\s*)", "`$1`r`nusing Microsoft.Bot.Builder.Integration.AspNet.Core;`r`n"
}

# 2) Ensure UseDefaultFiles + UseStaticFiles so / serves /wwwroot/index.html
#    If UseStaticFiles exists, insert UseDefaultFiles just before it.

if ($txt -match "\.UseStaticFiles\(\)") {
  if ($txt -notmatch "\.UseDefaultFiles\(\)") {
    $txt = $txt -replace "(\s*\.UseStaticFiles\(\))", "`r`n            .UseDefaultFiles()`r`n            `$1"
  }
} else {
  # If no static files wiring exists, add both after UseRouting()
  $txt = $txt -replace "(app\.UseRouting\(\);\s*)", "`$1`r`n            app.UseDefaultFiles();`r`n            app.UseStaticFiles();`r`n"
}


# 3) Ensure WebSockets + Named Pipes for DL ASE transport

if ($txt -notmatch "\.UseNamedPipes") {
  $insert = @'
            .UseWebSockets()
            .UseNamedPipes(System.Environment.GetEnvironmentVariable("WEBSITE_SITE_NAME") + ".directline")
'@
  # Place after UseStaticFiles for predictability
  $txt = $txt -replace "(\s*\.UseStaticFiles\(\)\s*)", "`$1`r`n$insert`r`n"
}

#Set the content, with the changed startup file.

Set-Content -Path $Startup -Value $txt -Encoding utf8

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

# Important:
# - $WebAppUrl is already computed above as "https://$WebAppName.azurewebsites.net"
# - $DLSecret already taken on previous step. If not, Take it from the bots channels --> Directline --> Secrets.
# - For production, move secret usage to a secure token service


#Final HTML , with the secret and web app url setup :

$IndexHtml = @"
<!DOCTYPE html>
<html lang="en-US">
  <head>
    <title>Web Chat</title>
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
        const res = await fetch('$WebAppUrl/.bot/v3/directline/tokens/generate', {
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
            directLine: await window.WebChat.createDirectLineAppServiceExtension({
              domain: '$WebAppUrl/.bot/v3/directline',
              token
            })
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

#Optional - Add a React Client 
# Ensure $WebAppUrl and $DLSecret have simple string values:


$ReactDir  = Join-Path $BotPath "wwwroot\react"
New-Item -ItemType Directory -Force -Path $ReactDir | Out-Null


$ReactHtml = @'
<!DOCTYPE html>
<html lang="en-US">
  <head>
    <meta charset="utf-8" />
    <title>Web Chat (React sample)</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <!-- React UMD + Web Chat UMD -->
    <script crossorigin="anonymous" src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
    <script crossorigin="anonymous" src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
    <script crossorigin="anonymous" src="https://cdn.botframework.com/botframework-webchat/latest/webchat.js"></script>
    <!-- Babel only for dev/demo so we can use JSX directly -->
    <script crossorigin="anonymous" src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
    <style>
      html, body { height: 100%; background-color: #f7f7f7; }
      body { margin: 0; }
      #root {
        height: 100%;
        margin: auto;
        max-width: 600px;
        min-width: 360px;
        box-shadow: 0 0 10px rgba(0,0,0,0.08);
        background: white;
      }
    </style>
  </head>
  <body>
    <div id="root" role="main"></div>
    <script type="text/babel">
      // NOTE: TEST ONLY — do not expose Direct Line secrets in production.
      const WEBAPP_URL = "__WEBAPP_URL__";
      const DL_SECRET  = "__DL_SECRET__"; // must be a plain secret string (not JSON)
      const { ReactWebChat, createDirectLineAppServiceExtension } = window.WebChat;
      function App() {
        const [directLine, setDirectLine] = React.useState(null);
        const [error, setError] = React.useState(null);
        React.useEffect(() => {
          (async () => {
            try {
              // Guard: fail fast if secret is empty
              if (!DL_SECRET || DL_SECRET.trim().length === 0) {
                throw new Error("DL_SECRET is empty. Extract only the secret string (not the whole JSON).");
              }
              // ✅ Template literal uses backticks; preserved by single-quoted here-string
              const res = await fetch(`${WEBAPP_URL}/.bot/v3/directline/tokens/generate`, {
                method: "POST",
                headers: {
                  "Authorization": "Bearer " + DL_SECRET,
                  "Content-Type": "application/json"
                },
                body: JSON.stringify({
                  user: { id: "react_test_user", name: "React Test" }
                })
              });
              if (!res.ok) {
                throw new Error("Token generate failed: " + res.status + " " + res.statusText);
              }
              const { token } = await res.json();
              const dl = await createDirectLineAppServiceExtension({
                domain: `${WEBAPP_URL}/.bot/v3/directline`,
                token
              });
              setDirectLine(dl);
            } catch (e) {
              console.error(e);
              setError(e.message || String(e));
            }
          })();
        }, []);
        if (error) {
          return <div style={{ padding: 16, color: "crimson" }}>Error: {error}</div>;
        }
        if (!directLine) {
          return <div style={{ padding: 16 }}>Loading Web Chat…</div>;
        }
        return <ReactWebChat directLine={directLine} styleOptions={{ hideUploadButton: true }} />;
      }
      const root = ReactDOM.createRoot(document.getElementById("root"));
      root.render(<App />);
    </script>
  </body>
</html>
'@
# Safe token replacement (no regex) — preserves all backticks and JSX braces
$ReactHtml = $ReactHtml.Replace('__WEBAPP_URL__', $WebAppUrl).Replace('__DL_SECRET__', $DLSecret)

# Write out the file
Set-Content -Path (Join-Path $ReactDir 'index.html') -Value $ReactHtml -Encoding utf8


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
# 10) Create Windows VM in some VNet (no public IP) + to test /.bot from VM
# ============================================================

$VmPassSecure = Read-Host "Enter password for Windows VM local admin ($VmAdminUser)" -AsSecureString
$VmPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmPassSecure))

# Password: enter something memorable..

az vm create `
  --resource-group $RG `
  --name $VmName `
  --location $VmLocation `
  --image "Win2022Datacenter" `
  --size $VmSize `
  --admin-username $VmAdminUser `
  --admin-password $VmPass `
  --vnet-name $VnetName `
  --subnet $VmSubnetName `

Start-Sleep -Seconds $SafeDelay

$VmScript = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$r = Invoke-RestMethod -Uri '$WebAppUrl/.bot' -Method GET -TimeoutSec 60
`$r | ConvertTo-Json -Depth 10
if (`$r.k -eq `$true -and `$r.ib -eq `$true -and `$r.ob -eq `$true -and `$r.initialized -eq `$true) {
  Write-Output 'SUCCESS ✅ DL-ASE healthy.'
  exit 0
} else {
  Write-Output 'WARN ⚠️ Expected k/ib/ob/initialized=true.'
  exit 2
}
"@

az vm run-command invoke `
  --resource-group $RG `
  --name $VmName `
  --command-id RunPowerShellScript `
  --scripts $VmScript

Write-Host "DONE."
Write-Host "WebApp: $WebAppUrl"
Write-Host "Test:   $WebAppUrl/.bot"
Write-Host "Bot:    $BotName"
Write-Host "VM:     $VmName"
Write-Host "RG:     $RG"

# ============================================================
# 10) ECHO all the variables after the operations: 
# ============================================================

# ===== UNSAFE ECHO (with secrets/keys created. You can mask them if you like) =====
echo "SubscriptionId=$SubscriptionId"
echo "RG=$RG"
echo "Location=$Location"
echo "VnetName=$VnetName"
echo "AppSubnetName=$AppSubnetName"
echo "VmSubnetName=$VmSubnetName"
echo "VnetCidr=$VnetCidr"
echo "AppSubnetCidr=$AppSubnetCidr"
echo "VmSubnetCidr=$VmSubnetCidr"
echo "PlanName=$PlanName"
echo "WebAppName=$WebAppName"
echo "Runtime=$Runtime"
echo "BotName=$BotName"
echo "AppRegName=$AppRegName"
echo "VmName=$VmName"
echo "VmSize=$VmSize"
echo "VmAdminUser=$VmAdminUser"
echo "VmLocation=$VmLocation"
echo "SafeDelay=$SafeDelay"
echo "WorkDir=$WorkDir"
# Derived
echo "WebAppUrl=$WebAppUrl"
echo "BotEndpoint=$BotEndpoint"
# App registration
echo "AppId=$AppId"
echo "TenantId=$TenantId"
echo "AppSecret=$AppSecret"
# Bot resource
echo "BotResourceId=$BotResourceId"
# Direct Line channel config
echo "DLSecret=" + $DLSecret
# Build/deploy paths
echo "BotPath=$BotPath"
echo "Startup=$Startup"
echo "IndexDir=$IndexDir"
echo "ZipPath=$ZipPath"
# VM creation
# NOTE: Do NOT echo SecureString directly
echo "VmPass=" + $VmPass


