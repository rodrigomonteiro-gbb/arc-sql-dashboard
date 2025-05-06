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

.PARAMETER ResourceGroup
    (Optional) Name of the target resource group passed into the downstream runbook scripts.

.PARAMETER SubId
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
      -SubId "00000000-0000-0000-0000-000000000000" `
      -ResourceGroup "MyRG" `
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
    [Parameter(Mandatory = $false, Position=1)]
    [ValidateSet("Arc","Azure","Both")]
    [string]$Target = "Both",

    [Parameter (Mandatory= $false)]
    [ValidateSet("Yes","No", IgnoreCase=$false)]
    [string] $UsePcoreLicense="No",

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroup=$null,

    [Parameter(Mandatory=$false)]
    [string]$SubId=$null,

    [Parameter(Mandatory=$false)]
    [string]$AutomationAccResourceGroupName="AutomationAccResourceGroupName",

    [Parameter(Mandatory=$false)]
    [string]$AutomationAccountName="aaccAzureArcSQLLicenseType",

    [Parameter(Mandatory=$false)]
    [string]$Location=$null,

    [Parameter(Mandatory=$false)]
    [String ]$RunAt=$null,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("BasePrice","LicenseIncluded","LicenseOnly", IgnoreCase=$false)]
    [string]$SQLLicenseType="PAYG",
    
    [Parameter (Mandatory= $false)]
    [ValidateSet("Yes","No", IgnoreCase=$false)]
    [string] $EnableESU="No",

    [Parameter(Mandatory=$false)]
    [hashtable]$ExclusionTags=$null
)
function Convert-ToDateTime {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$InputString
    )

    # Define supported formats
    $formats = @(
        'yyyy-MM-dd HH:mm:ss',      # 24-hour format
        'yyyy-MM-dd hh:mm:ss tt'    # 12-hour with AM/PM
    )

    # Handle edge case: 24:00:00
    if ($InputString -match '^\d{4}-\d{2}-\d{2} 24:00:00$') {
        $baseDate = [datetime]::ParseExact($InputString.Substring(0, 10), 'yyyy-MM-dd', $null)
        return $baseDate.AddDays(1)
    }

    foreach ($format in $formats) {
        try {
            return [datetime]::ParseExact($InputString, $format, $null)
        } catch {
            # Try next format
        }
    }

    throw "Invalid date format. Supported: 'YYYY-MM-DD HH:MM:SS' (24-hour) or 'YYYY-MM-DD hh:MM:SS AM/PM' (12-hour)."
}
$targetDate = $null
$Time = $null
$DayOfWeek=$null
$RunMode = "Single"
if($null -ne $RunAt -and $RunAt -ne "") {
    $RunMode = "Scheduled"
   $targetDate = Convert-ToDateTime -InputString $RunAt
    $Time = $targetDate.ToString("h:mmtt")
    $DayOfWeek=$targetDate.DayOfWeek
}
<# For Prod Deployment
$git = "sql-server-samples"
$environment = "microsoft"
#>
$git = "arc-sql-dashboard"
$environment = "rodrigomonteiro-gbb"
# === Pre-compute LicenseType mappings ===
$AzureLicenseType = $null
$ArcLicenseType = $null
$cleanDownloads=$false
# For the Azure scripts
switch ($SQLLicenseType) {
    'LicenseOnly' { $AzureLicenseType = 'BasePrice'; break }
    'PAYG'        { $AzureLicenseType = 'LicenseIncluded'; break }
    'Paid'        { $AzureLicenseType = 'BasePrice'; break }
    default       { $AzureLicenseType = $SQLLicenseType; break }
}

# For the Arc scripts
switch ($SQLLicenseType) {
    'LicenseIncluded' { $ArcLicenseType = 'PAYG'; break }
    'BasePrice'       { $ArcLicenseType = 'Paid'; break }
    default           { $ArcLicenseType = $SQLLicenseType; break }
}
# === Configuration ===
$scriptUrls = @{
    General = @{
        URL = "https://raw.githubusercontent.com/$($environment)/$($git)/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/set-azurerunbook.ps1"
        Args = @{
            ResourceGroupName       = "'$($AutomationAccResourceGroupName)'"
            AutomationAccountName   = $AutomationAccountName 
            Location                = $Location
            ResourceGroup     = $ResourceGroup
            SubId      = $SubId
        }
    }
    Azure = @{
        URL = "https://raw.githubusercontent.com/$($environment)/$($git)/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-azure-sql-license-type.ps1"
        Args = @{
            SubId                     = [string]$SubId
            Force_Start_On_Resources  = $false
            ResourceGroup             = [string]$ResourceGroup
            LicenseType               = $AzureLicenseType
        }
    }
    Arc = @{
        URL = "https://raw.githubusercontent.com/$($environment)/$($git)/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-arc-sql-license-type.ps1"
        Args = @{
            LicenseType             = $ArcLicenseType
            Force                   = $true
            UsePcoreLicense         = [string]$UsePcoreLicense
            SubId                   = [string]$SubId
            ResourceGroup           = [string]$ResourceGroup
            EnableESU               = $EnableESU
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
        [string]$RunMode,

        [Parameter(Mandatory=$false)]
        [string]$ExclusionTags=$null
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
    $(if ($null -ne $Time -and $Time -ne "") { "`$Time= '$Time'" })
    $(if ($null -ne $DayOfWeek -and $DayOfWeek -ne "") { "`$DayOfWeek= '$DayOfWeek'" })
    $(if ($null -ne $Location -and $Location -ne "") { "`$Location= '$Location'" })
    $ExclusionTags
    $(if ($null -ne $ResourceGroup -and $ResourceGroup -ne "") { "`$ResourceGroup= '$ResourceGroup'" })
    $(if ($null -ne $SubId -and $SubId -ne "") { "`$SubId= '$SubId'" })
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

        $nextline = if(($null -ne $ResourceGroup -and $ResourceGroup -ne "") -or ($null -ne $SubId -and $SubId -ne "") -or ($null -ne $Time -and $DayOfWeek -ne "") -or ($null -ne $DayOfWeek -ne "")) {"``"}
        $nextline2 = if(($null -ne $SubId -and $SubId -ne "") -or ($null -ne $Time -and $DayOfWeek -ne "") -or ($null -ne $DayOfWeek -ne "")){"``"}
        $nextline3 = if(($null -ne $Time -and $DayOfWeek -ne "")){"``"}
        $nextline4 = if(($null -ne $DayOfWeek -ne "")){"``"}
        $wrapper += @"
`$RunbookArg =@{
LicenseType= 'PAYG'
Force = `$true
$(if ($null -ne $UsePcoreLicense) { "UsePcoreLicense='$UsePcoreLicense'" } else { "" })
$(if ($null -ne $SubId -and $SubId -ne "") { "SubId='$SubId'" })
$(if ($null -ne $ResourceGroup -and $ResourceGroup -ne "") { "ResourceGroup='$ResourceGroup'" })
$(if ($null -ne $ExclusionTags -and $ExclusionTags -ne "") { "ExclusionTags=`$ExclusionTags" })
}

    $scriptname -ResourceGroupName `$ResourceGroupName -AutomationAccountName `$AutomationAccountName -Location `$Location -RunbookName 'ModifyLicenseTypeArc' ``
    -RunbookPath '$(Split-Path $scriptUrls.Arc.URL -Leaf)' ``
    -RunbookArg `$RunbookArg $($nextline)
"@
        if ($null -ne $ResourceGroup -and $ResourceGroup -ne "") { $wrapper +="-ResourceGroup `$ResourceGroup $nextline2" }
        if ($null -ne $SubId -and $SubId -ne "") { $wrapper +="-SubId `$SubId $nextline3" }
        if ($null -ne $Time -and $Time -ne "") { $wrapper += "-Time `$Time $nextline4" }
        if ($null -ne $DayOfWeek -and $DayOfWeek -ne "") { $wrapper +="-DayOfWeek `$DayOfWeek " }

    }

    if($Target -eq "Both" -or $Target -eq "Azure") {

        $supportfileName = Split-Path $scriptUrls.Azure.URL -Leaf
        $supportdest     = Join-Path $downloadFolder $supportfileName
        Write-Host "Downloading $($scriptUrls.Azure.URL) to $supportdest..."
        Invoke-RestMethod -Uri $scriptUrls.Azure.URL -OutFile $supportdest


        $wrapper += @"
`$RunbookArg =@{
    Force_Start_On_Resources = `$true
    $(if ($null -ne $ResourceGroup -and $ResourceGroup -ne "") { "ResourceGroup= '$ResourceGroup'" })
    $(if ($null -ne $SubId -and $SubId -ne "") { "SubId= '$SubId'" })
    $(if ($null -ne $ExclusionTags -and $ExclusionTags -ne "") { "ExclusionTags=`$ExclusionTags" })
    
}

$scriptname     -ResourceGroupName `$ResourceGroupName -AutomationAccountName `$AutomationAccountName -Location `$Location -RunbookName 'ModifyLicenseTypeAzure' ``
    -RunbookPath '$(Split-Path $scriptUrls.Azure.URL -Leaf)'``
    -RunbookArg `$RunbookArg $($nextline)
"@
    if ($null -ne $ResourceGroup -and $ResourceGroup -ne "") { $wrapper +="-ResourceGroup `$ResourceGroup $nextline2" }
    if ($null -ne $SubId -and $SubId -ne "") { $wrapper +="-SubId `$SubId $nextline3" }
    if ($null -ne $Time -and $Time -ne "") { $wrapper += "-Time `$Time $nextline4" }
    if ($null -ne $DayOfWeek -and $DayOfWeek -ne "") { $wrapper +="-DayOfWeek `$DayOfWeek " }
}
    $wrapper | Out-File -FilePath './runnow.ps1' -Encoding UTF8
    .\runnow.ps1
}
$tagsFilter = @()
if($null -ne $ExclusionTags) {

    $countTags = $ExclusionTags.Keys.Count
    foreach ($tag in $ExclusionTags.Keys) {
        $countTags--
        $tagsFilter+="$($tag)= '$( $ExclusionTags[$tag])'"
    }
    $multilineString = $tagsFilter -join "`n"
    $Tags = @"
    `$ExclusionTags = @{
    $($multilineString)
    }
"@
}else{
    $Tags = $null
}
Write-Host "Tags: $($Tags)"
# === Single run: download & invoke the appropriate script(s) ===
if($RunMode -eq "Single") {
    $wrapper = @()
    if ($null -ne $Tags) {
        $wrapper += $Tags
    }
    if ($Target -eq "Both" -or $Target -eq "Arc") {
        $fileName = Split-Path $scriptUrls.Arc.URL -Leaf
        $dest     = Join-Path $downloadFolder $fileName
        Write-Host "Downloading $($scriptUrls.Arc.URL) to $dest..."
        Invoke-RestMethod -Uri $scriptUrls.Arc.URL -OutFile $dest

        
        $wrapper +="$dest ``" 
        $arcparam = @()
        foreach ($arg in $scriptUrls.Arc.Args.Keys) {
            if ("" -ne $scriptUrls.Arc.Args[$arg] -and $null -ne $scriptUrls.Arc.Args[$arg]) {
                if($scriptUrls.Arc.Args[$arg] -eq "True" -or $scriptUrls.Arc.Args[$arg] -eq "False") {
                    if($scriptUrls.Arc.Args[$arg] -eq "True"){
                        $arcparam+="-$($arg)"
                    }
                }else{
                    $arcparam+="-$($arg) '$($scriptUrls.Arc.Args[$arg])'"
                }
            }
        }
        $count = $arcparam.Count
        foreach ($arg in $arcparam) {
            $count--
            $wrapper+="$($arg) $(if ($count -gt 0 -or ($null -ne $Tags)) { '`'})"
        }
        if ($null -ne $Tags) {
            $wrapper+="-ExclusionTags `$ExclusionTags"
        }

    }

    if ($Target -eq "Both" -or $Target -eq "Azure") {
        $fileName = Split-Path $scriptUrls.Azure.URL -Leaf
        $dest     = Join-Path $downloadFolder $fileName
        Write-Host "Downloading $($scriptUrls.Azure.URL) to $dest..."
        Invoke-RestMethod -Uri $scriptUrls.Azure.URL -OutFile $dest

       
        $wrapper +="$dest ``" 
        
        $azureparam = @()
        foreach ($arg in $scriptUrls.Azure.Args.Keys) {
            if ("" -ne $scriptUrls.Azure.Args[$arg] -and $null -ne $scriptUrls.Azure.Args[$arg]) {
                if($scriptUrls.Azure.Args[$arg] -eq $true -or $scriptUrls.Azure.Args[$arg] -eq $false) {
                    if($scriptUrls.Azure.Args[$arg] -eq $true){
                        $azureparam+="-$($arg)"
                    }
                }else{
                    $azureparam+="-$($arg) '$($scriptUrls.Azure.Args[$arg])'"
                }
            }
        }
        $count = $azureparam.Count
        foreach ($arg in $azureparam) {
            $count--
            $wrapper+="$($arg) $(if ($count -gt 0 -or ($null -ne $Tags)) { '`'})"
        }
        if ($null -ne $Tags) {
            $wrapper+="-ExclusionTags `$ExclusionTags"
        }
    }

    $wrapper | Out-File -FilePath './runnow.ps1' -Encoding UTF8 
    .\runnow.ps1

    Write-Host "Single run completed."
}else{
    Write-Host "Run 'Scheduled'."
    Invoke-RemoteScript -Url $scriptUrls.General.URL -Target $Target -RunMode $RunMode -ExclusionTags $Tags
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