# Registers StrixBootFix as a startup task running as SYSTEM. Must be run from an elevated PowerShell.
# Run with -Uninstall to remove the task and the installed script.
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$name = 'StrixBootFix'
$dest = Join-Path $env:ProgramData 'StrixBootFix'
$script = Join-Path $dest 'StrixBootFix.ps1'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated (Run as administrator) PowerShell.'
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $script) { Remove-Item $script -Force }
    "StrixBootFix removed (logs kept in $dest)."
    return
}

New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'StrixBootFix.ps1') $script -Force
# Only SYSTEM and Administrators may modify the installed script, since it runs as SYSTEM.
& icacls.exe $dest /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'Users:(OI)(CI)RX' | Out-Null

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
"StrixBootFix installed. It runs at every startup; log: $dest\boot.log"
