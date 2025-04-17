---
services: Azure SQL
platforms: Azure
author: anosov1960,rodrigomonteiro-gbb
ms.author: sashan.romontei
ms.date: 04/08/2025
---

# Overview

This Azure Runbook updates the license type for various Azure SQL resources using Azure CLI and PowerShell commands. It automates the process of modifying license settings for SQL Databases, Elastic Pools, SQL Managed Instances, SQL Instance Pools, SQL Virtual Machines, and DataFactory SSIS Integration Runtimes. The script supports targeting a single subscription, a list of subscriptions defined in a CSV file, or all accessible subscriptions. Optionally, it can also start resources that are stopped (if the -Force_Start_On_Resources parameter is enabled).

This script is designed to help administrators standardize SQL licensing across their Azure environment by automating license updates. In summary, the script:

Targets Multiple Resource Types:
SQL Virtual Machines: Updates license types after checking if the VM is running. If not, it can optionally start the VM to perform the update.
SQL Managed Instances: Detects instances that are stopped or not in the "Ready" state and can force them to start before updating.
SQL Databases & Elastic Pools: Scans individual SQL servers to locate databases and elastic pools with a different license type and updates them accordingly.
SQL Instance Pools: Locates instance pools that require an update.
DataFactory SSIS Integration Runtimes: Checks for integration runtimes with an out-of-date license setting and updates them.
Flexible Subscription Targeting:
The script accepts a subscription ID or CSV file (for a list of subscriptions). If no subscription is specified, it defaults to updating resources in all accessible subscriptions.
Interactive Reporting:
The script logs steps along the process and compiles a final report summarizing which resources were updated in each category.
Seamless Integration with Azure Authentication:
It uses managed identity authentication (via Connect-AzAccount -Identity and az login --identity) to connect to your Azure environment securely.

# Required Permissions
The automation account needs to have the bellow permissions in order to be able to successfully run the Runbook and update all the SQL Server resources license type:

1. **SQL DB Contributor**: *SQL DB Contributor role*. 
1. **SQL Managed Instance Contributor**: *SQL Managed Instance Contributor*
1. **SQL Server Contributor**: *SQL Managed Instance Contributor*
1. **Data Factory Contributor**: *Data Factory Contributor role*.
1. **Virtual Machine Contributor**: *Virtual Machine Contributor role*. 


A *Subscription Contributor* role has sufficient permissions to mdify any of the above resources. 

# Additional Information

Script Parameters:
- SubId: A single subscription ID or the filename of a CSV file containing multiple subscriptions.
- ResourceGroup: (Optional) Limits the script’s operations to a specific resource group.
- LicenseType: (Optional) Defines the target license type. Valid values are "LicenseIncluded" (default) or "BasePrice".
- Force_Start_On_Resources: (Optional) When enabled, the script will attempt to start SQL VMs and SQL Managed Instances if they are not running before applying the update.
Logging & Error Handling:

The script logs key actions to the console and captures error messages using Write-Error. Check the console output for a summary report detailing which resources were updated.

# Customizations:
You might want to customize the script’s logging or incorporate additional logging (e.g., writing to a file or Azure Log Analytics) to integrate seamlessly with your monitoring and reporting workflow.

# Creating an Azure Runbook

You can schedule the command to run as a runbook. Follow these steps using the Azure Portal:

### 1. Download the Script

Open a command shell on your device and run the command below. This will copy the script to your local folder.

```console
curl curl https://raw.githubusercontent.com/rodrigomonteiro-gbb/arc-sql-dashboard/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/Schedule-PAYG-Transition.ps1 -o Schedule-PAYG-Transition.ps1
```
### 2. Create or Use an Existing Automation Account
[Create a new automation account](https://ms.portal.azure.com/#create/Microsoft.AutomationAccount)  or open an existing one.
In the Advanced section, ensure that System assigned identity is selected.
### 3. Import the Runbook
Navigate to the Process Automation group and select Runbooks.
Click on the Import a runbook tab and configure it:
File: Select the file you downloaded in Step 1.
Name: Enter a name for the runbook.
Type: Set to PowerShell.
Runtime Version: Choose 7.2.
Click Import.
### 4. Publish the Runbook
After the runbook is imported, click the Publish button to make it available for scheduling.

### 5. Link the Runbook to a Schedule
Once the runbook status is Published, click on the Link to schedule button.
Select Link a schedule to your runbook and click + Add a schedule.
Configure the schedule:
Name: Provide a name for the schedule.
Start Time: Set the desired start time.
Recurrence: Choose the recurrence need it.
Click Create.
### 6. Configure Runbook Parameters
Return to the Schedule runbook page.
Click on Parameters and run settings.
Paste the license ID value into the appropriate field.
Click OK to link the schedule, then OK again to create the job.
### 7. Verify the Runbook Execution
On the runbook Overview page, open a recent job that was completed after the scheduled start time.
Click on the Output tab and verify that you see:
Properties.activationState=Activated
Your license is now active.

For more information about the runbooks, see the [Runbook tutorial](https://docs.microsoft.com/en-us/azure/automation/learn/automation-tutorial-runbook-textual-powershell)