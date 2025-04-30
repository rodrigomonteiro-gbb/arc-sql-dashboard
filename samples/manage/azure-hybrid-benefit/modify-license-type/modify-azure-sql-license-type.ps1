<#
.SYNOPSIS
    Updates the license type for Azure SQL resources (SQL DBs, Elastic Pools, Managed Instances, Instance Pools, SQL VMs)
    to a specified model ("LicenseIncluded" or "BasePrice"). Optionally starts resources if needed.

.DESCRIPTION
    The script updates Azure SQL License types across subscriptions by modifying the license settings for a variety of SQL resources. It supports processing resources in one of the following ways:

Single Subscription:
Run against a specified subscription ID.
CSV List of Subscriptions:
Process multiple subscriptions provided in a CSV file.
All Accessible Subscriptions:
Automatically detect and update all subscriptions that you have access to.
For specific resource types like SQL Virtual Machines and SQL Managed Instances, the script can optionally start the resource if it is in a stopped state (when the -Force_Start_On_Resources parameter is enabled) before applying the license update.

The script processes several types of Azure SQL resources including:

SQL Virtual Machines (SQL VMs)
SQL Managed Instances
SQL Databases
Elastic Pools
SQL Instance Pools
DataFactory SSIS Integration Runtimes
This automation helps ensure that your licensing configuration is consistent across your environment without manual intervention.

.VERSION
    1.0.0 - Initial version.

.PARAMETER SubId
    A single subscription ID or a CSV file name containing a list of subscriptions.

.PARAMETER ResourceGroup
    Optional. Limit the scope to a specific resource group.

.PARAMETER LicenseType
    Optional. License type to set. Allowed values: "LicenseIncluded" (default) or "BasePrice".

.PARAMETER Force_Start_On_Resources
    Optional. If true, starts SQL VMs and SQL Managed Instances before updating their license type.
#>

param (
    [Parameter(Mandatory = $false)]
    [string] $SubId,
    
    [Parameter(Mandatory = $false)]
    [string] $ResourceGroup,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("LicenseIncluded", "BasePrice", IgnoreCase = $false)]
    [string] $LicenseType = "LicenseIncluded",
    
    [Parameter(Mandatory = $false)]
    [switch] $Force_Start_On_Resources
)

# Suppress unnecessary logging output
$VerbosePreference      = "SilentlyContinue"
$DebugPreference        = "SilentlyContinue"
$ProgressPreference     = "SilentlyContinue"
$InformationPreference  = "SilentlyContinue"
$WarningPreference      = "SilentlyContinue"
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
        $UseManagedIdentity=$true
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

    # 3) Sync Azure CLI if available
    if (Get-Command az -ErrorAction SilentlyContinue) {
        try {
            Write-Output "Check if az CLI is loged on..."
            $acct = az account show --output json | ConvertFrom-Json
            Write-Output "az: $($acct)"
            if($null -eq $acct)
            {
                Write-Output "Azure CLI not logged in. Running az login..."
                if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
                    az login --identity | Out-Null
                }
                else {
                    az login | Out-Null
                }
                $acct = az account show --output json | ConvertFrom-Json
            }
        }
        catch {
            Write-Output "Azure CLI not logged in. Running az login..."
            if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
                az login --identity | Out-Null
            }
            else {
                az login | Out-Null
            }
            $acct = az account show --output json | ConvertFrom-Json
        }
    }
    Write-Output "Azure CLI logged in as: $($acct.user.name)"        

}


# Initialize final status and report counters.
$finalStatus = @()
$report = @{
    "SQLVMUpdated"        = @()
    "SQLMIUpdated"        = @()
    "SQLDBUpdated"        = @()
    "ElasticPoolUpdated"  = @()
    "InstancePoolUpdated" = @()
    "ADFSSISUpdated" = @()
}

# Ensure connection with both PowerShell and CLI.
Connect-Azure
$context = Get-AzContext -ErrorAction SilentlyContinue
Write-Output "Connected to Azure as: $($context.Account)"

# Map License Types for SQL VMs: LicenseIncluded -> PAYG, BasePrice -> AHUB.
$SqlVmLicenseType = if ($LicenseType -eq "LicenseIncluded") { "PAYG" } else { "AHUB" }

# Determine the subscriptions to process: CSV file, single subscription, or all accessible subscriptions.
try {
    if ($SubId -and $SubId -like "*.csv") {
        Write-Output "Gathering subscriptions from CSV file: $SubId"
        $subscriptions = Import-Csv -Path $SubId
    }
    elseif ($SubId) {
        Write-Output "Gathering subscription details for: $SubId"
        $subscriptions = @(az account show --subscription $SubId --output json | ConvertFrom-Json)
    }
    else {
        Write-Output "Gathering all accessible subscriptions..."
        $subscriptions = az account list --output json | ConvertFrom-Json
    }
}
catch {
    Write-Error "Error determining subscriptions: $_"
    exit 1
}

# Build resource group filter if specified.
$rgFilter = if ($ResourceGroup) { "resourceGroup=='$ResourceGroup'" } else { "" }
$scriptStartTime = Get-Date
Write-Output "Our adventure begins at: $scriptStartTime`n"

# Process each subscription.
foreach ($sub in $subscriptions) {
    try {
        Write-Output "===== Entering Subscription: $($sub.name) ====="
        Write-Output "Switching context to subscription: $($sub.name)"
        az account set --subscription $sub.id

        # --- Section: Update SQL Virtual Machines ---
        try {
            Write-Output "Seeking SQL Virtual Machines that require a license update to $SqlVmLicenseType..."
            $sqlVmQuery = if ($rgFilter) {
                "[?sqlServerLicenseType!='${SqlVmLicenseType}' && $rgFilter]"
            }
            else {
                "[?sqlServerLicenseType!='${SqlVmLicenseType}']"
            }
            Write-Output "Seeking SQL Virtual Machines with filter $sqlVmQuery..."
            $sqlVMs = az sql vm list --query $sqlVmQuery -o json | ConvertFrom-Json
            $sqlVmsToUpdate = [System.Collections.ArrayList]::new()

            foreach ($sqlvm in $sqlVMs) {
                $vmStatus = az vm get-instance-view --resource-group $sqlvm.resourceGroup --name $sqlvm.name --query "{Name:name, ResourceGroup:resourceGroup, PowerState:instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]}" -o json | ConvertFrom-Json
                if ($vmStatus.PowerState -eq "VM running") {
                    Write-Output "Updating SQL VM '$($sqlvm.name)' in RG '$($sqlvm.resourceGroup)' to license type '$SqlVmLicenseType'..."
                    $result = az sql vm update -n $sqlvm.name -g $sqlvm.resourceGroup --license-type $SqlVmLicenseType -o json | ConvertFrom-Json
                    $finalStatus += $result
                    $report["SQLVMUpdated"] += $sqlvm.name
                }
                else {
                    if ($Force_Start_On_Resources) {
                        Write-Output "SQL VM '$($sqlvm.name)' is not running. Forcing start to update license..."
                        az vm start --resource-group $sqlvm.resourceGroup --name $sqlvm.name --no-wait yes
                        $sqlVmsToUpdate.Add($sqlvm) | Out-Null
                    }
                }
            }
        }
        catch {
            Write-Error "An error occurred while updating SQL VMs: $_"
        }

        # --- Section: Update SQL Managed Instances (Stopped then Ready) ---
        $sqlMIsToUpdate = [System.Collections.ArrayList]::new()
        try {
            if ($Force_Start_On_Resources) {
                Write-Output "Seeking SQL Managed Instances that are stopped and require an update to $LicenseType..."
                $miQuery = if ($rgFilter) {
                    "[?licenseType!='${LicenseType}' && state!='Ready' && $rgFilter].{Name:name, State:state, ResourceGroup:resourceGroup}"
                }
                else {
                    "[?licenseType!='${LicenseType}' && state!='Ready'].{Name:name, State:state, ResourceGroup:resourceGroup}"
                }
                Write-Output "Seeking SQL Managed Instances with Filter $miQuery..."
                $offSQLMIs = az sql mi list --query $miQuery -o json | ConvertFrom-Json
                foreach ($mi in $offSQLMIs) {
                    if ($mi.State -eq "Stopped") {
                        Write-Output "Starting SQL Managed Instance '$($mi.Name)' in RG '$($mi.ResourceGroup)'..."
                        az sql mi start --mi $mi.Name -g $mi.ResourceGroup --no-wait yes
                    }
                    $sqlMIsToUpdate.Add($mi) | Out-Null
                }
            }

            Write-Output "Processing SQL Managed Instances that are running to $LicenseType..."
            $miRunningQuery = if ($rgFilter) {
                "[?licenseType!='${LicenseType}' && state=='Ready' && $rgFilter]"
            }
            else {
                "[?licenseType!='${LicenseType}' && state=='Ready']"
            }
            Write-Output "Processing SQL Managed Instances that are running with filter $miRunningQuery..."
            $runningMIs = az sql mi list --query $miRunningQuery -o json | ConvertFrom-Json
            foreach ($mi in $runningMIs) {
                Write-Output "Updating SQL Managed Instance '$($mi.name)' in RG '$($mi.resourceGroup)' to license type '$LicenseType'..."
                $result = az sql mi update --name $mi.name --resource-group $mi.resourceGroup --license-type $LicenseType -o json | ConvertFrom-Json
                $finalStatus += $result
                $report["SQLMIUpdated"] += $mi.name
            }
        }
        catch {
            Write-Error "An error occurred while updating SQL Managed Instances: $_"
        }

        # --- Section: Update SQL Databases and Elastic Pools ---
        try {
            Write-Output "Querying SQL Servers within this subscription..."
            $serverQuery = if ($rgFilter) { "[?$rgFilter]" } else { "[]" }
            $servers = az sql server list --query $serverQuery -o json | ConvertFrom-Json

            foreach ($server in $servers) {
                # Update SQL Databases
                Write-Output "Scanning SQL Databases on server '$($server.name)'..."
                $dbs = az sql db list --resource-group $server.resourceGroup --server $server.name --query "[?licenseType!='$($LicenseType)' && licenseType!=null]" -o json | ConvertFrom-Json
                foreach ($db in $dbs) {
                    Write-Output "Updating SQL Database '$($db.name)' on server '$($server.name)' to license type '$LicenseType'..."
                    $result = az sql db update --name $db.name --server $server.name --resource-group $server.resourceGroup --set licenseType=$LicenseType -o json | ConvertFrom-Json
                    $finalStatus += $result
                    $report["SQLDBUpdated"] += $db.name
                }

                # Update Elastic Pools
                try {
                    Write-Output "Scanning Elastic Pools on server '$($server.name)'..."
                    $elasticPools = az sql elastic-pool list --resource-group $server.resourceGroup --server $server.name --query "[?licenseType!='$($LicenseType)' && licenseType!=null]" --only-show-errors -o json | ConvertFrom-Json
                    foreach ($pool in $elasticPools) {
                        Write-Output "Updating Elastic Pool '$($pool.name)' on server '$($server.name)' to license type '$LicenseType'..."
                        $result = az sql elastic-pool update --name $pool.name --server $server.name --resource-group $server.resourceGroup --set licenseType=$LicenseType --only-show-errors -o json | ConvertFrom-Json -ErrorAction SilentlyContinue
                        $finalStatus += $result
                        $report["ElasticPoolUpdated"] += $pool.name
                    }
                }
                catch {
                    Write-Output "Encountered an issue while updating Elastic Pools on server '$($server.name)'. Continuing..."
                }
            }
        }
        catch {
            Write-Error "An error occurred while processing SQL Databases or Elastic Pools: $_"
        }

        # --- Section: Update SQL Instance Pools ---
        try {
            Write-Output "Searching for SQL Instance Pools that require a license update..."
            $instancePoolsQuery = if ($rgFilter) { "[?$rgFilter]" } else { "[]" }
            $instancePools = az sql instance-pool list --query $instancePoolsQuery -o json | ConvertFrom-Json
            $poolsToUpdate = $instancePools | Where-Object { $_.licenseType -ne $LicenseType }
            foreach ($pool in $poolsToUpdate) {
                Write-Output "Updating SQL Instance Pool '$($pool.name)' in RG '$($pool.resourceGroup)' to license type '$LicenseType'..."
                $result = az sql instance-pool update --name $pool.name --resource-group $pool.resourceGroup --license-type $LicenseType -o json | ConvertFrom-Json
                $finalStatus += $result
                $report["InstancePoolUpdated"] += $pool.name
            }
        }
        catch {
            Write-Error "An error occurred while updating SQL Instance Pools: $_"
        }

        # --- Section: Update DataFactory SSIS Integration Runtimes ---
        try {
            Write-Output "Processing DataFactory SSIS Integration Runtime resources..."
            Get-AzDataFactoryV2 | Where-Object { $_.ProvisioningState -eq "Succeeded" } | ForEach-Object {
                Get-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $_.ResourceGroupName -DataFactoryName $_.DataFactoryName | Where-Object { $_.Type -eq "Managed" -and $_.State -ne "Starting" } | ForEach-Object {
                    if ($_.LicenseType -ne $LicenseType) {
                        # Update the license type to $LicenseType.
                        $result = Set-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $_.ResourceGroupName -DataFactoryName $_.DataFactoryName -Name $_.Name -LicenseType $LicenseType -Force
                        $finalStatus += $result
                        $report["ADFSSISUpdated"] += $_.Name                        
                        Write-Host ([Environment]::NewLine + "-- DataFactory '$($_.DataFactoryName)' integration runtime updated to license type $LicenseType")
                    }
                }
            }
        }
        catch {
            Write-Error "An error occurred while updating DataFactory SSIS Integration Runtimes: $_"
        }

        # --- Section: Finalize SQL VM updates for those that were started on-demand ---
        $sqlvm = ""
        try {
            $updated = $true
            while ($sqlVmsToUpdate.Count -gt 0) {
                $sqlvm = $sqlVmsToUpdate[0]
                $vmStatus = az vm get-instance-view --resource-group $sqlvm.resourceGroup --name $sqlvm.name --query "{PowerState:instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]}" -o json | ConvertFrom-Json
                if ($vmStatus.PowerState -eq "VM running") {
                    Write-Output "Now updating SQL VM '$($sqlvm.name)' after forced start..."
                    $result = az sql vm update -n $sqlvm.name -g $sqlvm.resourceGroup --license-type $SqlVmLicenseType -o json | ConvertFrom-Json
                    $finalStatus += $result
                    $report["SQLVMUpdated"] += $sqlvm.name
                    Write-Output "Deallocating SQL VM '$($sqlvm.name)' post-update..."
                    az vm deallocate --resource-group $sqlvm.resourceGroup --name $sqlvm.name --no-wait yes
                    $sqlVmsToUpdate.RemoveAt(0)
                    $updated = $true
                }
                else {
                    if ($updated) {
                        Write-Host "Waiting for SQL VM '$($sqlvm.name)' to start..."
                        $updated = $false
                    }
                    else {
                        Write-Host "." -NoNewline
                    }
                    Start-Sleep -Seconds 30
                }
            }
        }
        catch {
            Write-Error "An error occurred while finalizing SQL VM updates in subscription '$($sub.name)': $sqlvm"
        }

        # --- Section: Finalize SQL Managed Instance updates for those that were forced-start ---
        $mi = ""
        try {
            $updated = $true
            while ($sqlMIsToUpdate.Count -gt 0) {
                $mi = $sqlMIsToUpdate[0]
                $miStatus = az sql mi show --resource-group $mi.ResourceGroup --name $mi.Name -o json | ConvertFrom-Json
                if ($miStatus.state -eq "Ready") {
                    Write-Output "Updating SQL Managed Instance '$($mi.Name)' after forced start..."
                    $result = az sql mi update --name $mi.Name --resource-group $mi.ResourceGroup --license-type $LicenseType -o json | ConvertFrom-Json
                    $finalStatus += $result
                    $report["SQLMIUpdated"] += $mi.Name
                    Write-Output "Stopping SQL Managed Instance '$($mi.Name)' post-update..."
                    az sql mi stop --resource-group $mi.ResourceGroup --mi $mi.Name --no-wait yes
                    $sqlMIsToUpdate.RemoveAt(0)
                    $updated = $true
                }
                else {
                    if ($updated) {
                        Write-Host "Waiting for SQL Managed Instance '$($mi.Name)' to be ready..."
                        $updated = $false
                    }
                    else {
                        Write-Host "." -NoNewline
                    }
                    Start-Sleep -Seconds 30
                }
            }
        }
        catch {
            Write-Error "An error occurred while finalizing SQL Managed Instance updates in subscription '$($sub.name)': $mi"
        }

    }
    catch {
        Write-Error "An error occurred while processing subscription '$($sub.name)': $_"
    }
}

$scriptEndTime = Get-Date
$totalDuration = $scriptEndTime - $scriptStartTime

# --- Final Report ---
Write-Output "`n===== Final Report ====="
Write-Output "Script started at: $scriptStartTime"
Write-Output "Script ended at:   $scriptEndTime"
Write-Output "Total duration:    $($totalDuration.ToString())"
Write-Output "`nResources updated by category:"

if ($report["SQLVMUpdated"].Count -gt 0) {
    Write-Output "SQL VMs Updated: $($report["SQLVMUpdated"] -join ', ')"
} else {
    Write-Output "SQL VMs Updated: None"
}

if ($report["SQLMIUpdated"].Count -gt 0) {
    Write-Output "SQL Managed Instances Updated: $($report["SQLMIUpdated"] -join ', ')"
} else {
    Write-Output "SQL Managed Instances Updated: None"
}

if ($report["SQLDBUpdated"].Count -gt 0) {
    Write-Output "SQL Databases Updated: $($report["SQLDBUpdated"] -join ', ')"
} else {
    Write-Output "SQL Databases Updated: None"
}

if ($report["ElasticPoolUpdated"].Count -gt 0) {
    Write-Output "Elastic Pools Updated: $($report["ElasticPoolUpdated"] -join ', ')"
} else {
    Write-Output "Elastic Pools Updated: None"
}

if ($report["InstancePoolUpdated"].Count -gt 0) {
    Write-Output "SQL Instance Pools Updated: $($report["InstancePoolUpdated"] -join ', ')"
} else {
    Write-Output "SQL Instance Pools Updated: None"
}

if ($report["ADFSSISUpdated"].Count -gt 0) {
    Write-Output "SQL ADF SSIS: $($report["ADFSSISUpdated"] -join ', ')"
} else {
    Write-Output "SQL ADF SSIS Updated: None"
}