# Builds SoarDial and installs it as the "SoarDial" Windows service (starts at boot, restarts on failure).
# Must be run from an elevated PowerShell. Run with -Uninstall to remove the service and its files.
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$name = 'SoarDial'
$dest = Join-Path $env:ProgramFiles 'SoarDial'
$exe = Join-Path $dest 'SoarDial.exe'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated (Run as administrator) PowerShell.'
}

# Stop anything already running: an existing service, or a manual --console run.
if (Get-Service $name -ErrorAction SilentlyContinue) {
    Stop-Service $name -Force -ErrorAction SilentlyContinue
    & sc.exe delete $name | Out-Null
    Start-Sleep -Seconds 1
}
Get-Process SoarDial -ErrorAction SilentlyContinue | Stop-Process -Force
# Remove the older per-user autostart entry, if an earlier version set one.
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name SoarDial -ErrorAction SilentlyContinue

if ($Uninstall) {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    "SoarDial service removed (log kept in $env:ProgramData\SoarDial)."
    return
}

New-Item -ItemType Directory -Force $dest | Out-Null
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /optimize /target:exe /r:System.ServiceProcess.dll "/out:$exe" (Join-Path $PSScriptRoot 'SoarDial.cs')
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }

New-Service -Name $name -BinaryPathName ('"{0}"' -f $exe) -DisplayName 'SoarDial (STRIX RAID PRO control box)' `
    -Description 'Maps the STRIX RAID PRO control box dial and buttons to Windows volume and drives its LEDs.' -StartupType Automatic | Out-Null
# Restart after 5 s on the first three failures; reset the failure count after a day.
& sc.exe failure $name reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
Start-Service $name
Start-Sleep -Seconds 2
Get-Service $name | Format-Table Name, Status, StartType -AutoSize
"Log: $env:ProgramData\SoarDial\SoarDial.log"
