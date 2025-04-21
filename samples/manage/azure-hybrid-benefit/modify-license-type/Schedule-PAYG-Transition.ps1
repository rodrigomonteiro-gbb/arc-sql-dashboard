<#
.SYNOPSIS
    Schedules or executes pay-transition operations for Azure and/or Arc.

.DESCRIPTION
    Depending on parameters, this script either:
      - Downloads and runs the Azure and/or Arc pay-transition scripts once, or
      - Registers a Windows Scheduled Task to invoke itself daily at 2 AM.

.PARAMETER Target
    Which environment(s) to process:
      - Arc
      - Azure
      - Both

.PARAMETER RunMode
    Whether to run immediately or schedule recurring runs:
      - Single     : Download & invoke once, then exit.
      - Scheduled  : Create or update the scheduled task calling this script daily.

.EXAMPLE
    # Run immediately for both Azure and Arc
    .\schedule-pay-transition.ps1 -Target Both -RunMode Single

.EXAMPLE
    # Schedule daily runs for Azure only
    .\schedule-pay-transition.ps1 -Target Azure -RunMode Scheduled
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
    [string]$targetResourceGroup,

    [Parameter(Mandatory=$false)]
    [string]$targetSubscription,

    [Parameter(Mandatory=$false)]
    [string]$AutomationAccountName

    [Parameter(Mandatory=$false)]
    [string]$Location
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
        URL = "https://github.com/$($environment)/$($git)/blob/master/samples/manage/azure-hybrid-benefit/modify-license-type/set-azurerunbook.ps1"
        Args = @{
            ResourceGroupName= $ResourceGroupName 
            AutomationAccountName= $AutomationAccountName 
            Location= $Location
            RunbookName= $RunbookName 
            RunbookPath= $RunbookPath
            RunbookArg=@{}
            targetResourceGroup= $targetResourceGroup
            targetSubscription= $targetSubscription}
    Azure = @{
        URL = "https://github.com/$($environment)/$($git)/blob/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-azure-sql-license-type.ps1"
        Args = @{
            Force_Start_On_Resources = $true
            SubId = $targetSubscription
            ResourceGroup = $targetResourceGroup
        }
    }
    Arc   = @{
        URL = "https://github.com/$($environment)/$($git)/blob/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type/modify-license-type.ps1"
        Args =@{
            LicenseType= "PAYG"
            Force = $true
            UsePcoreLicense=$UsePcoreLicense
            SubId = $targetSubscription
            ResourceGroup = $targetResourceGroup
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

    Write-Host "Running $dest..."
    if($Target -eq "Both") {
        $scriptUrls.General.Args.RunbookArg = $scriptUrls.Arc.Args
        $scriptUrls.General.Args.RunbookName = "ModifyLicenseTypeArc"
        $scriptUrls.General.Args.RunbookPath = Split-Path $scriptUrls.Arc.URL -Leaf
        & $dest @($scriptUrls.General.Args) -ErrorAction Stop

        $scriptUrls.General.Args.RunbookArg = $scriptUrls.Azure.Args
        $scriptUrls.General.Args.RunbookName = "ModifyLicenseTypeAzure"
        $scriptUrls.General.Args.RunbookPath = Split-Path $scriptUrls.Azure.URL -Leaf
        & $dest @($scriptUrls.General.Args) -ErrorAction Stop
    }else
    {
        $scriptUrls.General.Args.RunbookArg = $scriptUrls[$Target].Args
        $scriptUrls.General.Args.RunbookName = "ModifyLicenseType$Target"
        $scriptUrls.General.Args.RunbookPath = Split-Path $scriptUrls[$Target].URL -Leaf
        # Invoke the script with the specified arguments
      & $dest @($scriptUrls[$Target].Args) -ErrorAction Stop
    }
}

# === Single run: download & invoke the appropriate script(s) ===
if($RunMode -eq "Single") {
    switch ($Target) {
        'Azure' {
            Invoke-RemoteScript -Url $scriptUrls.Azure.URL -Target $Target -RunMode $RunMode
        }
        'Arc' {
            Invoke-RemoteScript -Url $scriptUrls.Arc.URL -Target $Target -RunMode $RunMode
        }
        'Both' {
            Invoke-RemoteScript -Url $scriptUrls.Azure.URL  -Target $Target -RunMode $RunMode
            Invoke-RemoteScript -Url $scriptUrls.Arc.URL    -Target $Target -RunMode $RunMode
        }
    }
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