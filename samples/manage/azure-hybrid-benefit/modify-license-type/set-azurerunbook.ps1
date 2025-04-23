<#
.SYNOPSIS
    Creates or uses an Azure Automation account and imports a runbook.

.DESCRIPTION
    This script:
      - Connects to Azure (PowerShell + CLI).
      - Creates the resource group if it doesn't exist.
      - Creates the Automation account (with system identity) if it doesn't exist.
      - Assigns a set of built‑in roles to that managed identity.
      - Imports or updates the specified runbook, publishes it.
      - Creates a daily schedule (if missing) and links it to the runbook.
      - Starts a one‑off job of the runbook.

.PARAMETER ResourceGroupName
    The resource group in which to create/use the Automation account.

.PARAMETER AutomationAccountName
    The Automation account name.

.PARAMETER Location
    Azure region for the RG and account (e.g. "EastUS").

.PARAMETER RunbookName
    The name under which to import/publish the runbook.

.PARAMETER RunbookPath
    Full path to the local .ps1 runbook file.

.PARAMETER RunbookType
    Runbook type: "PowerShell", "PowerShell72", "PowerShellWorkflow", "Graph", "Python2", or "Python3".
    Default: "PowerShell72".

.PARAMETER targetResourceGroup
    (Optional) Resource group passed into the runbook as a parameter.

.PARAMETER targetSubscription
    (Optional) Subscription ID passed into the runbook as a parameter.
#>

param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$AutomationAccountName,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$RunbookName,
    [Parameter(Mandatory)][string]$RunbookPath,
    [Parameter()][Hashtable]$RunbookArg,
    [ValidateSet("PowerShell","PowerShell72","PowerShellWorkflow","Graph","Python2","Python3")]
    [string]$RunbookType = "PowerShell72",
    [string]$targetResourceGroup,
    [string]$targetSubscription
)
# Suppress unnecessary logging output
$VerbosePreference      = "SilentlyContinue"
$DebugPreference        = "SilentlyContinue"
$ProgressPreference     = "SilentlyContinue"
$InformationPreference  = "SilentlyContinue"
$WarningPreference      = "SilentlyContinue"
$context = $null
# Define role assignments to apply
$roleAssignments = @(
    @{ RoleName = "SQL DB Contributor"; Description = "For Azure SQL Databases and Azure SQL Elastic Pools" },
    @{ RoleName = "SQL Managed Instance Contributor"; Description = "For Azure SQL Managed Instances and Azure SQL Instance Pools" },
    @{ RoleName = "Data Factory Contributor"; Description = "For Azure Data Factory SSIS Integration Runtimes" },
    @{ RoleName = "Virtual Machine Contributor"; Description = "For SQL Servers in Azure Virtual Machines" },
    @{RoleName = "SQL Server Contributor"; Description = "For Elastic-Pools in Azure Virtual Machines"},
    @{RoleName = "Azure Connected Machine Resource Administrator"; Description = "For SQL Servers in Arc Virtual Machines"},
    @{RoleName = "Reader"; Description = "For read resources in the subscription"}
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
$context = Get-AzContext -ErrorAction SilentlyContinue
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
$Scope = "/subscriptions/$($context.Subscription.Id)"
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
            if($null -eq (Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $roleName  -Scope $Scope)) {
                New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $roleName -Scope "/subscriptions/$($context.Subscription.Id)"   -ErrorAction Stop  | Out-Null
                Write-Host "Role '$roleName' assigned successfully." -ForegroundColor Green
                continue
            }
            
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
<#
Start-AzAutomationRunbook `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $RunbookName `
    -Parameters $sampleParameters `
    -ErrorAction SilentlyContinue | Out-Null
#>
Write-Output "Runbook '$RunbookName' has been imported and published successfully."
