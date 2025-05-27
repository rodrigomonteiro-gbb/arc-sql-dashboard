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

.PARAMETER ExclusionTags
    Optional. If specified, excludes the resources that have this tag assigned.

.PARAMETER TenantId
    Optional. If specified, this tenant id to log in both PoaerShell and CLI. Otyherwise, the current logoin context is used.

.PARAMETER ReportOnly
    Optional. If true, generates a csv file with the list of resources that are to be modified, but doesn't make the actual change.

.PARAMETER UseManagedIdentity
    Optional. If true, logs in both PoaerShell and CLI using managed identity. Required to run the script as a runbook.

#>

param (
    [Parameter(Mandatory = $false)]
    [string] $SubId=$null,
    
    [Parameter(Mandatory = $false)]
    [string] $ResourceGroup=$null,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("LicenseIncluded", "BasePrice", IgnoreCase = $false)]
    [string] $LicenseType = "LicenseIncluded",
    
    [Parameter(Mandatory = $false)]
    [switch] $Force_Start_On_Resources,

    [Parameter (Mandatory= $false)]
    [object] $ExclusionTags,

    [Parameter (Mandatory= $false)]
    [string] $TenantId,

    [Parameter (Mandatory= $false)]
    [switch] $ReportOnly,

    [Parameter (Mandatory= $false)]
    [switch] $UseManagedIdentity,

    [Parameter(Mandatory = $false)]
    [string] $ResourceName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("SQLVM", "SQLMI", "SQLDB", "ElasticPool", "SQLInstancePool", "DataFactory","All", IgnoreCase = $false)]
    [string] $ResourceType = "All"
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
         [Parameter (Mandatory= $true)]
         [string] $TenantId,

         [Parameter (Mandatory= $false)]
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
    Write-Output "Not connected to Azure PowerShell. Running Connect-AzAccount..."
    if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
        if($TenantId -eq $null) {
            $ctx = Connect-AzAccount  -Identity -ErrorAction Stop | Out-Null
        }else{
            Write-Output "Using Managed Identity to connect to Azure PowerShell..."
            $ctx = Connect-AzAccount -Tenant $TenantId -Identity -ErrorAction Stop | Out-Null
        }
        
    }
    else {
        if($TenantId -eq $null) {
            $ctx = Connect-AzAccount -ErrorAction Stop | Out-Null
        }else{
            $ctx = Connect-AzAccount -Tenant $TenantId -ErrorAction Stop | Out-Null
        }
    }
    Write-Output "Connected to Azure PowerShell as: $($ctx.Account)"

    # 3) Sync Azure CLI if available
    if (Get-Command az -ErrorAction SilentlyContinue) {
        Write-Output "Running az login..."
        if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
            if($TenantId -eq $null) {
                az login --identity | Out-Null
            }else{
                Write-Output "Using Managed Identity to connect to Azure CLI..."
                # Use --identity for managed identity
                az login --identity --tenant $TenantId | Out-Null
            }
        }
        else {
            if($TenantId -eq $null) {
                az login | Out-Null
            }else{
                az login --tenant $TenantId | Out-Null
            }
        }
        $acct = az account show --output json | ConvertFrom-Json
    }
    Write-Output "Azure CLI logged in as: $($acct.user.name)"        

}


# Initialize final status and report counters.
$finalStatus = @()

# Convert to hashtable explicitly
$tagTable = @{}
if($null -ne $ExclusionTags){
    if($ExclusionTags.GetType().Name -eq "Hashtable"){
        $tagTable = $ExclusionTags    
    }else{
        ($ExclusionTags | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $tagTable[$_.Name] = $_.Value
        }
    }
}

if (-not $TenantId) {
    $TenantId = $context.Tenant.Id
    Write-Output "No TenantId provided. Using current context TenantId: $TenantId"
} else {
    Write-Output "Using provided TenantId: $TenantId"
}
# Ensure connection with both PowerShell and CLI.
if ($UseManagedIdentity) {
    Connect-Azure ($TenantId, $UseManagedIdentity)
}else{
    Connect-Azure ($TenantId)
}

# Map License Types for SQL VMs: LicenseIncluded -> PAYG, BasePrice -> AHUB.
$SqlVmLicenseType = if ($LicenseType -eq "LicenseIncluded") { "PAYG" } else { "AHUB" }

# Modified resources array
$modifiedResources = @()

# Determine the subscriptions to process: CSV file, single subscription, or all accessible subscriptions.
if ($SubId -like "*.csv") {
    $subscriptions = Import-Csv $SubId
}elseif($SubId -ne "") {
    Write-Output "Passed Subscription $($SubId)"
    $subscriptions = Get-AzSubscription -SubscriptionId $SubId
}else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.TenantId -eq $tenantId }
}

# Build resource group filter if specified.
$rgFilter = if ($ResourceGroup) { "resourceGroup=='$ResourceGroup'" } else { "" }
$scriptStartTime = Get-Date
Write-Output "Our adventure begins at: $scriptStartTime`n"
$tagsFilter = $null
if($tagTable.Keys.Count -gt 0) {
    $tagsFilter += " && "
    $tagcount = $tagTable.Keys.Count
    foreach ($tag in $tagTable.Keys) {
        $tagcount --
        $tagsFilter += " tags.$($tag) != '$($tagTable[$tag])' "
        if($tagcount -gt 0) {
            $tagsFilter += " && "
        }
    }
}
$sqlVMNameFilter = if ($ResourceName -and $ResourceType -eq "SQLVM") { " && name=='$ResourceName'" } else { "" }
$sqlMINameFilter = if ($ResourceName -and $ResourceType -eq "SQLMI") { " && name=='$ResourceName'" } else { "" }
$sqlDBNameFilter = if ($ResourceName -and $ResourceType -eq "SQLDB") { " && name=='$ResourceName'" } else { "" }
$elasticPoolNameFilter = if ($ResourceName -and $ResourceType -eq "ElasticPool") { " && name=='$ResourceName'" } else { "" } 
$sqlInstancePoolNameFilter = if ($ResourceName -and $ResourceType -eq "SQLInstancePool") { " && name=='$ResourceName'" } else { "" }

# Process each subscription.
foreach ($sub in $subscriptions) {
    try {
        Write-Output "===== Entering Subscription: $($sub.name) ====="
        Write-Output "Switching context to subscription: $($sub.name)"


        Write-Output "License Type: $LicenseType"
        az account set --subscription $sub.id

        # --- Section: Update SQL Virtual Machines ---
        if($ResourceType -eq "SQLVM" -or $ResourceType -eq "All") {
            Write-Output "Processing SQL Virtual Machines..."
        
            try {
                Write-Output "Seeking SQL Virtual Machines that require a license update to $SqlVmLicenseType..."
                $sqlVmQuery = if ($rgFilter) {
                    "[?sqlServerLicenseType!='${SqlVmLicenseType}' && sqlServerLicenseType!= 'DR' && $rgFilter $tagsFilter $sqlVMNameFilter]"
                } else {
                    "[?sqlServerLicenseType!='${SqlVmLicenseType}' && sqlServerLicenseType!= 'DR' $tagsFilter $sqlVMNameFilter]"
                }


                Write-Output "Seeking SQL Virtual Machines with filter $sqlVmQuery..."
                $sqlVMs = az sql vm list --query $sqlVmQuery -o json | ConvertFrom-Json
                $sqlVmsToUpdate = [System.Collections.ArrayList]::new()
                if($sqlVMs.Count -eq 0) {
                    Write-Output "No SQL VMs found that require a license update."
                } else {
                    Write-Output "Found $($sqlVMs.Count) SQL VMs that require a license update."
                }
                foreach ($sqlvm in $sqlVMs) {

                    if($null -ne (az vm list --query "[?name=='$sqlvm.name' && resourceGroup=='$sqlvm.resourceGroup' $tagsFilter]"))
                    {
                        $vmStatus = az vm get-instance-view --resource-group $sqlvm.resourceGroup --name $sqlvm.name --query "{Name:name, ResourceGroup:resourceGroup, PowerState:instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]}" -o json | ConvertFrom-Json
                        if ($vmStatus.PowerState -eq "VM running") {
                            
                            # Collect data before modification
                            $modifiedResources += [PSCustomObject]@{
                                TenantID            = $TenantId
                                SubID               = $sqlvm.SubscriptionId
                                ResourceName        = $sqlvm.name
                                ResourceType        = $sqlvm.ResourceType
                                Status              = $sqlvm.Status
                                OriginalLicenseType = $sqlvm.licenseType
                                ResourceGroup       = $sqlvm.resourceGroup
                                Location            = $sqlvm.Location
                                # Cores             <To be added>
                            }

            
                            if (-not $ReportOnly) {
                                Write-Output "Updating SQL VM '$($sqlvm.name)' in RG '$($sqlvm.resourceGroup)' to license type '$SqlVmLicenseType'..."
                                $result = az sql vm update -n $sqlvm.name -g $sqlvm.resourceGroup --license-type $SqlVmLicenseType -o json | ConvertFrom-Json
                                $finalStatus += $result
                            }
                        }
                        else {
                            if ($Force_Start_On_Resources -and -not $ReportOnly) {                           
                                Write-Output "SQL VM '$($sqlvm.name)' is not running. Forcing start to update license..."
                                az vm start --resource-group $sqlvm.resourceGroup --name $sqlvm.name --no-wait yes 
                                $sqlVmsToUpdate.Add($sqlvm) | Out-Null
                            }
                        }
                    }
                    else {
                        Write-Output "SQL VM '$($sqlvm.name)' in RG '$($sqlvm.resourceGroup)' Skipping because of tags ($tags)..."
                    }
                }
                if($sqlVmsToUpdate.Count -eq 0) {
                    Write-Output "No SQL VMs found to start that require a license update."
                } else {
                    Write-Output "Found $($sqlVmsToUpdate.Count) to Start SQL VMs that require a license update."
                }
            }
            catch {
                Write-Error "An error occurred while updating SQL VMs: $_"
            }
        } else {
            Write-Output "Skipping SQL Virtual Machines update as ResourceType is set to $ResourceType"
        }
        # --- Section: Update SQL Managed Instances (Stopped then Ready) "hybridSecondaryUsage": "Passive"---
        $sqlMIsToUpdate = [System.Collections.ArrayList]::new()
        if($ResourceType -eq "SQLMI" -or $ResourceType -eq "All") {
            Write-Output "Processing SQL Managed Instances..."
        
            try {
                if ($Force_Start_On_Resources) {
                    Write-Output "Seeking SQL Managed Instances that are stopped and require an update to $LicenseType..."
                    $miQuery = if ($rgFilter) {
                        "[?licenseType!='${LicenseType}' && hybridSecondaryUsage!='Passive' && state!='Ready' && $rgFilter $tagsFilter $sqlMINameFilter].{Name:name, State:state, ResourceGroup:resourceGroup}"
                    } else {
                        "[?licenseType!='${LicenseType}' && hybridSecondaryUsage!='Passive' && state!='Ready' $tagsFilter $sqlMINameFilter].{Name:name, State:state, ResourceGroup:resourceGroup}"
                    }
                    Write-Output "Seeking SQL Managed Instances with Filter $miQuery..."
                    $offSQLMIs = az sql mi list --query $miQuery -o json | ConvertFrom-Json
                    if( $offSQLMIs.Count -eq 0) {
                        Write-Output "No SQL Managed Instances found to Start that require a license update."
                    } else {
                        Write-Output "Found $($offSQLMIs.Count) SQL Managed Instances found to Start that require a license update."
                    }
                    foreach ($mi in $offSQLMIs) {
                        if ($mi.State -eq "Stopped" -and -not $ReportOnly) {
                            Write-Output "Starting SQL Managed Instance '$($mi.Name)' in RG '$($mi.ResourceGroup)'..."
                            az sql mi start --mi $mi.Name -g $mi.ResourceGroup --no-wait yes 
                        }
                        $sqlMIsToUpdate.Add($mi) | Out-Null
                    }
                }

                Write-Output "Processing SQL Managed Instances that are running to $LicenseType..."
                $miRunningQuery = if ($rgFilter) {
                    "[?licenseType!='${LicenseType}' && hybridSecondaryUsage!='Passive' && state=='Ready' && $rgFilter $tagsFilter $sqlMINameFilter] "
                } else {
                    "[?licenseType!='${LicenseType}' && hybridSecondaryUsage!='Passive' && state=='Ready' $tagsFilter $sqlMINameFilter]"
                }
                Write-Output "Processing SQL Managed Instances that are running with filter $miRunningQuery..."
                $runningMIs = az sql mi list --query $miRunningQuery -o json | ConvertFrom-Json
                if($runningMIs.Count -eq 0) {
                    Write-Output "No SQL Managed Instances found that require a license update."
                } else {
                    Write-Output "Found $($runningMIs.Count) SQL Managed Instances that require a license update."
                }
                foreach ($mi in $runningMIs) {
                            
                    # Collect data before modification
                    $modifiedResources += [PSCustomObject]@{
                        TenantID            = $TenantId
                        SubID               = $mi.SubscriptionId
                        ResourceName        = $mi.name
                        ResourceType        = $mi.ResourceType
                        Status              = $mi.State
                        OriginalLicenseType = $mi.licenseType
                        ResourceGroup       = $mi.resourceGroup
                        Location            = $mi.location
                    }
                    
                    if (-not $ReportOnly) {
                        Write-Output "Updating SQL Managed Instance '$($mi.name)' in RG '$($mi.resourceGroup)' to license type '$LicenseType'..."
                        $result = az sql mi update --name $mi.name --resource-group $mi.resourceGroup --license-type $LicenseType -o json | ConvertFrom-Json
                        $finalStatus += $result
                    }
                }
            }
            catch {
                Write-Error "An error occurred while updating SQL Managed Instances: $_"
            }
        } else {
            Write-Output "Skipping SQL Managed Instances update as ResourceType is set to $ResourceType"
        }

        # --- Section: Update SQL Databases and Elastic Pools ---
        if($ResourceType -eq "SQLDB" -or $ResourceType -eq "ElasticPool" -or $ResourceType -eq "All") {
            Write-Output "Processing SQL Databases and Elastic Pools..."
        
            try {
                Write-Output "Querying SQL Servers within this subscription..."
                $serverQuery = if ($rgFilter) { "[?$rgFilter $elasticPoolNameFilter]" } else { "[$elasticPoolNameFilter.Replace(""&& "",""?"")]" }
                $servers = az sql server list --query $serverQuery -o json | ConvertFrom-Json

                foreach ($server in $servers) {
                    # Update SQL Databases
                    Write-Output "Scanning SQL Databases on server '$($server.name)'..."
                    $dbs = az sql db list --resource-group $server.resourceGroup --server $server.name --query "[?licenseType!='$($LicenseType)' && licenseType!=null  $tagsFilter]" -o json | ConvertFrom-Json
                    if( $dbs.Count -eq 0) {
                        Write-Output "No SQL Databases found on Server $($server.name) that require a license update."
                    } else {
                        Write-Output "Found $($dbs.Count) SQL Databases on Server $($server.name) that require a license update."
                    }
                    foreach ($db in $dbs) {
                        
                        # Collect data before modification
                        $modifiedResources += [PSCustomObject]@{
                            TenantID            = $TenantId
                            SubID               = $db.SubscriptionId
                            ResourceName        = $db.name
                            ResourceType        = $db.ResourceType
                            Status              = $db.State
                            OriginalLicenseType = $db.licenseType
                            ResourceGroup       = $db.resourceGroup
                            Location            = $db.location
                        }
                        
                        if (-not $ReportOnly) {
                            Write-Output "Updating SQL Database '$($db.name)' on server '$($server.name)' to license type '$LicenseType'..."
                            $result = az sql db update --name $db.name --server $server.name --resource-group $server.resourceGroup --set licenseType=$LicenseType -o json | ConvertFrom-Json
                            $finalStatus += $result
                        }
                    }

                    # Update Elastic Pools
                    if($ResourceType -eq "ElasticPool" -or $ResourceType -eq "All") {
                        Write-Output "Processing Elastic Pools on server '$($server.name)'..."
                        try {
                            Write-Output "Scanning Elastic Pools on server '$($server.name)'..."
                            $elasticPools = az sql elastic-pool list --resource-group $server.resourceGroup --server $server.name --query "[?licenseType!='$($LicenseType)' && licenseType!=null  $tagsFilter $elasticPoolNameFilter]" --only-show-errors -o json | ConvertFrom-Json
                            if( $elasticPools.Count -eq 0) {
                                Write-Output "No Elastic Pools found on Server $($server.name) that require a license update."
                            } else {
                                Write-Output "Found $($elasticPools.Count) Elastic Pools on Server $($server.name) that require a license update."
                            }
                            foreach ($pool in $elasticPools) {
                                                
                                # Collect data before modification
                                $modifiedResources += [PSCustomObject]@{
                                    TenantID            = $TenantId
                                    SubID               = $pool.SubscriptionId
                                    ResourceName        = $pool.name
                                    ResourceType        = $pool.ResoureType
                                    Status              = $pool.State
                                    OriginalLicenseType = $pool.licenseType
                                    ResourceGroup       = $pool.resourceGroup
                                    Location            = $pool.location
                                }
                                
                                if (-not $ReportOnly) {
                                    Write-Output "Updating Elastic Pool '$($pool.name)' on server '$($server.name)' to license type '$LicenseType'..."
                                    $result = az sql elastic-pool update --name $pool.name --server $server.name --resource-group $server.resourceGroup --set licenseType=$LicenseType --only-show-errors -o json | ConvertFrom-Json -ErrorAction SilentlyContinue
                                    $finalStatus += $result
                                    $report["ElasticPoolUpdated"] += $pool.name
                                }
                            }
                        }
                        catch {
                            Write-Output "Encountered an issue while updating Elastic Pools on server '$($server.name)'. Continuing..."
                        }

                }else {
                    Write-Output "Skipping Elastic Pools update as ResourceType is set to $ResourceType"
                }
            }
            catch {
                Write-Error "An error occurred while processing SQL Databases or Elastic Pools: $_"
            }
        } else {
            Write-Output "Skipping SQL Databases and Elastic Pools update as ResourceType is set to $ResourceType"
        }

        # --- Section: Update SQL Instance Pools ---
        if($ResourceType -eq "SQLInstancePool" -or $ResourceType -eq "All") {
            Write-Output "Processing SQL Instance Pools..."
            try {
                Write-Output "Searching for SQL Instance Pools that require a license update..."
                $instancePoolsQuery = if ($rgFilter) { "[?licenseType!='${LicenseType}' && $rgFilter $tagsFilter]" } else { "[?licenseType!='${LicenseType}' $tagsFilter $sqlMIInstanceNameFilter]" }
                $instancePools = az sql instance-pool list --query $instancePoolsQuery -o json | ConvertFrom-Json
                $poolsToUpdate = $instancePools | Where-Object { $_.licenseType -ne $LicenseType }
                if($poolsToUpdate.Count -eq 0) {
                    Write-Output "No SQL Instance Pools found that require a license update."
                } else {
                    Write-Output "Found $($poolsToUpdate.Count) SQL Instance Pools that require a license update."
                }
                foreach ($pool in $poolsToUpdate) {
                    
                    # Collect data before modification
                    $modifiedResources += [PSCustomObject]@{
                        TenantID            = $TenantId
                        SubID               = $pool.SubscriptionId
                        ResourceName        = $pool.name
                        ResourceType        = $pool.ResoureType
                        Status              = $pool.State
                        OriginalLicenseType = $pool.licenseType
                        ResourceGroup       = $pool.resourceGroup
                        Location            = $pool.location
                    }
                    if (-not $ReportOnly) {
                        Write-Output "Updating SQL Instance Pool '$($pool.name)' in RG '$($pool.resourceGroup)' to license type '$LicenseType'..."
                        $result = az sql instance-pool update --name $pool.name --resource-group $pool.resourceGroup --license-type $LicenseType -o json | ConvertFrom-Json
                        $finalStatus += $result
                    }
                }
            }
            catch {
                Write-Error "An error occurred while updating SQL Instance Pools: $_"
            }
        } else {
            Write-Output "Skipping SQL Instance Pools update as ResourceType is set to $ResourceType"
        }
        # --- Section: Update DataFactory SSIS Integration Runtimes ---
        if($ResourceType -eq "DataFactory" -or $ResourceType -eq "All") {
            Write-Output "Processing DataFactory SSIS Integration Runtimes..."
        
            try {
                Write-Output "Processing DataFactory SSIS Integration Runtime resources..."
                Get-AzDataFactoryV2 | Where-Object { $_.ProvisioningState -eq "Succeeded" } | ForEach-Object {
                    Get-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $_.ResourceGroupName -DataFactoryName $_.DataFactoryName | Where-Object { $_.Type -eq "Managed" -and $_.State -ne "Starting" } | ForEach-Object {
                        if ($_.LicenseType -ne $LicenseType) {
                            # Collect data before modification
                            $modifiedResources += [PSCustomObject]@{
                                TenantID            = $TenantId
                                SubID               = $_.SubscriptionId
                                ResourceName        = $_.Name
                                ResourceType        = $_.ResoureType
                                Status              = $_.State
                                OriginalLicenseType = $_.LicenseType
                                ResourceGroup       = $_.ResourceGroupName
                                Location            = $_.Location
                            }
                            # Update the license type to $LicenseType.
                            if (-not $ReportOnly) {
                                if($ResourceName -eq $_.Name -and $ResourceType -eq "DataFactory") {    
                                    Write-Output "Updating DataFactory '$($_.DataFactoryName)' integration runtime '$($_.Name)' to license type $LicenseType..."
                                    $result = Set-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $_.ResourceGroupName -DataFactoryName $_.DataFactoryName -Name $_.Name -LicenseType $LicenseType -Force
                                    $finalStatus += $result
                                } else {
                                    Write-Output "Updating DataFactory '$($_.DataFactoryName)' integration runtime '$($_.Name)' to license type $LicenseType..."
                                    $result = Set-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $_.ResourceGroupName -DataFactoryName $_.DataFactoryName -Name $_.Name -LicenseType $LicenseType -Force
                                    $finalStatus += $result
                                    Write-Host ([Environment]::NewLine + "-- DataFactory '$($_.DataFactoryName)' integration runtime updated to license type $LicenseType")
                                }
                            }
                        }
                    }
                }
            }
            catch {
                Write-Error "An error occurred while updating DataFactory SSIS Integration Runtimes: $_"
            }
        } else {
            Write-Output "Skipping DataFactory SSIS Integration Runtimes update as ResourceType is set to $ResourceType"
        }
        # --- Section: Finalize SQL VM updates for those that were started on-demand ---
        $sqlvm = ""
        if($ResourceType -eq "SQLVM" -or $ResourceType -eq "All") {
            Write-Output "Finalizing SQL VM updates..."
        
            try {
                $updated = $true
                while ($sqlVmsToUpdate.Count -gt 0) {
                    $sqlvm = $sqlVmsToUpdate[0]
                    $vmStatus = az vm get-instance-view --resource-group $sqlvm.resourceGroup --name $sqlvm.name --query "{PowerState:instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]}" -o json | ConvertFrom-Json
                    if ($vmStatus.PowerState -eq "VM running") {
                        # Collect data before modification
                        $modifiedResources += [PSCustomObject]@{
                            TenantID            = $TenantId
                            SubID               = $sqlvm.SubscriptionId
                            ResourceName        = $sqlvm.name
                            ResourceType        = $sqlvm.ResourceType
                            Status              = $sqlvm.State
                            OriginalLicenseType = $sqlvm.licenseType
                            ResourceGroup       = $sqlvm.resourceGroup
                            Location            = $sqlvm.Location
                            # Cores             <To be added>
                        }
                        if (-not $ReportOnly) {
                            Write-Output "Now updating SQL VM '$($sqlvm.name)' after forced start..."
                            $result = az sql vm update -n $sqlvm.name -g $sqlvm.resourceGroup --license-type $SqlVmLicenseType -o json | ConvertFrom-Json
                            $finalStatus += $result
                            Write-Output "Deallocating SQL VM '$($sqlvm.name)' post-update..."
                            az vm deallocate --resource-group $sqlvm.resourceGroup --name $sqlvm.name --no-wait yes 
                            $sqlVmsToUpdate.RemoveAt(0)
                            $updated = $true
                        }
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
        }
        else {
            Write-Output "Skipping SQL VM updates as ResourceType is set to $ResourceType"
        }
        # --- Section: Finalize SQL Managed Instance updates for those that were forced-start ---
        $mi = ""
        if($ResourceType -eq "SQLMI" -or $ResourceType -eq "All") {
            Write-Output "Finalizing SQL Managed Instance updates..."
            try {
                $updated = $true
                while ($sqlMIsToUpdate.Count -gt 0) {
                    $mi = $sqlMIsToUpdate[0]
                    $miStatus = az sql mi show --resource-group $mi.ResourceGroup --name $mi.Name -o json | ConvertFrom-Json
                    if ($miStatus.state -eq "Ready") {
                        # Collect data before modification
                        $modifiedResources += [PSCustomObject]@{
                            TenantID            = $TenantId
                            SubID               = $mi.SubscriptionId
                            ResourceName        = $mi.name
                            ResourceType        = $mi.ResourceType
                            Status              = $mi.State
                            OriginalLicenseType = $mi.licenseType
                            ResourceGroup       = $mi.resourceGroup
                            Location            = $mi.location
                        }                     
                        if (-not $ReportOnly) {
                            Write-Output "Updating SQL Managed Instance '$($mi.Name)' after forced start..."
                            $result = az sql mi update --name $mi.Name --resource-group $mi.ResourceGroup --license-type $LicenseType -o json | ConvertFrom-Json
                            $finalStatus += $result
                            Write-Output "Stopping SQL Managed Instance '$($mi.Name)' post-update..."
                            az sql mi stop --resource-group $mi.ResourceGroup --mi $mi.Name --no-wait yes 
                            $sqlMIsToUpdate.RemoveAt(0)
                            $updated = $true
                        }
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
        else {
            Write-Output "Skipping SQL Managed Instance updates as ResourceType is set to $ResourceType"
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

# Export modified resource data to CSV
if ($modifiedResources.Count -gt 0) {
    $csvPath = "ModifiedResources_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $modifiedResources | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Output "CSV report saved to: $csvPath"
} else {
    Write-Output "No resources were marked for modification. No CSV generated."
}

write-Output "Azure SQL Update Script completed"    