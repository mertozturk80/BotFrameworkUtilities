
# DL ASE isolation on top of CreateDirectlineASEWithEchoBot.ps1 script. 

# ============================================================
# 3a) Extra subnets for integration + private endpoints
#     (PE subnet must have private endpoint policies disabled)
# ============================================================
$IntSubnetName = "webapp-int"
$IntSubnetCidr = "10.20.2.0/24"
$PeSubnetName  = "privatelink"
$PeSubnetCidr  = "10.20.4.0/24"
az network vnet subnet create `
  --resource-group $RG `
  --vnet-name $VnetName `
  --name $IntSubnetName `
  --address-prefixes $IntSubnetCidr
az network vnet subnet create `
  --resource-group $RG `
  --vnet-name $VnetName `
  --name $PeSubnetName `
  --address-prefixes $PeSubnetCidr
# Disable private endpoint network policies on PE subnet (recommended)
az network vnet subnet update `
  --resource-group $RG `
  --vnet-name $VnetName `
  --name $PeSubnetName `
  --disable-private-endpoint-network-policies true
Start-Sleep -Seconds $SafeDelay

# ============================================================
# 3b) NSGs: lock down traffic while keeping DL-ASE working
# ============================================================

$IntNsgName = "dlase-webapp-int-nsg"
$PeNsgName  = "dlase-pe-nsg"
# Create NSGs
az network nsg create --resource-group $RG --name $IntNsgName --location $Location
az network nsg create --resource-group $RG --name $PeNsgName  --location $Location
# Associate NSGs to subnets
az network vnet subnet update `
  --resource-group $RG `
  --vnet-name $VnetName `
  --name $IntSubnetName `
  --network-security-group $IntNsgName
az network vnet subnet update `
  --resource-group $RG `
  --vnet-name $VnetName `
  --name $PeSubnetName `
  --network-security-group $PeNsgName
# --- Rules on Integration subnet (OUTBOUND)
# Allow DL-ASE outbound HTTPS to Bot Service + AAD via service tags
az network nsg rule create -g $RG --nsg-name $IntNsgName -n "allow-botservice-443" `
  --priority 1000 --direction Outbound --access Allow --protocol Tcp `
  --source-address-prefixes "*" --source-port-ranges "*" `
  --destination-address-prefixes "AzureBotService" --destination-port-ranges 443
az network nsg rule create -g $RG --nsg-name $IntNsgName -n "allow-aad-443" `
  --priority 1010 --direction Outbound --access Allow --protocol Tcp `
  --source-address-prefixes "*" --source-port-ranges "*" `
  --destination-address-prefixes "AzureActiveDirectory" --destination-port-ranges 443
# Optional: add a conservative default outbound deny (place after allows, high number)
az network nsg rule create -g $RG --nsg-name $IntNsgName -n "deny-outbound-default" `
  --priority 4096 --direction Outbound --access Deny --protocol "*"
  
# --- Rules on Private Endpoint subnet (INBOUND)
# Allow HTTPS from VM subnet to the Private Endpoint NICs
az network nsg rule create -g $RG --nsg-name $PeNsgName -n "allow-vm-to-pe-443" `
  --priority 1000 --direction Inbound --access Allow --protocol Tcp `
  --source-address-prefixes $VmSubnetCidr --source-port-ranges "*" `
  --destination-address-prefixes "*" --destination-port-ranges 443
# Optional: deny all other inbound to PE subnet
az network nsg rule create -g $RG --nsg-name $PeNsgName -n "deny-inbound-default" `
  --priority 4096 --direction Inbound --access Deny --protocol "*"




# ============================================================
# 4a) Integrate Web App with VNET (outbound via IntSubnet)
# ============================================================

#VNET integration for the Web App (append after your Step 4 Web App creation)
#VNET integration provides outbound reach from App Service into your VNET (it does not provide inbound private access—that’s what Private Endpoints are for). WEBSITE_VNET_ROUTE_ALL=1 ensures flows honor your NSG. [Integrate...soft Learn | Learn.Microsoft.com]


az webapp vnet-integration add `
  --resource-group $RG `
  --name $WebAppName `
  --vnet $VnetName `
  --subnet $IntSubnetName
# Route all outbound through the VNET so NSG rules apply
az webapp config appsettings set `
  --resource-group $RG `
  --name $WebAppName `
  --settings WEBSITE_VNET_ROUTE_ALL=1



# ============================================================
# 8a) Private DNS zones + links for App Service
#     - main site: privatelink.azurewebsites.net
#     - SCM/Kudu : privatelink.scm.azurewebsites.net
# ============================================================

#Add‑on: Private Endpoints + Private DNS (append after your Step 6–8 bot setup)
#Notes
#• Private endpoints are for inbound private access; you typically need both sites and scm subresources so Kudu/zip deploy works from inside the VNET. 
#• Use the two Private DNS zones above; SCM has its own zone (privatelink.scm.azurewebsites.net). The dns-zone-group commands wire the A records automatically. 
#• Disable public network access to finish isolation. App Service exposes properties.publicNetworkAccess for that switch. [learn.microsoft.com] [learn.microsoft.com], [learn.microsoft.com] [azadvertizer.net], [learn.microsoft.com]


$DnsZoneSites = "privatelink.azurewebsites.net"
$DnsZoneScm   = "privatelink.scm.azurewebsites.net"
az network private-dns zone create --resource-group $RG --name $DnsZoneSites
az network private-dns zone create --resource-group $RG --name $DnsZoneScm
# Link zones to VNET
az network private-dns link vnet create `
  --resource-group $RG `
  --zone-name $DnsZoneSites `
  --name "${VnetName}-link-sites" `
  --virtual-network $VnetName `
  --registration-enabled false
az network private-dns link vnet create `
  --resource-group $RG `
  --zone-name $DnsZoneScm `
  --name "${VnetName}-link-scm" `
  --virtual-network $VnetName `
  --registration-enabled false
# ============================================================
# 8b) Private Endpoints for Web App (sites + scm)
# ============================================================
$WebAppId = "/subscriptions/$SubscriptionId/resourceGroups/$RG/providers/Microsoft.Web/sites/$WebAppName"
# PE for main site
$PeSitesName = "$($WebAppName)-pe-sites"
az network private-endpoint create `
  --resource-group $RG `
  --name $PeSitesName `
  --vnet-name $VnetName `
  --subnet $PeSubnetName `
  --private-connection-resource-id $WebAppId `
  --group-id "sites" `
  --connection-name "$($WebAppName)-pe-sites-conn"
# Attach DNS zone group for 'sites'
az network private-endpoint dns-zone-group create `
  --resource-group $RG `
  --endpoint-name $PeSitesName `
  --name "sites-zone-group" `
  --private-dns-zone $DnsZoneSites `
  --zone-name "$($WebAppName)-sites-dns"

# PE for SCM/Kudu
# DNS zone names
$DnsZoneSites = "privatelink.azurewebsites.net"
$DnsZoneScm   = "privatelink.scm.azurewebsites.net"


# Create zones (no-op if they already exist)
az network private-dns zone create --resource-group $RG --name $DnsZoneSites
az network private-dns zone create --resource-group $RG --name $DnsZoneScm
# Link both zones to the VNET (ignore if already linked)
az network private-dns link vnet create `
  --resource-group $RG `
  --zone-name $DnsZoneSites `
  --name "${VnetName}-link-sites" `
  --virtual-network $VnetName `
  --registration-enabled false 2>$null
az network private-dns link vnet create `
  --resource-group $RG `
  --zone-name $DnsZoneScm `
  --name "${VnetName}-link-scm" `
  --virtual-network $VnetName `
  --registration-enabled false 2>$null


# Show both zone configs under the single group
az network private-endpoint dns-zone-group list `
  --resource-group $RG `
  --endpoint-name $PeSitesName `
  -o json | ConvertFrom-Json | ForEach-Object {
    $_.name
    $_.privateDnsZoneConfigs | Select-Object privateDnsZoneId, zoneName
  }
# Resolution tests from inside the VNET
nslookup $WebAppName.azurewebsites.net
nslookup "$WebAppName.scm.azurewebsites.n



# ============================================================
# 8c) Disable public network access (enforce private-only)
# ============================================================

$WebAppResId = "/subscriptions/$SubscriptionId/resourceGroups/$RG/providers/Microsoft.Web/sites/$WebAppName"
az resource update --ids $WebAppResId --set properties.publicNetworkAccess=Disabled



***************  Dump from the test ******************


Write-Host "=== DL-ASE Network Isolation Variables ==="
Write-Host "SubscriptionId: $SubscriptionId"
Write-Host "RG:             $RG"
Write-Host "Location:       $Location"
Write-Host "VnetName:       $VnetName"
Write-Host "AppSubnetName:  $AppSubnetName"
Write-Host "VmSubnetName:   $VmSubnetName"
Write-Host "IntSubnetName:  $IntSubnetName"
Write-Host "PeSubnetName:   $PeSubnetName"
Write-Host "PlanName:       $PlanName"
Write-Host "WebAppName:     $WebAppName"
Write-Host "BotName:        $BotName"
Write-Host "AppRegName:     $AppRegName"
Write-Host "VmName:         $VmName"
Write-Host "VmSize:         $VmSize"
Write-Host "VmAdminUser:    $VmAdminUser"
Write-Host "VmLocation:     $VmLocation"
Write-Host "DnsZoneSites:   $DnsZoneSites"
Write-Host "DnsZoneScm:     $DnsZoneScm"
Write-Host "PeSitesName:    $PeSitesName"
Write-Host "PeScmName:      $PeScmName"
Write-Host "WebAppId:       $WebAppId"
Write-Host "WebAppResId:    $WebAppResId"
Write-Host "ExtensionKey:   $ExtensionKey"
Write-Host "AppId:          $AppId"
Write-Host "AppSecret:      $AppSecret"
Write-Host "TenantId:       $TenantId"
Write-Host "WebAppUrl:      $WebAppUrl"
Write-Host "BotEndpoint:    $BotEndpoint"
Write-Host "==========================================="
