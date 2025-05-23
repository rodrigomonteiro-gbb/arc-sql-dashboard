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

function ConvertTo-Hashtable {
    [CmdletBinding()]
    [OutputType('hashtable')]
    param (
        [Parameter(ValueFromPipeline)]
        $InputObject
    )
    process {
        if ($null -eq $InputObject) {
            return $null
        }
        if ($InputObject -is [System.Collections.ICollection]) {
            $hash = @{}
            foreach ($property in $InputObject) {
                $hash[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
            }
            $hash
        } else {
            $InputObject
        }
    }
}

function LoadModule {
    param (
        [parameter(Mandatory = $true)][string] $name
    )

    $retVal = $true

    if (!(Get-Module -Name $name)) {
        $retVal = Get-Module -ListAvailable | Where-Object {$_.Name -eq $name}

        if ($retVal) {
            try {
                Import-Module $name -ErrorAction SilentlyContinue
            }
            catch {
                write-host "The request to load module $($name) failed with the following error:"
                write-host $_.Exception.Message                
                $retVal = $false
            }
        } else {
            if (Find-Module -Name $name) {
                Install-Module -Name $name -Force -Verbose -Scope CurrentUser
                try {
                    Import-Module $name -ErrorAction SilentlyContinue
                }
                catch {
                    write-host "The request to load module $($name) failed with the following error:"
                    write-host $_.Exception.Message                
                    $retVal = $false
                }
            } else {
                write-host "Module $($name) not imported, not available and not in online gallery, exiting."
                EXIT 1
            }
        }
    }

    return $retVal
}

Update-AzConfig -DisplayBreakingChangeWarning $false

$requiredModules = @(
    "AzureAD",    
    "Az.Accounts",
    "Az.ConnectedMachine",
    "Az.ResourceGraph"
)
$requiredModules | Foreach-Object {LoadModule $_}

$tenantID = (Get-AzureADTenantDetail).ObjectId

if ($SubId -like "*.csv") {
    $subscriptions = Import-Csv $SubId
}elseif($SubId -ne "") {
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
        $subscriptionOffers = Get-AzSubscription -SubscriptionId $sub.Id | Select-Object -ExpandProperty OfferId
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

    $query = "
    resources
    | where type =~ 'microsoft.hybridcompute/machines/extensions'
    | where subscriptionId =~ '$($sub.Id)'
    | extend extensionPublisher = tostring(properties.publisher), extensionType = tostring(properties.type), provisioningState = tostring(properties.provisioningState)
    | parse id with * '/providers/Microsoft.HybridCompute/machines/' machineName '/extensions/' *
    | where extensionPublisher =~ 'Microsoft.AzureData'
    | where provisioningState =~ 'Succeeded'
    "
    
    if ($ResourceGroup) {
        $query += "| where resourceGroup =~ '$($ResourceGroup)'"
    }

    if ($MachineName) {
        $query += "| where machineName =~ '$($MachineName)'"
    } 
    
    $query += "
    | project machineName, extensionName = name, resourceGroup, location, subscriptionId, extensionPublisher, extensionType, properties
    "

    $resources = Search-AzGraph -Query "$($query)"
    foreach ($r in $resources) {
        $setID = @{
            MachineName = $r.MachineName
            Name = $r.extensionName
            ResourceGroup = $r.resourceGroup
            Location = $r.location
            SubscriptionId = $r.subscriptionId
            Publisher = $r.extensionPublisher
            ExtensionType = $r.extensionType
        }

        $WriteSettings = $false
        $settings = @{}
        $settings = $r.properties.settings | ConvertTo-Json | ConvertFrom-Json | ConvertTo-Hashtable

        $LO_Allowed = (!$settings["enableExtendedSecurityUpdates"] -and !$EnableESU) -or  ($EnableESU -eq "No")
            
        if ($LicenseType) {
            if (($LicenseType -eq "LicenseOnly") -and !$LO_Allowed) {
                write-host "ESU must be disabled before license type can be set to $($LicenseType)"
            } else {
                if ($settings.ContainsKey("LicenseType")) {
                    if ($Force) {
                        $settings["LicenseType"] = $LicenseType
                        $WriteSettings = $true
                    }
                } else {
                    $settings["LicenseType"] = $LicenseType
                    $WriteSettings = $true
                }
            }
        }
        
        if ($EnableESU) {
            if (($settings["LicenseType"] | select-string "Paid","PAYG") -or  ($EnableESU -eq "No")) {
                $settings["enableExtendedSecurityUpdates"] = ($EnableESU -eq "Yes")
                $settings["esuLastUpdatedTimestamp"] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                $WriteSettings = $true
            } else {
                write-host "The configured license type does not support ESUs" 
            }
        }
        
        if ($UsePcoreLicense) {
            if (($settings["LicenseType"] | select-string "Paid","PAYG") -or  ($UsePcoreLicense -eq "No")) {
                $settings["UsePhysicalCoreLicense"] = @{
                    "IsApplied" = ($UsePcoreLicense -eq "Yes");
                    "LastUpdatedTimestamp" = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                }
                $WriteSettings = $true
            } else {
                write-host "The configured license type does not support ESUs" 
            }
        }
        If ($WriteSettings) {
            try { 
                Set-AzConnectedMachineExtension @setID -Settings $settings -NoWait | Out-Null
                Write-Host "Updated -- Resource group: [$($r.resourceGroup)], Connected machine: [$($r.MachineName)]"
            } catch {
                write-host "The request to modify the extension object failed with the following error:"
                write-host $_.Exception.Message
                {continue}
            }
        }
    }
}
