[CmdletBinding()]
param(
    [string] $DailyTime = "09:00",
    [string] $ProjectPath = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskName = "Nimbus Cablemobil SFTP Mailer"
$resolvedProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$runScript = Join-Path $resolvedProjectPath "run.ps1"

if (-not (Test-Path -LiteralPath $runScript -PathType Leaf)) {
    throw "run.ps1 was not found at: $runScript"
}

try {
    $parsedTime = [datetime]::ParseExact($DailyTime, "HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
}
catch {
    throw "DailyTime must use 24-hour HH:mm format, for example 09:00."
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runScript`""

$triggerTime = (Get-Date).Date.Add($parsedTime.TimeOfDay)
$trigger = New-ScheduledTaskTrigger -Daily -At $triggerTime
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

$currentUser = "$env:USERDOMAIN\$env:USERNAME"

try {
    Write-Host "To run whether the user is logged on or not, Windows needs the password for $currentUser."
    Write-Host "Press Ctrl+C to cancel if you prefer not to enter it now."
    $credential = Get-Credential -UserName $currentUser -Message "Enter the Windows password for the scheduled task account."
    $taskPassword = $credential.GetNetworkCredential().Password

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -User $credential.UserName `
        -Password $taskPassword `
        -RunLevel Highest `
        -Description "Downloads Cablemobil invoice files with WinSCP and emails them to purchases." `
        -Force | Out-Null
}
catch {
    Write-Warning "Could not register the task with 'run whether user is logged on or not'. Trying an interactive-user task instead."
    Write-Warning "To run while logged off, open PowerShell as Administrator and run this installer again; Windows may request the user's password."

    $interactivePrincipal = New-ScheduledTaskPrincipal `
        -UserId $currentUser `
        -LogonType Interactive `
        -RunLevel LeastPrivilege

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $interactivePrincipal `
        -Description "Downloads Cablemobil invoice files with WinSCP and emails them to purchases." `
        -Force | Out-Null
}

Write-Host "Scheduled task installed: $taskName"
Write-Host "Daily time: $DailyTime"
Write-Host "Project path: $resolvedProjectPath"
Write-Host "No SFTP or SMTP secrets were stored in the scheduled task. Secrets stay in config.json."
