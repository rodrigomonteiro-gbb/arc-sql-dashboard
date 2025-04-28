<#
.SYNOPSIS
    Creates or uses an Azure Automation account, imports and publishes a runbook, and optionally schedules it.

.DESCRIPTION
    This script will:
      - Authenticate to Azure (PowerShell + CLI).
      - Create the specified resource group if it doesn't exist.
      - Create or reuse an Automation account (with system-assigned identity).
      - Import or update the AzureAD, Az.* modules into that Automation account.
      - Assign built-in roles to the Automation account’s managed identity.
      - Remove any existing copy of the specified runbook, then import & publish the new runbook.
      - Create or update a daily schedule (at your chosen time/day) and link it to the runbook.
      - Start a one-off run of the runbook.

.PARAMETER ResourceGroupName
    The name of the resource group for the Automation account.

.PARAMETER AutomationAccountName
    The name of the Azure Automation account.

.PARAMETER Location
    Azure region (e.g. "EastUS") for the resource group and Automation account.

.PARAMETER RunbookName
    The name under which to import and publish the runbook.

.PARAMETER RunbookPath
    The local path (relative to ./PayTransitionDownloads/) to the runbook .ps1 file.

.PARAMETER RunbookArg
    A hashtable of parameters to pass into the runbook when scheduling or starting it.

.PARAMETER RunbookType
    The runbook type: "PowerShell", "PowerShell72", "PowerShellWorkflow", "Graph", "Python2", or "Python3".
    Default is "PowerShell72".

.PARAMETER targetResourceGroup
    Optional. A resource group name to pass into the runbook as a parameter.

.PARAMETER targetSubscription
    Optional. A subscription ID to pass into the runbook as a parameter.

.PARAMETER Time
    Scheduled run time in "H:mm" 24-hour format (e.g. "08:00" for 8 AM). Default is "8:00".

.PARAMETER TimeZone
    Time zone for the scheduled trigger (e.g. "UTC" or "Pacific Standard Time"). Default is "UTC".

.PARAMETER DayOfWeek
    Day of week for the scheduled trigger. Default is Sunday.

.EXAMPLE
    # One-off import & run, passing target RG/Subscription, then clean up downloads:
    .\ThisScript.ps1 `
       -ResourceGroupName "AutoRG" `
       -AutomationAccountName "MyAutoAcct" `
       -Location "EastUS" `
       -RunbookName "MyRunbook" `
       -RunbookPath "MyRunbook.ps1" `
       -RunbookType "PowerShell72" `
       -targetResourceGroup "AppRG" `
       -targetSubscription "00000000-0000-0000-0000-000000000000" `
       -Time "08:00" `
       -TimeZone "UTC" `
       -DayOfWeek Monday

.EXAMPLE
    # Schedule daily execution at 2 AM Wednesday:
    .\ThisScript.ps1 `
       -ResourceGroupName "AutoRG" `
       -AutomationAccountName "MyAutoAcct" `
       -Location "EastUS" `
       -RunbookName "MyRunbook" `
       -RunbookPath "MyRunbook.ps1" `
       -RunbookType "PowerShell72" `
       -RunbookArg @{ Foo="Bar"; Baz=42 } `
       -RunMode Scheduled `
       -Time "02:00" `
       -TimeZone "Pacific Standard Time" `
       -DayOfWeek Wednesday
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
    [string]$targetSubscription,
    [Parameter(Mandatory=$false)]
    [System.DateTimeOffset]$Time="8:00",
    [Parameter(Mandatory=$false)]
    [string]$TimeZone="UTC",
    [Parameter(Mandatory=$false)]
    [System.DayOfWeek] $DayOfWeek=[System.DayOfWeek]::Sunday
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
    [CmdletBinding()]
    param(
        [switch]$UseManagedIdentity
    )

    # 1) Detect environment
    $envType = "Local"
    if ($env:AZUREPS_HOST_ENVIRONMENT -and $env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*') {
        $envType = "CloudShell"
    }
    elseif (($env:AZUREPS_HOST_ENVIRONMENT -and $env:AZUREPS_HOST_ENVIRONMENT -like 'AzureAutomation*') -or $PSPrivateMetadata.JobId) {
        $envType = "AzureAutomation"
    }
    Write-Verbose "Environment detected: $envType"

    # 2) Ensure Az.PowerShell context
    try {
        $ctx = Get-AzContext -ErrorAction Stop
        if (-not $ctx.Account) { throw }
        Write-Output "Already connected to Azure PowerShell as: $($ctx.Account)"
    }
    catch {
        Write-Output "Not connected to Azure PowerShell. Running Connect-AzAccount..."
        if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
            Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        }
        else {
            Connect-AzAccount -ErrorAction Stop | Out-Null
        }
        $ctx = Get-AzContext
        Write-Output "Connected to Azure PowerShell as: $($ctx.Account)"
    }

    # 3) (Optional) adjust for Cloud Shell
    if ($envType -eq 'CloudShell') {
        Write-Verbose "Switching to clouddrive"
        Set-Location "$HOME\clouddrive"
    }

    # 4) Sync Azure CLI if available
    if (Get-Command az -ErrorAction SilentlyContinue) {
        try {
            $acct = az account show --output json | ConvertFrom-Json
            Write-Output "Azure CLI logged in as: $($acct.user.name)"
        }
        catch {
            Write-Output "Azure CLI not logged in. Running az login..."
            if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
                az login --identity | Out-Null
            }
            else {
                az login | Out-Null
            }
        }
    }
}

    function LoadAzModules {
        param(
            [Parameter(Mandatory)][string]$SubscriptionId,
            [Parameter(Mandatory)][string]$ResourceGroupName,
            [Parameter(Mandatory)][string]$AutomationAccountName
        )
        
        
        # List of modules to import from PSGallery
        $modules = @(
            'AzureAD',
            'Az.Accounts',
            'Az.ConnectedMachine',
            'Az.ResourceGraph'
        )
        try {
            $existing = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName -Name $mod -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Output "Removing existing Automation module '$mod'..."
                Remove-AzAutomationModule -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName -Name $mod -Force
                    Write-Output "  → Removed '$mod'."
            }
        }
        catch {
            Write-Warning "Could not check/remove existing module '$mod': $_"
        }

        foreach ($mod in $modules) {
            # Remove existing module from Automation account, if present
            try {
                $existing = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName -Name $mod -ErrorAction SilentlyContinue
                if ($existing) {
                    Write-Output "Removing existing Automation module '$mod'..."
                    Remove-AzAutomationModule -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $AutomationAccountName -Name $mod -Force -ErrorAction SilentlyContinue
                        Write-Output "  → Removed '$mod'."
                }
            }
            catch {
                Write-Warning "Could not check/remove existing module '$mod': $_"
            }
            Write-Output "Resolving latest version for module '$mod' from PowerShell Gallery..."
            try {
                $info = Find-Module -Name $mod -Repository PSGallery -ErrorAction Stop
                $version = $info.Version.ToString()
                $contentUri = "https://www.powershellgallery.com/api/v2/package/$mod/$version"
                Write-Output "Importing '$mod' version $version into Automation account..." 
                Import-AzAutomationModule `
                    -ResourceGroupName     $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -Name                  $mod `
                    -ContentLinkUri        $contentUri `
                    -RuntimeVersion    5.1 `
                    -ErrorAction Stop | Out-Null
                    
                    Import-AzAutomationModule `
                    -ResourceGroupName     $ResourceGroupName `
                    -AutomationAccountName $AutomationAccountName `
                    -Name                  $mod `
                    -ContentLinkUri        $contentUri `
                    -RuntimeVersion    7.2 `
                    -ErrorAction Stop | Out-Null
        
                Write-Output "  → Queued '$mod' v$version for import." 
            }
            catch {
                Write-Error "Failed to import module '$mod': $_"
            }
        }
        
        Write-Output "All specified modules have been queued for import. Check the Automation account in the portal for status." 
        }
# Connect to Azure.
Write-Output "Connecting to Azure..."
Connect-Azure
$context = Get-AzContext -ErrorAction Stop
if ($null -ne $targetSubscription -and $targetSubscription -ne $context.Subscription.Id -and $targetSubscription -ne "") {
    $context = Set-AzContext -Subscription  $targetSubscription -ErrorAction Stop
}

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
if (-not (Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name 'Az.ResourceGraph' -ErrorAction SilentlyContinue)) {
    Import-AzAutomationModule `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name 'Az.ResourceGraph' `
    -ContentLinkUri "https://www.powershellgallery.com/packages/Az.ResourceGraph/1.2.0"
    
}
LoadAzModules -SubscriptionId $context.Subscription.Id -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName
# Assign roles to the Automation Account's system-assigned managed identity.
$principalId = $automationAccount.Identity.PrincipalId
$Scope = "/subscriptions/$($context.Subscription.Id)"
Write-Output $principalId 
if ($null -eq $principalId) {
    Write-Output "The Automation Account does not have a system-assigned managed identity enabled."
    exit
} else {
    Write-Output "Automation Account Object ID (PrincipalId): $principalId"
    foreach ($assignment in $roleAssignments) {
        $roleName = $assignment.RoleName
        
        try {
            if($null -eq (Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $roleName  -Scope $Scope)) {
                Write-Output "Assigning role '$roleName' to Managed Identity '$AutomationAccountName' at scope '$Scope'..." -ForegroundColor Yellow
                New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $roleName -Scope "/subscriptions/$($context.Subscription.Id)"   -ErrorAction Stop  | Out-Null
                Write-Output "Role '$roleName' assigned successfully." -ForegroundColor Green
                continue
            }
            
        }
        catch {
            Write-Error "Failed to assign role '$roleName': $_"
        }
    }
}
$downloadFolder = './PayTransitionDownloads/'
# Import the runbook into the Automation Account.
if ((Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -ErrorAction SilentlyContinue)) {
    Write-Output "Removing old Runbook '$RunbookName' from Automation Account '$AutomationAccountName'..."
    Remove-AzAutomationRunbook -AutomationAccountName $AutomationAccountName -Name $RunbookName -ResourceGroupName $ResourceGroupName -Force -ErrorAction SilentlyContinue | Out-Null
}
if (-not (Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -ErrorAction SilentlyContinue)) {
    Write-Output "Importing Runbook '$RunbookName' from file '$RunbookPath' into Automation Account '$AutomationAccountName'..."
    Import-AzAutomationRunbook -AutomationAccountName $AutomationAccountName `
        -Name $RunbookName `
        -ResourceGroupName $ResourceGroupName `
        -Path "$($downloadFolder)$($RunbookPath)" `
        -Type $RunbookType `
        -Force `
        -Published `
        -LogProgress $True   | Out-Null
    }


# Create a daily schedule for the runbook (if it doesn't exist).
$ScheduleName = "$($RunbookName)_defaultschedule"
if (-not (Get-AzAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $ScheduleName -ErrorAction SilentlyContinue)) {
    Remove-AzAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $ScheduleName -ErrorAction SilentlyContinue -Force | Out-Null
}
if (-not (Get-AzAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $ScheduleName -ErrorAction SilentlyContinue)) {
    Write-Output "Creating schedule '$ScheduleName'..."
    # Set the schedule to start 5 minutes from now and expire in one year, with daily frequency.
    

    New-AzAutomationSchedule `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -Name $ScheduleName `
        -WeekInterval 1 `
        -DaysOfWeek @($DayOfWeek) `
        -StartTime $Time.AddHours(25)`
        -TimeZone "EST" `
        -Description 'Default schedule for runbook'   | Out-Null
} 

# Link the schedule to the runbook, including the sample parameters.
Write-Output "Assigning schedule '$ScheduleName' to runbook '$RunbookName' with sample parameters..."
Register-AzAutomationScheduledRunbook `
    -AutomationAccountName $AutomationAccountName `
    -ResourceGroupName $ResourceGroupName `
    -RunbookName $RunbookName `
    -ScheduleName $ScheduleName `
    -Parameters $RunbookArg  | Out-Null

Start-AzAutomationRunbook `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name $RunbookName `
    -Parameters $RunbookArg `
    -ErrorAction SilentlyContinue | Out-Null

Write-Output "Runbook '$RunbookName' has been imported and published successfully."
