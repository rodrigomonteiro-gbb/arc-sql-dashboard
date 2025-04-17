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

# === Configuration ===
$scriptUrls = @{
    Azure = 'https://github.com/rodrigomonteiro-gbb/arc-sql-dashboard/blob/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-azure-sql-license-type.ps1'
    Arc   = 'https://github.com/microsoft/sql-server-samples/blob/master/samples/manage/azure-arc-enabled-sql-server/modify-license-type/modify-license-type.ps1'
}

# Helper to download a script and invoke it
function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [ValidateSet("Arc","Azure","Both")]
        string]$Target,
        [ValidateSet("Single","Scheduled")]
        [string]$RunMode
    )
    $fileName = Split-Path $Url -Leaf
    $dest     = Join-Path "./$($Target)/" $fileName

    Write-Host "Downloading $Url to $dest..."
    Invoke-RestMethod -Uri $Url -OutFile $dest

    Write-Host "Running $dest..."
    #& $dest
}

# === Single run: download & invoke the appropriate script(s) ===
switch ($Target) {
    'Azure' {
        Invoke-RemoteScript -Url $scriptUrls.Azure
    }
    'Arc' {
        Invoke-RemoteScript -Url $scriptUrls.Arc
    }
    'Both' {
        Invoke-RemoteScript -Url $scriptUrls.Azure
        Invoke-RemoteScript -Url $scriptUrls.Arc
    }
}
