<#
.SYNOPSIS
    Creates or use an Azure Automation account and imports a runbook.

.DESCRIPTION
    This script connects to Azure, creates a resource group (if it does not exist),
    creates an Automation account, imports a runbook from a specified file, and then publishes
    the runbook. The runbook type defaults to "PowerShell", but you can change it to other types
    like "PowerShellWorkflow", "Python2", "Python3", or "Graph" if needed.

.PARAMETER ResourceGroupName
    Name of the resource group in which the Automation account will be created.

.PARAMETER AutomationAccountName
    Name of the Azure Automation account.

.PARAMETER Location
    Azure region where the resource group and automation account will be created (e.g., "EastUS").

.PARAMETER RunbookName
    Name to assign to the imported runbook in the Automation account.

.PARAMETER RunbookPath
    Full local file path to the runbook script that will be imported.

.PARAMETER RunbookType
    Type of runbook. Allowed values: "PowerShell", "PowerShellWorkflow", "Graph",
    "Python2", "Python3" (default is "PowerShell").

.EXAMPLE
    .\CreateAutomationAndImportRunbook.ps1 -ResourceGroupName "MyResourceGroup" `
        -AutomationAccountName "MyAutomation" -Location "EastUS" `
        -RunbookName "TestRunbook" -RunbookPath "C:\Runbooks\TestRunbook.ps1" `
        -RunbookType "PowerShell"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$Location,
    
    [Parameter(Mandatory = $true)]
    [string]$RunbookName,
    
    [Parameter(Mandatory = $true)]
    [string]$RunbookPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet("PowerShell","PowerShell72", "PowerShellWorkflow", "Graph", "Python2", "Python3")]
    [string]$RunbookType = "PowerShell"
)
# Suppress unnecessary logging output
$VerbosePreference      = "SilentlyContinue"
$DebugPreference        = "SilentlyContinue"
$ProgressPreference     = "SilentlyContinue"
$InformationPreference  = "SilentlyContinue"
$WarningPreference      = "SilentlyContinue"
# Define role assignments to apply
$roleAssignments = @(
    @{ RoleName = "SQL DB Contributor"; Description = "For Azure SQL Databases and Azure SQL Elastic Pools" },
    @{ RoleName = "SQL Managed Instance Contributor"; Description = "For Azure SQL Managed Instances and Azure SQL Instance Pools" },
    @{ RoleName = "Data Factory Contributor"; Description = "For Azure Data Factory SSIS Integration Runtimes" },
    @{ RoleName = "Virtual Machine Contributor"; Description = "For SQL Servers in Azure Virtual Machines" },
    @{RoleName = "SQL Server Contributor"; Description = "For Elastic-Pools in Azure Virtual Machines"},
    @{RoleName = "Azure Connected Machine Resource Administrator "; Description = "For SQL Servers in Arc Virtual Machines"},
    @{RoleName = "Reader "; Description = "For read resources in the subscription"}
)
function Connect-Azure {
        try {
            Write-Output "Testing if it is connected to Azure."
            # Attempt to retrieve the current Azure context
            $context = Get-AzContext -ErrorAction SilentlyContinue
    
            if ($null -eq $context -or $null -eq $context.Account) {
                Write-Output "Not connected to Azure. Executing Connect-AzAccount..."
                if($UseManageIdentity){
                    Connect-AzAccount -Identity -ErrorAction Stop  | Out-Null
                } else {
                    Connect-AzAccount -ErrorAction Stop  | Out-Null
                }
                $context = Get-AzContext
                Write-Output "Connected to Azure as: $($context.Account)"
            }
            else {
                Write-Output "Already connected to Azure as: $($context.Account)"
            }
        }
        catch {
            Write-Error "An error occurred while testing the Azure connection: $_"
        }
        # Ensure the user is logged in to Azure
        try {
            $account = az account show 2>$null | ConvertFrom-Json
            if ($account) {
                Write-Output "Logged in as: $($account.user.name)"
            }
        } catch {
            Write-Output "Not logged in. Run 'az login'."
            if($UseManageIdentity){
                az login --Identity  | Out-Null
            } else {    
                az login  | Out-Null
            }
        }
    }

# Connect to Azure.
Write-Output "Connecting to Azure..."
Connect-Azure

# Check if the resource group exists; if not, create it.
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    Write-Output "Creating Resource Group '$ResourceGroupName' in region '$Location'..."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location  | Out-Null
}
else {
    Write-Output "Resource Group '$ResourceGroupName' already exists."
}

# Check if the Automation Account exists; if not, create it.
$automationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction SilentlyContinue
if ($null -eq $automationAccount) {
    Write-Output "Automation Account '$AutomationAccountName' not found. Creating it..."
    $automationAccount = New-AzAutomationAccount -Name $AutomationAccountName -ResourceGroupName $ResourceGroupName -Location $Location -AssignSystemIdentity 
} else {
    Write-Output "Automation Account '$AutomationAccountName' already exists."
}
# Assign roles to the Automation Account's system-assigned managed identity.
$principalId = $automationAccount.Identity.PrincipalId
Write-Host $principalId 
if ($null -eq $principalId) {
    Write-Host "The Automation Account does not have a system-assigned managed identity enabled." -ForegroundColor Yellow
    exit
} else {
    Write-Host "Automation Account Object ID (PrincipalId): $principalId" -ForegroundColor Green
    foreach ($assignment in $roleAssignments) {
        $roleName = $assignment.RoleName
        Write-Host "Assigning role '$roleName' to Managed Identity '$AutomationAccountName' at scope '$Scope'..." -ForegroundColor Yellow
        try {
            New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $roleName -Scope "/subscriptions/$($context.Subscription.Id)"   -ErrorAction Stop  | Out-Null
            Write-Host "Role '$roleName' assigned successfully." -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to assign role '$roleName': $_"
        }
    }
}

# Import the runbook into the Automation Account.
if (-not (Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -ErrorAction SilentlyContinue)) {
    Write-Output "Importing Runbook '$RunbookName' from file '$RunbookPath' into Automation Account '$AutomationAccountName'..."
    Import-AzAutomationRunbook -AutomationAccountName $AutomationAccountName `
        -Name $RunbookName `
        -ResourceGroupName $ResourceGroupName `
        -Path $RunbookPath `
        -Type $RunbookType `
        -Force `
        -Published `
        -LogProgress $True   | Out-Null
    }
else {
    Write-Output "Runbook '$RunbookName' already exists. It will be updated."
    Write-Output "Importing Runbook '$RunbookName' from file '$RunbookPath' into Automation Account '$AutomationAccountName'..."
    Set-AzAutomationRunbook -AutomationAccountName $AutomationAccountName `
    -Name $RunbookName `
    -ResourceGroupName $ResourceGroupName `
    -LogProgress $True  | Out-Null
    Write-Output "Runbook '$RunbookName' has been updated." 

}


# Create a daily schedule for the runbook (if it doesn't exist).
$ScheduleName = "$($RunbookName)_defaultschedule"
if (-not (Get-AzAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $ScheduleName -ErrorAction SilentlyContinue)) {
    Write-Output "Creating schedule '$ScheduleName'..."
    # Set the schedule to start 5 minutes from now and expire in one year, with daily frequency.
    New-AzAutomationSchedule `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $ScheduleName `
        -StartTime (Get-Date).AddDays(1)`
        -WeekInterval 1 `
        -DaysOfWeek @([System.DayOfWeek]::Monday..[System.DayOfWeek]::Sunday) `
        -TimeZone 'UTC' `
        -Description 'Default schedule for runbook'   | Out-Null
} else {
    Write-Output "Schedule '$ScheduleName' already exists."
}

# Define sample parameter values to pass to the runbook when scheduled.
$sampleParameters = @{
    Force_Start_On_Resources = $True
}

# Link the schedule to the runbook, including the sample parameters.
Write-Output "Assigning schedule '$ScheduleName' to runbook '$RunbookName' with sample parameters..."
Register-AzAutomationScheduledRunbook `
    -AutomationAccountName $AutomationAccountName `
    -ResourceGroupName $ResourceGroupName `
    -RunbookName $RunbookName `
    -ScheduleName $ScheduleName `
    -Parameters $sampleParameters  | Out-Null

Start-AzAutomationRunbook `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $RunbookName `
    -Parameters $sampleParameters `
    -ErrorAction SilentlyContinue | Out-Null

Write-Output "Runbook '$RunbookName' has been imported and published successfully."
