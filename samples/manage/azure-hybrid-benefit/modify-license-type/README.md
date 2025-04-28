# schedule-pay-transition.ps1

## Overview

`schedule-pay-transition.ps1` automates the process of applying pay-transition licensing for Azure and Azure Arc–connected SQL resources. It supports two modes:

- **Single**: Download and invoke the Azure and/or Arc pay-transition scripts immediately, then optionally clean up the downloads.
- **Scheduled**: Register or update a task (Windows Scheduled Task or Automation schedule) to run daily at a specified time and day.

By centralizing these steps, you ensure consistent licensing across your estate with minimal manual effort.

---

## Permissions

The account or service principal running this script must have at least the **Contributor** role (or **Owner**) on the target subscription. This permission allows the script to:

- Create resource groups and Automation accounts
- Assign roles to the managed identity
- Import modules into the Automation account
- Import, publish, and run the runbook
- Configure and link schedules to the runbook

---

## Download & Execution

You can fetch and run the script locally or in Azure Cloud Shell. Below are examples using both PowerShell cmdlets and `curl`.

### From Local PowerShell (Windows or PowerShell 7)

**Using PowerShell**:

```powershell
# Download
authentication required
download completed
# Execute (Single run)
.\schedule-pay-transition.ps1 \
  -Target Both \
  -RunMode Single \
  -cleanDownloads:$true \
  -UsePcoreLicense No \
  -targetSubscription 00000000-0000-0000-0000-000000000000 \
  -targetResourceGroup MyRG \
  -AutomationAccResourceGroupName MyAutoRG \
  -AutomationAccountName MyAutoAcct \
  -Location EastUS
```

**Using curl**:

```powershell
# Download
curl.exe -L \
  https://raw.githubusercontent.com/<your-org>/<your-repo>/master/schedule-pay-transition.ps1 \
  -o schedule-pay-transition.ps1

# Execute
pwsh.exe .\schedule-pay-transition.ps1 \
  -Target Azure \
  -RunMode Scheduled \
  -AutomationAccResourceGroupName MyAutoRG \
  -Location EastUS \
  -Time 08:00AM \
  -DayOfWeek Sunday
```

### From Azure Cloud Shell (Bash or PowerShell)

**Bash + curl + PowerShell**:

```bash
# Download
curl -sL https://raw.githubusercontent.com/<your-org>/<your-repo>/master/schedule-pay-transition.ps1 -o schedule-pay-transition.ps1

# Execute in PowerShell Core
pwsh schedule-pay-transition.ps1 \
  -Target Both \
  -RunMode Single \
  -cleanDownloads \
  -AutomationAccResourceGroupName MyAutoRG \
  -Location EastUS
```

**PowerShell in Cloud Shell**:

```powershell
# Download
Invoke-RestMethod \
  -Uri https://raw.githubusercontent.com/<your-org>/<your-repo>/master/schedule-pay-transition.ps1 \
  -OutFile schedule-pay-transition.ps1

# Execute
.\schedule-pay-transition.ps1 \
  -Target Azure \
  -RunMode Scheduled \
  -AutomationAccResourceGroupName MyAutoRG \
  -Location EastUS \
  -Time 02:00AM \
  -DayOfWeek Wednesday
```

---

## Parameters

| Parameter                         | Required | Type        | Description                                                           |
| --------------------------------- | :------: | ----------- | --------------------------------------------------------------------- |
| `-Target`                         | Yes      | `String`    | `Arc`, `Azure`, or `Both`—which pay-transition to run.                |
| `-RunMode`                        | Yes      | `String`    | `Single` or `Scheduled`.                                              |
| `-cleanDownloads`                 | No       | `Switch`    | If specified in `Single` mode, deletes the download folder afterward. |
| `-UsePcoreLicense`                | No       | `String`    | (`Arc` only) `Yes` or `No` for PCore licensing. Default: `No`.        |
| `-targetResourceGroup`            | No       | `String`    | Target resource group for the downstream runbook.                     |
| `-targetSubscription`             | No       | `String`    | Target subscription ID for the downstream runbook.                    |
| `-AutomationAccResourceGroupName` | Yes      | `String`    | Resource group containing the Automation account.                     |
| `-AutomationAccountName`          | No       | `String`    | Automation account name. Default: `aaccAzureArcSQLLicenseType`.       |
| `-Location`                       | Yes      | `String`    | Azure region (e.g. `EastUS`).                                         |
| `-Time`                           | No       | `String`    | (Scheduled) Time (`h:mmtt`, e.g. `08:00AM`). Default: `8:00AM`.       |
| `-DayOfWeek`                      | No       | `DayOfWeek` | (Scheduled) Day of week. Default: `Sunday`.                           |

---

## Examples

### Single Run (Arc + Azure) with Cleanup

```powershell
.\schedule-pay-transition.ps1 \
  -Target Both \
  -RunMode Single \
  -cleanDownloads \
  -UsePcoreLicense No \
  -targetSubscription 00000000-0000-0000-0000-000000000000 \
  -targetResourceGroup MyRG \
  -AutomationAccResourceGroupName MyAutoRG \
  -AutomationAccountName MyAutoAcct \
  -Location EastUS
```

### Scheduled Azure-Only Run (Every Sunday at 8 AM)

```powershell
.\schedule-pay-transition.ps1 \
  -Target Azure \
  -RunMode Scheduled \
  -AutomationAccResourceGroupName MyAutoRG \
  -Location EastUS \
  -Time 08:00AM \
  -DayOfWeek Sunday
```



