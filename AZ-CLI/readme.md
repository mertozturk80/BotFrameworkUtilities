
# BotFramework Utilities (AZ-CLI)

A concise catalog of PowerShell scripts for deploying and configuring an Bots on Azure, including Direct Line App Service Extension (DL ASE) setup and network isolation.

---

## Script Index

Agents SDK based deploying scripts:

| Script | Purpose | Resources |
|---|---|---|
| `DeployAgentsBotTemplateToNewRG.ps1` | Provisions a .NET Agents SDK bot on Azure App Service (Windows) — logs in and sets the subscription, creates a resource group, Windows App Service plan and Web App (WebSockets, .NET runtime), registers an Entra app and secret, configures Azure Bot registration, clones the microsoft/Agents repository, builds the quickstart sample, creates appsettings.json with Agents SDK authentication (MSAL), and deploys via ZIP to App Service. | <img width="559" height="253" alt="image" src="https://github.com/user-attachments/assets/d2a8db4f-69d3-4a30-96e7-5a9ea0e0127f" />|
| `DeploySemanticKernelMultiturnToNewRG.ps1` | Provisions a .NET Agents SDK bot with Semantic Kernel and Azure OpenAI on Azure App Service (Windows) — logs in and sets subscription, creates resource group, creates Azure OpenAI resource with custom subdomain and deploys GPT model, creates App Service plan and Web App (WebSockets enabled), enables system-assigned managed identity on App Service, grants Cognitive Services OpenAI User role to the managed identity, registers Entra app and secret, configures Azure Bot registration, clones the microsoft/Agents repository, builds the semantic-kernel-multiturn sample, modifies Program.cs to use DefaultAzureCredential for token-based authentication, creates appsettings.json with Agents SDK authentication and Azure OpenAI endpoint (no API key), and deploys via ZIP to App Service. | <img width="324" height="169" alt="image" src="https://github.com/user-attachments/assets/8db95b9b-2ba5-46ea-92ad-c33d1a478c23" />
|

Here is the result of `DeploySemanticKernelMultiturnToNewRG.ps1`: 

![SemanticKernelBotResponds](https://github.com/user-attachments/assets/6a27b3af-94bb-42e4-9e02-769d30819d42)


Bot Builder SDK based deploying scripts:

| Script | Purpose | Resources |
|---|---|---|
| `DeployBBEchoBotTemplateToNewRG.ps1` | Provisions an Bot Builder Echo Bot on Azure — logs in and sets the subscription, creates a resource group, App Service plan and Web App (WebSockets), registers an Entra app and secret, configures app settings, creates a Bot Service registration, builds and deploys the BotBuilder echo sample, and writes a test index.html for classic Direct Line. |<img width="499" height="144" alt="image" src="https://github.com/user-attachments/assets/42d04b7d-00c8-4028-9c0e-df6dbd3ca3da"/>|
| `DeployBBEchoBotDirectlineASEToNewRG.ps1` | Provisions and configures an Echo Bot with Direct Line App Service Extension — sets subscription and resource group, creates VNet/subnets, App Service plan and Web App (WebSockets), registers Entra app and secret, creates Bot registration, enables and configures DL ASE (extension key/version) via app settings, builds and deploys the Echo sample, writes DL ASE test pages, attempts best‑effort DL secret capture, and restarts the app. | <img width="516" height="335" alt="image" src="https://github.com/user-attachments/assets/226855d7-f154-42d1-94fd-89487d238272" />|
| `PerformDirectlineASEIsolationSteps.ps1` | Complementary script to DeployBBEchoBotDirectlineASEToNewRG.ps1, as it applies DL ASE isolation steps for an already created bot — adds integration and private endpoint subnets, configures NSGs (allow Bot Service/AAD, deny defaults), integrates Web App with VNet (route all outbound), creates private DNS zones and links, provisions Private Endpoints for sites and SCM, and disables public network access. | <img width="523" height="329" alt="image" src="https://github.com/user-attachments/assets/9e47e75f-86cb-4ab8-9dbd-a421415b6391" />|

After each script is finished, it will flush the replay variables, which include all the variables required for powershell for next sessions.

> **⚠️ DEPRECATION NOTICE**: The Bot Builder SDK scripts above are provided for legacy support only. The Bot Builder SDK has been deprecated by Microsoft. **New projects should use the Agents SDK** (see `DeployAgentsBotTemplateToNewRG.ps1` above), which offers modern authentication patterns, improved security, and active support. For migration guidance, see the [Microsoft Agents SDK documentation](https://github.com/microsoft/Agents).

---

## Notes

- All purposes above are sourced from each script’s summary section for accuracy.
- Handle secrets (e.g., `AppSecret`, `DLSecret`) securely; do not commit or expose in client code.
- Some operations (e.g., Direct Line secret retrieval) may require portal actions or Key Vault storage depending on policy.

---

## Quick Start

- Open PowerShell (`pwsh`) and run the desired script after updating parameters near the top of the file.

```powershell
# Example
pwsh ./AZ-CLI/DeployAgentsBotTemplateToNewRG.ps1
```

---

© BotFrameworkUtilities

---

**Developer:** Mert Ozturk

**License (MIT):**

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
