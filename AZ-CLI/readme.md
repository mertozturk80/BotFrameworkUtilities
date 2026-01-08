
# BotFramework Utilities (AZ-CLI)

A concise catalog of PowerShell scripts for deploying and configuring an Bots on Azure, including Direct Line App Service Extension (DL ASE) setup and network isolation.

---

## Script Index

| Script | Purpose |
|---|---|
| `DeployBBEchoBotTemplateToNewRG.ps1` | Provisions an Echo Bot on Azure — logs in and sets the subscription, creates a resource group, App Service plan and Web App (WebSockets), registers an Entra app and secret, configures app settings, creates a Bot Service registration, builds and deploys the BotBuilder echo sample, and writes a test index.html for classic Direct Line. |
| `DeployBBEchoBotDirectlineASEToNewRG.ps1` | Provisions and configures an Echo Bot with Direct Line App Service Extension — sets subscription and resource group, creates VNet/subnets, App Service plan and Web App (WebSockets), registers Entra app and secret, creates Bot registration, enables and configures DL ASE (extension key/version) via app settings, builds and deploys the Echo sample, writes DL ASE test pages, attempts best‑effort DL secret capture, and restarts the app. |
| `PerformDirectlineASEIsolationSteps.ps1` | Applies DL ASE isolation steps for an already created bot — adds integration and private endpoint subnets, configures NSGs (allow Bot Service/AAD, deny defaults), integrates Web App with VNet (route all outbound), creates private DNS zones and links, provisions Private Endpoints for sites and SCM, and disables public network access. |

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
az login
pwsh ./AZ-CLI/DeployBBEchoBotTemplateToNewRG.ps1
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