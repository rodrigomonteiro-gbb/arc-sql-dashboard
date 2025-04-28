<#
.SYNOPSIS
    Schedules or executes pay-transition operations for Azure and/or Arc.

.DESCRIPTION
    Depending on parameters, this script can either:
      - **Single** run: Download and invoke Azure and/or Arc pay-transition scripts immediately, then exit (and optionally clean up).
      - **Scheduled** run: Create or update a Windows Scheduled Task to invoke itself daily at a specified time and day.

.PARAMETER Target
    Which environment(s) to process:
      - `Arc`   : Run the Arc pay-transition.
      - `Azure` : Run the Azure pay-transition.
      - `Both`  : Run Arc then Azure in sequence.

.PARAMETER RunMode
    Execution mode:
      - `Single`    : Download & invoke once, then exit.
      - `Scheduled` : Register/update the Scheduled Task and exit.

.PARAMETER cleanDownloads
    Switch. If set (`$true`) in **Single** mode, deletes the temporary download folder when done. Default: `$false`.

.PARAMETER UsePcoreLicense
    For **Arc** only. `"Yes"` or `"No"` to control PCore licensing behavior passed to the Arc runbook. Default: `"No"`.

.PARAMETER targetResourceGroup
    (Optional) Name of the target resource group passed into the downstream runbook scripts.

.PARAMETER targetSubscription
    (Optional) Subscription ID passed into the downstream runbook scripts.

.PARAMETER AutomationAccResourceGroupName
    Name of the **resource group** that contains the Automation Account used for importing/runbook operations. **Required**.

.PARAMETER AutomationAccountName
    Name of the **Automation Account** for importing/publishing the helper runbook. Default: `"aaccAzureArcSQLLicenseType"`.

.PARAMETER Location
    Azure region (e.g. `"EastUS"`) used for the Automation Account and runbook operations. **Required**.

.PARAMETER Time
    (Scheduled mode) Daily run time for the Scheduled Task in `"h:mmtt"` format (e.g. `"8:00AM"`). Default: `"8:00AM"`.

.PARAMETER DayOfWeek
    (Scheduled mode) Day of the week on which the Scheduled Task will run. Default: `Sunday`.

.PARAMETER SQLLicenseType
    (Optional) SQL license type to be set for the Azure and/or Arc resources. Default: `"PAYG"`.
    Valid values:
      - `BasePrice` : Use SA.
      - `LicenseIncluded` : Pay as You Go.
      - `LicenseOnly` : This is customer with no SA only valid for Arc.
.PARAMETER EnableESU
    (Optional) Enable Extended Security Updates (ESU) for Arc SQL Server VMs. Default: `"No"`.
    Valid values:
      - `Yes` : Enable ESU.
      - `No`  : Disable ESU.
    Note: This parameter is only applicable for Arc SQL Server VMs and is ignored for Azure SQL resources.        

.EXAMPLE
    # Single run for both Arc & Azure, then clean up downloads:
    .\schedule-pay-transition.ps1 `
      -Target Both `
      -RunMode Single `
      -cleanDownloads:$true `
      -UsePcoreLicense No `
      -targetSubscription "00000000-0000-0000-0000-000000000000" `
      -targetResourceGroup "MyRG" `
      -AutomationAccResourceGroupName "MyAutoRG" `
      -AutomationAccountName "MyAutoAcct" `
      -Location "EastUS"

.EXAMPLE
    # Schedule daily at 8 AM every Sunday for Azure only:
    .\schedule-pay-transition.ps1 `
      -Target Azure `
      -RunMode Scheduled `
      -AutomationAccResourceGroupName "MyAutoRG" `
      -Location "EastUS" `
      -Time "8:00AM" `
      -DayOfWeek Sunday
#>

param(
    [Parameter(Mandatory, Position=0)]
    [ValidateSet("Arc","Azure","Both")]
    [string]$Target,

    [Parameter(Mandatory, Position=1)]
    [ValidateSet("Single","Scheduled")]
    [string]$RunMode,

    [Parameter(Mandatory = $false, Position=2)]
    [bool]$cleanDownloads=$false,

    [Parameter (Mandatory= $false)]
    [ValidateSet("Yes","No", IgnoreCase=$false)]
    [string] $UsePcoreLicense="No",

    [Parameter(Mandatory=$false)]
    [string]$targetResourceGroup=$null,

    [Parameter(Mandatory=$false)]
    [string]$targetSubscription=$null,

    [Parameter(Mandatory=$false)]
    [string]$AutomationAccResourceGroupName="AutomationAccResourceGroupName",

    [Parameter(Mandatory=$false)]
    [string]$AutomationAccountName="aaccAzureArcSQLLicenseType",

    [Parameter(Mandatory=$true)]
    [string]$Location=$null,

    [Parameter(Mandatory=$false)]
    [string]$Time="8:00AM",
    [Parameter(Mandatory=$false)]
    [System.DayOfWeek] $DayOfWeek=[System.DayOfWeek]::Sunday,

    [Parameter(Mandatory=$false)]
    [ValidateSet("BasePrice","LicenseIncluded","LicenseOnly", IgnoreCase=$false)]
    [string]$SQLLicenseType="PAYG",
    
    [Parameter (Mandatory= $false)]
    [ValidateSet("Yes","No", IgnoreCase=$false)]
    [string] $EnableESU="No"
)
$git = "sql-server-samples"
$environment = "microsoft"
if($null -ne $env:MYAPP_ENV) {
    $git = "arc-sql-dashboard"
    $environment = $env:MYAPP_ENV
}
# === Configuration ===
$scriptUrls = @{
    General = @{
        URL = "https://raw.githubusercontent.com/$($environment)/$($git)/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/set-azurerunbook.ps1"
        Args = @{
            ResourceGroupName= "'$($AutomationAccResourceGroupName)'"
            AutomationAccountName= $AutomationAccountName 
            Location= $Location
            targetResourceGroup= $targetResourceGroup
            targetSubscription= $targetSubscription}
        }
    Azure = @{
        URL = "https://raw.githubusercontent.com/$($environment)/$($git)/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-azure-sql-license-type.ps1"
        Args = @{
            Force_Start_On_Resources = $true
            SubId = [string]$targetSubscription
            ResourceGroup = [string]$targetResourceGroup
            LicenseType= $SQLLicenseType -eq "LicenseOnly" ? "BasePrice" : $SQLLicenseType
        }
    }
    Arc   = @{
        URL = "https://raw.githubusercontent.com/$($environment)/$($git)/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-arc-sql-license-type.ps1"
        Args =@{
            LicenseType= $SQLLicenseType -eq "LicenseIncluded" ? "PAYG" : $SQLLicenseType -eq  "BasePrice" ? "Paid" : $SQLLicenseType
            Force = $true
            UsePcoreLicense=[string]$UsePcoreLicense
            SubId = [string]$targetSubscription
            ResourceGroup = [string]$targetResourceGroup
            EnableESU = $EnableESU
        }
   }
}
# Define a dedicated download folder under TEMP
$downloadFolder = './PayTransitionDownloads/'
# Ensure destination folder exists
if (-not (Test-Path $downloadFolder)) {
    Write-Host "Creating folder: $downloadFolder"
    New-Item -Path $downloadFolder -ItemType Directory -Force | Out-Null
}
# Helper to download a script and invoke it
function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [ValidateSet("Arc","Azure","Both")]
        [string]$Target,
        [Parameter(Mandatory)]
        [ValidateSet("Single","Scheduled")]
        [string]$RunMode
    )
    $fileName = Split-Path $Url -Leaf
    $dest     = Join-Path $downloadFolder $fileName

    
    Write-Host "Downloading $Url to $dest..."
    Invoke-RestMethod -Uri $Url -OutFile $dest

    $scriptname = $dest
    $wrapper = @()
    $wrapper += @"
    `$ResourceGroupName= '$($AutomationAccResourceGroupName)'
    `$AutomationAccountName= '$AutomationAccountName' 
    `$Location= '$Location'
    $(if ($null -ne $targetResourceGroup -and $targetResourceGroup -ne "") { "`$targetResourceGroup= '$targetResourceGroup'" })
    $(if ($null -ne $targetSubscription -and $targetSubscription -ne "") { "`$targetSubscription= '$targetSubscription'" })
"@
    if($Target -eq "Both" -or $Target -eq "Arc") {

        $supportfileName = Split-Path $scriptUrls.Arc.URL -Leaf
        $supportdest     = Join-Path $downloadFolder $supportfileName
        Write-Host "Downloading $($scriptUrls.Arc.URL) to $supportdest..."
        Invoke-RestMethod -Uri $scriptUrls.Arc.URL -OutFile $supportdest

        $supportfileName = Split-Path $scriptUrls.Azure.URL -Leaf
        $supportdest     = Join-Path $downloadFolder $supportfileName
        Write-Host "Downloading $scriptUrls.Azure.URL to $supportdest..."
        Invoke-RestMethod -Uri $scriptUrls.Azure.URL -OutFile $supportdest

        $nextline = if(($null -ne $targetResourceGroup -and $targetResourceGroup -ne "") -or ($null -ne $targetSubscription -and $targetSubscription -ne "")) {"``"}
        $nextline2 = if(($null -ne $targetSubscription -and $targetSubscription -ne "")){"``"}
        $wrapper += @"
`$RunbookArg =@{
LicenseType= 'PAYG'
Force = `$true
$(if ($null -ne $UsePcoreLicense) { "UsePcoreLicense='$UsePcoreLicense'" } else { "" })
$(if ($null -ne $targetSubscription -and $targetSubscription -ne "") { "SubId='$targetSubscription'" })
$(if ($null -ne $targetResourceGroup -and $targetResourceGroup -ne "") { "ResourceGroup='$targetResourceGroup'" })
}

    $scriptname -ResourceGroupName `$ResourceGroupName -AutomationAccountName `$AutomationAccountName -Location `$Location -RunbookName 'ModifyLicenseTypeArc' ``
    -RunbookPath '$(Split-Path $scriptUrls.Arc.URL -Leaf)' ``
    -RunbookArg `$RunbookArg $($nextline)
    $(if ($null -ne $targetResourceGroup -and $targetResourceGroup -ne "") { "-targetResourceGroup `$targetResourceGroup $nextline2" })
    $(if ($null -ne $targetSubscription -and $targetSubscription -ne "") { "-targetSubscription `$targetSubscription" })
"@

    }

    if($Target -eq "Both" -or $Target -eq "Azure") {

        $supportfileName = Split-Path $scriptUrls.Azure.URL -Leaf
        $supportdest     = Join-Path $downloadFolder $supportfileName
        Write-Host "Downloading $($scriptUrls.Azure.URL) to $supportdest..."
        Invoke-RestMethod -Uri $scriptUrls.Azure.URL -OutFile $supportdest

        $nextline = if(($null -ne $targetResourceGroup -and $targetResourceGroup -ne "") -or ($null -ne $targetSubscription -and $targetSubscription -ne "")) {"``"}
        $nextline2 = if(($null -ne $targetSubscription -and $targetSubscription -ne "")){"``"}
        $wrapper += @"
`$RunbookArg =@{
    Force_Start_On_Resources = `$true
    $(if ($null -ne $targetResourceGroup -and $targetResourceGroup -ne "") { "ResourceGroup= '$targetResourceGroup'" })
    $(if ($null -ne $targetSubscription -and $targetSubscription -ne "") { "SubId= '$targetSubscription'" })

}

$scriptname     -ResourceGroupName `$ResourceGroupName -AutomationAccountName `$AutomationAccountName -Location `$Location -RunbookName 'ModifyLicenseTypeAzure' ``
    -RunbookPath '$(Split-Path $scriptUrls.Azure.URL -Leaf)'``
    -RunbookArg `$RunbookArg $($nextline)
    $(if ($null -ne $targetResourceGroup -and $targetResourceGroup -ne "") { "-targetResourceGroup `$targetResourceGroup $nextline2" })
    $(if ($null -ne $targetSubscription -and $targetSubscription -ne "") { "-targetSubscription `$targetSubscription" })
        
"@

    }
    $wrapper | Out-File -FilePath './runnow.ps1' -Encoding UTF8
    .\runnow.ps1
}

# === Single run: download & invoke the appropriate script(s) ===
if($RunMode -eq "Single") {
    $wrapper = @()
    if ($Target -eq "Both" -or $Target -eq "Arc") {
        $fileName = Split-Path $scriptUrls.Arc.URL -Leaf
        $dest     = Join-Path $downloadFolder $fileName
        Write-Host "Downloading $($scriptUrls.Arc.URL) to $dest..."
        Invoke-RestMethod -Uri $scriptUrls.Arc.URL -OutFile $dest

        
        $wrapper +="$dest ``" 
        $count = $scriptUrls.Arc.Args.Keys.Count
        foreach ($arg in $scriptUrls.Arc.Args.Keys) {
            if ("" -ne $scriptUrls.Arc.Args[$arg]) {
                $count--
                if($scriptUrls.Arc.Args[$arg] -eq "True" -or $scriptUrls.Arc.Args[$arg] -eq "False") {
                    if($scriptUrls.Arc.Args[$arg] -eq "True"){
                    $wrapper+="-$($arg) $(if ($count -gt 0) { '`'})"
                    }
                }else {
                    $wrapper+="-$($arg) '$($scriptUrls.Arc.Args[$arg])' $(if ($count -gt 0) { '`' })"
                }
            }   
        }
    }

    if ($Target -eq "Both" -or $Target -eq "Azure") {
        $fileName = Split-Path $scriptUrls.Azure.URL -Leaf
        $dest     = Join-Path $downloadFolder $fileName
        Write-Host "Downloading $($scriptUrls.Azure.URL) to $dest..."
        Invoke-RestMethod -Uri $scriptUrls.Azure.URL -OutFile $dest

       
        $wrapper +="$dest ``" 
        $count = $scriptUrls.Azure.Args.Keys.Count
        foreach ($arg in $scriptUrls.Azure.Args.Keys) {
            if ("" -ne $scriptUrls.Azure.Args[$arg]) {
                $count--
                if($scriptUrls.Azure.Args[$arg] -eq "True" -or $scriptUrls.Azure.Args[$arg] -eq "False") {
                    if($scriptUrls.Azure.Args[$arg] -eq "True"){
                            $wrapper+="-$($arg) $(if ($count -gt 0) { '`'})"
                                            }
                }else{
                    $wrapper+="-$($arg) '$($scriptUrls.Azure.Args[$arg])' $(if ($count -gt 0) { '`'})"
                }
                
            }   
        }
    }

    $wrapper | Out-File -FilePath './runnow.ps1' -Encoding UTF8 
    .\runnow.ps1

    Write-Host "Single run completed."
}else{
    Write-Host "Run 'Scheduled'."
    Invoke-RemoteScript -Url $scriptUrls.General.URL -Target $Target -RunMode $RunMode
}
# === Cleanup downloaded files & folder ===
if($cleanDownloads -eq $true) {
    if (Test-Path $downloadFolder) {
        Write-Host "Cleaning up downloaded scripts in $downloadFolder..."
        try {
            Remove-Item -Path $downloadFolder -Recurse -Force
            Write-Host "Cleanup successful: removed $downloadFolder"
        }
        catch {
            Write-Warning "Cleanup failed: $_"
        }
    }
}