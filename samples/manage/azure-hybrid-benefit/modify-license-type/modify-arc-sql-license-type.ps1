#
# This script provides a scaleable solution to set or change the license type and/or enable or disable the ESU policy 
# on all Azure-connected SQL Servers in a specified scope.
#
# You can specfy a single subscription to scan, or provide subscriptions as a .CSV file with the list of IDs.
# If not specified, all subscriptions your role has access to are scanned.
#
# The script accepts the following command line parameters:
#.
# -SubId [subscription_id] | [csv_file_name]    (Optional. Limits the scope to specific subscriptions. Accepts a .csv file with the list of subscriptions.
#                                               If not specified all subscriptions will be scanned)
# -ResourceGroup [resource_goup]                (Optional. Limits the scope to a specific resoure group)
# -MachineName [machine_name]                   (Optional. Limits the scope to a specific machine)
# -LicenseType [license_type_value]             (Optional. Sets the license type to the specified value)
# -UsePcoreLicense  [Yes or No]                 (Optional. Enables unlimited virtualization license if the value is "Yes" or disables it if the value is "No"
#                                               To enable, the license type must be "Paid" or "PAYG"
# -EnableESU  [Yes or No]                       (Optional. Enables the ESU policy if the value is "Yes" or disables it if the value is "No"
#                                               To enable, the license type must be "Paid" or "PAYG"
# -Force                                        (Optional. Forces the chnahge of the license type to the specified value on all installed extensions.
#                                               If Force is not specified, the -LicenseType value is set only if undefined. Ignored if -LicenseType  is not specified
#
# This script uses a function ConvertTo-HashTable that was created by Adam Bertram (@adam-bertram).
# The function was originally published on https://4sysops.com/archives/convert-json-to-a-powershell-hash-table/
# and is used here with the author's permission.
#

param (
    [Parameter (Mandatory=$false)]
    [string] $SubId,
    [Parameter (Mandatory= $false)]
    [string] $ResourceGroup,
    [Parameter (Mandatory= $false)]
    [string] $MachineName,
    [Parameter (Mandatory= $false)]
    [ValidateSet("PAYG","Paid","LicenseOnly", IgnoreCase=$false)]
    [string] $LicenseType,
    [Parameter (Mandatory= $false)]
    [ValidateSet("Yes","No", IgnoreCase=$false)]
    [string] $UsePcoreLicense,
    [Parameter (Mandatory= $false)]
    [ValidateSet("Yes","No", IgnoreCase=$false)]
    [string] $EnableESU,
    [Parameter (Mandatory= $false)]
    [switch] $Force
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


# Ensure connection with both PowerShell and CLI.
Connect-Azure
$context = Get-AzContext -ErrorAction SilentlyContinue
Write-Output "Connected to Azure as: $($context.Account)"


try{
    Import-Module AzureAD -UseWindowsPowerShell
}
catch{
    Write-Output "Can't import module AzureAD"
}
try{
    Import-Module Az.Accounts
}catch{
    Write-Output "Can't import module Az.Accounts"
}
try{
    Import-Module Az.ConnectedMachine
}
catch{
    Write-Output "Can't import module Az.ConnectedMachine"
}
try{
    Import-Module Az.ResourceGraph
}
catch{
    Write-Output "Can't import module Az.ResourceGraph"
}

$tenantID = $context.Tenant.id

if ($SubId -like "*.csv") {
    $subscriptions = Import-Csv $SubId
}elseif($SubId -ne "") {
    Write-Output "Passed Subscription $($SubId)"
    $subscriptions = [PSCustomObject]@{SubscriptionId = $SubId} | Get-AzSubscription -TenantID $tenantID
}else {
    $subscriptions = Get-AzSubscription -TenantID $tenantID
}

Write-Host ([Environment]::NewLine + "-- Scanning subscriptions --")

foreach ($sub in $subscriptions) {
    if ($sub.State -ne "Enabled") {continue}

    try {
        Set-AzContext -SubscriptionId $sub.Id -Tenant $tenantID
    }catch {
        write-host "Invalid subscription: $($sub.Id)"
        {continue}
    }

    # Consent tag enforcement on the CSP subscriptions
    if ($LicenseType -eq "PAYG") {
        $offers = @("MS-AZR-0145P", "MS-AZR-DE-0145P", "MS-AZR-0017G", "MS-AZR-159P", "MS-AZR-USGOV-0145P")
        $subscriptionOffers = Get-AzSubscription -SubscriptionId $sub.Id | Select-Object -ExpandProperty OfferId -ErrorAction SilentlyContinue
        if ($subscriptionOffers -contains $offers) {
            if ($tags.Tags.ContainsKey("SQLPerpetualPaygBilling")) {
                if ($tags.Tags["SQLPerpetualPaygBilling"] -ne "Enabled") {
                    write-host "Error: Subscription $($sub.Id) has an incorrect value $($tags.Tags["SQLPerpetualPaygBilling"]) of the consent tag 'SQLPerpetualPaygBilling' ."
                    continue
                }
            } else {
                write-host "Error: Subscription $($sub.Id) does not have the consent tag 'SQLPerpetualPaygBilling'."
                continue
            }
        }
    }

    Write-Output "Collecting list of resources to update"
    $query = "
    resources
    | where type =~ 'microsoft.hybridcompute/machines/extensions'
    | where subscriptionId =~ '$($sub.Id)'
    | extend extensionPublisher = tostring(properties.publisher), extensionType = tostring(properties.type), provisioningState = tostring(properties.provisioningState)
    | parse id with * '/providers/Microsoft.HybridCompute/machines/' machineName '/extensions/' *
    | where extensionPublisher =~ 'Microsoft.AzureData'
    | where provisioningState =~ 'Succeeded'"
    
    if ($ResourceGroup) {
        $query += "| where resourceGroup =~ '$($ResourceGroup)'"
    }

    if ($MachineName) {
        $query += "| where machineName =~ '$($MachineName)'"
    } 
    
    $query += "
    | project machineName, extensionName = name, resourceGroup, location, subscriptionId, extensionPublisher, extensionType, properties
    "
    $resources = @(Search-AzGraph -Query "$($query)" -First 1000)
    Write-Output "Found $($resources.Count) resource(s) to update"
    $count = 0
    if ($resources.Count -gt 0) {
        $count = $resources.MachineName.Count
    }
    
    while($count -gt 0) {
        $count-=1
        Write-Output "VM-$($count)"
        write-Output "VM - $($resources.MachineName[$count])"
        $setID = @{
            MachineName = $resources.MachineName[$count]
            Name = $resources.extensionName[$count]
            ResourceGroup = $resources.resourceGroup[$count]
            Location = $resources.location[$count]
            SubscriptionId = $resources.subscriptionId[$count]
            Publisher = $resources.extensionPublisher[$count]
            ExtensionType = $resources.extensionType[$count]
        }

        write-Output "VM - $($setID.MachineName)"
        write-Output "   ResourceGroup - $($setID.ResourceGroup)"
        write-Output "   Location - $($setID.Location)"
        write-Output "   SubscriptionId - $($setID.SubscriptionId)"
        write-Output "   ExtensionType - $($setID.ExtensionType)"
        
        
        $WriteSettings = $false
        $settings = @{}
        $settings = $resources.properties[$count].settings | ConvertTo-Json | ConvertFrom-Json
        $ext = Get-AzConnectedMachineExtension -Name $setID.Name -ResourceGroupName $setID.ResourceGroup -MachineName $setID.MachineName
        $LO_Allowed = (!$settings["enableExtendedSecurityUpdates"] -and !$EnableESU) -or  ($EnableESU -eq "No")
        
        
        write-Output "   LicenseType - $($settings.LicenseType)"

        if ($LicenseType) {
            if (($LicenseType -eq "LicenseOnly") -and !$LO_Allowed) {
                write-Output "ESU must be disabled before license type can be set to $($LicenseType)"
            } else {
                if ($ext.Setting["LicenseType"]) {
                    if ($Force) {
                        $ext.Setting["LicenseType"] = $LicenseType
                        $WriteSettings = $true
                    }
                } else {
                    $ext.Setting["LicenseType"] = $LicenseType
                    $WriteSettings = $true
                }
            }
        }
        
        if ($EnableESU) {
            if (($ext.Setting["LicenseType"] -in ("Paid","PAYG")) -or  ($EnableESU -eq "No")) {
                $ext.Setting["enableExtendedSecurityUpdates"] = ($EnableESU -eq "Yes")
                $ext.Setting["esuLastUpdatedTimestamp"] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                $WriteSettings = $true
            } else {
                write-Output "The configured license type does not support ESUs" 
            }
        }
        
        if ($UsePcoreLicense) {
            if (($ext.Setting["LicenseType"] -in ("Paid","PAYG")) -or  ($UsePcoreLicense -eq "No")) {
                $ext.Setting["UsePhysicalCoreLicense"] = @{
                    "IsApplied" = ($UsePcoreLicense -eq "Yes");
                    "LastUpdatedTimestamp" = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                }
                $WriteSettings = $true
            } else {
                write-Output "The configured license type does not support ESUs" 
            }
        }
        write-Output "   Write Settings - $($WriteSettings)"
        If ($WriteSettings) {
            try { 
                $ext | Set-AzConnectedMachineExtension -Name $setID.Name -ResourceGroupName $setID.ResourceGroup -MachineName $setID.MachineName -NoWait -ErrorAction SilentlyContinue | Out-Null
                Write-Output "Updated -- Resource group: [$($setID.ResourceGroup)], Connected machine: [$($setID.MachineName)]"
            } catch {
                write-Output "The request to modify the extension object failed with the following error:"
                {continue}
            }
        }
    }
}
