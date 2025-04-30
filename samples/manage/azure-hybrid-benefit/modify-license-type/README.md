## Overview

`schedule-pay-transition.ps1` automates the process of applying pay-transition licensing for Azure and Azure Arc–connected SQL resources. It supports two modes:

- **Single**: Download and invoke the Azure and/or Arc pay-transition scripts immediately, then optionally clean up the downloads.
- **Scheduled**: Register or update a task (Automation schedule) to run daily at a specified time and day.

By centralizing these steps, you ensure consistent licensing across your estate with minimal manual effort.

---

## Permissions

### If used for schedule recurents runs using Azure Atomation Account
The account or service principal running this script must have at least the **Contributor** role (or **Owner**) on the target subscription. This permission allows the script to:

- Create resource groups and Automation account
- Assign roles to the Automation account managed identity
- Import modules into the Automation account
- Import, publish, and run the runbook
- Configure and link schedules to the runbook

### If used for single run
The account or service principal running this script must have at least the **Contributor** role (or **Owner**) on the target subscription:
- SQL DB Contributor
- SQL Managed Instance Contributor
- Data Factory Contributor
- Virtual Machine Contributor
- SQL Server Contributor
- Azure Connected Machine Resource Administrator
- Subscription Reader

This permission allows the script to:
- Change license type for Azure SQL Databases and Azure SQL Elastic Pools
- Change license type for Azure SQL Managed Instances and Azure SQL Instance Pools
- Change license type for Azure Data Factory SSIS Integration Runtimes
- Virtual Machine Contributor"; Description = "For SQL Servers in Azure Virtual Machines
- SQL Server Contributor"; Description = "For Elastic-Pools in Azure Virtual Machines
- Change license type for SQL Servers in Arc Virtual Machines
- Change license type for read resources in the subscription

- Create resource groups and Automation account


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
| `-SQLLicenseType`                 | No       | `String`    | SQL license type to be set for the Azure and/or Arc resources.        |
| `EnableESU`                       | No       | `String`    | Enable Extended Security Updates (ESU) for Arc SQL Server VMs.        |
---
## Download & Execution

You can fetch and run the script locally or in Azure Cloud Shell. Below are examples using both PowerShell cmdlets and `curl`.

### From Local PowerShell (Windows or PowerShell 7)

**Using PowerShell for a single time run of the script**:

```powershell
# Download
$git = "arc-sql-dashboard"
$environment = "rodrigomonteiro-gbb"
Invoke-RestMethod `
  -Uri https://raw.githubusercontent.com/$git/$project/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/Schedule-PAYG-Transition.ps1 `
  -OutFile schedule-pay-transition.ps1

# Execute with -Target = Both to Target Both Arc and Azure resources
.\schedule-pay-transition.ps1 `
  -Target Both `
  -RunMode Single `
  -UsePcoreLicense No 
```

```powershell
# Download
$git = "arc-sql-dashboard"
$environment = "rodrigomonteiro-gbb"
Invoke-RestMethod `
  -Uri https://raw.githubusercontent.com/$git/$project/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/Schedule-PAYG-Transition.ps1 `
  -OutFile schedule-pay-transition.ps1

# Execute with -Target = Arc to Target only Arc resource
.\schedule-pay-transition.ps1 `
  -Target Arc `
  -RunMode Single `
  -UsePcoreLicense No 
```

**Using PowerShell for a multiple time runs of the script (schedule using Azure Atomation)**:

```powershell
# Download
$git = "arc-sql-dashboard"
$environment = "rodrigomonteiro-gbb"
Invoke-RestMethod `
  -Uri https://raw.githubusercontent.com/$git/$project/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/Schedule-PAYG-Transition.ps1 `
  -OutFile schedule-pay-transition.ps1

# Execute with -Target = Azure to Target only Azure resource, -RunMode = Schedule to create a schedule run on Azure Automation (-Time = 8:00 and -DayOfWeek = Sunday) eevery Sunday at 8AM local time
 .\schedule-pay-transition.ps1 `
  -Target Azure `
  -RunMode Scheduled `
  -AutomationAccResourceGroupName MyAutoRG `
  -Location EastUS `
  -Time 08:00 `
  -DayOfWeek Sunday





