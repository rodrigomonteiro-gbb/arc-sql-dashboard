# Schedule pay Transition

## Overview

**schedule-pay-transition.ps1** is a PowerShell script that either:

- **Runs once**: Downloads and invokes environment‑specific “pay transition” scripts for Azure, Arc, or both.
- **Schedules itself**: Registers a Windows Scheduled Task to run daily at 2 AM, invoking itself in “Single” mode.

It supports optional cleanup of downloaded files and passing extra parameters (target resource group, subscription, etc.) to the downstream scripts.

---

## Prerequisites

- **PowerShell 5+.**
- **User running needs to be Azure Subscription owner or contributor to be able to run the script.**  


---

## Parameters

| Name                   | Mandatory | Type    | Acceptable Values        | Description                                                                                  |
|------------------------|-----------|---------|--------------------------|----------------------------------------------------------------------------------------------|
| `-Target`              | Yes       | String  | `Arc`, `Azure`, `Both`   | Which environment(s) to process.                                                             |
| `-RunMode`             | Yes       | String  | `Single`, `Scheduled`    | `Single` runs immediately; `Scheduled` registers an NT Task to run daily at 2 AM.            |
| `-cleanDownloads`      | No        | Boolean |                          | If `$true`, deletes the download folder after a single run.                                  |
| `-UsePcoreLicense`     | No        | String  | `Yes`, `No`              | Passed to Arc script to control PCore licensing behavior (defaults to `No`).                  |
| `-targetResourceGroup` | No        | String  |                          | Subscription resource group to target in downstream scripts.                                 |
| `-targetSubscription`  | No        | String  |                          | Subscription ID to target in downstream scripts.                                             |
| `-AutomationAccountName` | No      | String  |                          | Automation Account name for the “General” runbook import operation.                          |
| `-Location`            | No        | String  |                          | Azure region for the “General” runbook import operation.                                     |

---

## How It Works

1. **Script URL Configuration**  
   - **General**: points to `set-azurerunbook.ps1` (imports & publishes the helper runbook).  
   - **Azure**: points to `modify-azure-sql-license-type.ps1`.  
   - **Arc**: points to `modify-license-type.ps1` for Arc‑enabled SQL.

2. **Download Folder**  
   - Creates `.\PayTransitionDownloads\` (relative) if missing.  
   - Downloads chosen script(s) into it.

3. **Invoke-RemoteScript**  
   - Downloads a script via `Invoke-RestMethod`.  
   - Invokes it with splatted parameter hashtable derived from `$scriptUrls[...] .Args`.

4. **Modes**  
   - **Single**: Invokes the selected scripts immediately and (optionally) cleans up.  
   - **Scheduled**: Registers or updates a Scheduled Task (run as SYSTEM) to call itself every day at 2 AM with `-RunMode Single`.

5. **Cleanup**  
   - If `-cleanDownloads $true`, removes the download folder after a single run.

---

## Examples

### Run Immediately
#### Both Environments

```powershell
.\schedule-pay-transition.ps1 -Target Both -RunMode Single -cleanDownloads $true `
    -UsePcoreLicense Yes `
    -targetSubscription "00000000-0000-0000-0000-000000000000" `
    -targetResourceGroup "MyRG" `
    -AutomationAccountName "MyAutoAcct" `
    -Location "EastUS"
````

### Arc Only, Single Run, With Cleanup
```powershell
.\schedule-pay-transition.ps1 `
  -Target Arc `
  -RunMode Single `
  -cleanDownloads $true `
  -UsePcoreLicense Yes `
  -targetSubscription "11111111-1111-1111-1111-111111111111" `
  -targetResourceGroup "ArcRG"
````

### Both Azure & Arc, Single Run, Full Parameters
```powershell
.\schedule-pay-transition.ps1 `
  -Target Both `
  -RunMode Single `
  -cleanDownloads $true `
  -UsePcoreLicense No `
  -targetSubscription "22222222-2222-2222-2222-222222222222" `
  -targetResourceGroup "HybridRG" `
  -AutomationAccountName "MyAutomationAccount" `
  -Location "EastUS"
```
### Scheduled-Run Scenarios

#### Schedule Daily for Azure Only
```powershell
.\schedule-pay-transition.ps1 `
  -Target Azure `
  -RunMode Scheduled
```
#### Schedule Daily for Arc Only
```powershell
.\schedule-pay-transition.ps1 `
  -Target Arc `
  -RunMode Scheduled
```

#### Schedule Daily for Both Environments
```powershell
.\schedule-pay-transition.ps1 `
  -Target Both `
  -RunMode Scheduled
```