
# 🚀 DL ASE with Echo Bot – Deployment & Network Isolation

This guide walks you through deploying an Azure App Service Environment (ASE) for Direct Line channel integration with an Echo Bot, and applying advanced network isolation using Azure networking features.

---

## 📦 Script Contents

**Following are the scripts included in this repository:**

- **CreateDirectlineASEWithEchoBot.ps1**  
  Contains PowerShell commands to configure and create all the resources required to set up Direct Line App Service Extension (DL ASE) on an Azure App Service.  
  _Comments in the script are highly descriptive, guiding you through each step of the deployment process._

- **DirectlineASEIsolationSteps.ps1**  
  Contains PowerShell commands to perform network isolation for the DL ASE, building on top of the resources created by the previous script.  
  _This script focuses on securing the environment using subnets, NSGs, private endpoints, and DNS zones._

---

## 🛠️ 1. Resource Provisioning

- **Resource Group & VNet**
  - Creates a dedicated resource group and virtual network with subnets for apps and VMs.
- **App Service Plan & Web App**
  - Deploys a Windows App Service Plan and a Web App (Echo Bot) with WebSockets enabled.
- **Azure Bot Registration**
  - Registers an Azure Bot, configures authentication (App Registration, Service Principal, Secret), and sets up the Direct Line channel with a 1-week expiring credential for enhanced security.
- **Echo Bot Deployment**
  - Clones the BotBuilder samples, modifies the Echo Bot sample for required integrations (WebSockets, Named Pipes), and deploys it to the Web App using ZIP deployment.

---

## ⚡ 2. Direct Line Extension & Configuration

- **Direct Line Extension**
  - Enables the Direct Line App Service Extension, configures required app settings, and restarts the Web App.
- **Web Chat Clients**
  - Adds both a simple HTML and a React-based Web Chat client to the bot’s wwwroot for testing.

---

## 🔒 3. Network Isolation Steps

- **Extra Subnets**
  - Adds integration and private endpoint subnets to the VNet, with appropriate address spaces.
- **Network Security Groups (NSGs)**
  - Creates and associates NSGs to subnets, defining outbound/inbound rules to:
    - Allow only necessary traffic (e.g., HTTPS to Bot Service and AAD).
    - Deny all other traffic by default for strict isolation.
- **VNet Integration**
  - Integrates the Web App with the VNet for outbound traffic, ensuring all flows are subject to NSG rules.
- **Private DNS Zones**
  - Sets up private DNS zones for both the main site and SCM (Kudu), linking them to the VNet.
- **Private Endpoints**
  - Creates private endpoints for the Web App (sites and SCM), attaches DNS zone groups, and disables public network access to enforce private-only connectivity.

---

## 🧪 4. Testing & Validation

- **Windows VM**
  - Deploys a Windows VM in the VNet (no public IP) to test bot connectivity and validate isolation.
- **Health Checks**
  - Runs PowerShell scripts from the VM to verify the health of the DL ASE deployment.

---

## 📋 5. Variable Dump & Documentation

- **Echo Variables**
  - At the end, all key variables (including secrets, resource IDs, endpoints, etc.) are echoed for documentation and troubleshooting.

---

## 💡 How to Use

1. **Edit Parameters**  
   Only the `WebAppName` typically needs to be globally unique; other parameters are pre-set.
2. **Run Scripts Sequentially**  
   Start with the main deployment script, then apply the isolation steps.
3. **Test**  
   Use the deployed VM or the provided web clients to validate the bot and network isolation.

---

## 🔐 Security Notes

- **Secrets**  
  App secrets and Direct Line keys are generated and echoed for convenience but should be handled securely in production.
- **Isolation**  
  Public network access is disabled; only private endpoints and VNet-integrated resources can access the bot.

---

## 📚 References

- Azure CLI documentation for each resource type.
- Microsoft Learn articles on App Service VNet integration, Private Endpoints, and Bot Service Direct Line Extension.

---

**This README summarizes the automation and isolation of a secure, enterprise-grade bot deployment in Azure using PowerShell.**
