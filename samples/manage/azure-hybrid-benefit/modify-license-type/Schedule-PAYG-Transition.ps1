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
    [string]$RunMode
)
$environment = "microsoft"
if($env:MYAPP_ENV -ne $null) {
    $environment = $env:MYAPP_ENV
}
# === Configuration ===
$scriptUrls = @{
    General = "https://github.com/$($environment)/arc-sql-dashboard/blob/master/samples/manage/azure-hybrid-benefit/modify-license-type/set-azurerunbook.ps1"
    Azure = "https://github.com/$($environment)/arc-sql-dashboard/blob/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-azure-sql-license-type.ps1"
    Arc   = "https://github.com/$($environment)/sql-server-samples/blob/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type/modify-license-type.ps1"
}
# Define a dedicated download folder under TEMP
$downloadFolder = './PayTransitionDownloads/'
# Ensure destination folder exists
if (-not (Test-Path $foldownloadFolderder)) {
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
    $dest     = Join-Path downloadFolder $fileName

    
    Write-Host "Downloading $Url to $dest..."
    Invoke-RestMethod -Uri $Url -OutFile $dest

    Write-Host "Running $dest..."
    #& $dest
}

# === Single run: download & invoke the appropriate script(s) ===
switch ($Target) {
    'Azure' {
        Invoke-RemoteScript -Url $scriptUrls.Azure -Target $Target -RunMode $RunMode
    }
    'Arc' {
        Invoke-RemoteScript -Url $scriptUrls.Arc -Target $Target -RunMode $RunMode
    }
    'Both' {
        Invoke-RemoteScript -Url $scriptUrls.Azure  -Target $Target -RunMode $RunMode
        Invoke-RemoteScript -Url $scriptUrls.Arc    -Target $Target -RunMode $RunMode
    }
}

# === Cleanup downloaded files & folder ===
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
