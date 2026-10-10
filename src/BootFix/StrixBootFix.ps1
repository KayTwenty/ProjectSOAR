# Runs at system startup (as SYSTEM via scheduled task). If the STRIX RAID PRO's USB audio device
# (USB\VID_0B05&PID_180D, behind the card's ASMedia ASM1142 controller) has not appeared, restart
# that controller so it re-enumerates the device - the targeted equivalent of a warm reboot.
# Every boot is logged to C:\ProgramData\StrixBootFix\boot.log for diagnosis.
# On a good boot the card's USB device arrives ~12 s after Windows starts; on a bad cold boot it never
# does, and it took two controller restarts to bring it back (2026-10-10), so wait briefly, then retry often.
param([int]$WaitSeconds = 25, [int]$SettleSeconds = 12, [int]$MaxRestarts = 6)
$logDir = Join-Path $env:ProgramData 'StrixBootFix'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'boot.log'
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Remove-Item $log -Force }
function Log($msg) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg) }

function Get-Controller { Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\VEN_1B21&DEV_1142*' } | Select-Object -First 1 }
function Get-Strix { Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'USB\VID_0B05&PID_180D\*' } | Select-Object -First 1 }
function Get-StrixAudio { Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'USB\VID_0B05&PID_180D&MI_00*' -and $_.Status -eq 'OK' } | Select-Object -First 1 }

function Log-State($label) {
    $c = Get-Controller; $s = Get-Strix; $a = Get-StrixAudio
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Log ("{0}: uptime {1:n0}s | controller: {2} | STRIX USB: {3} | STRIX audio: {4}" -f $label, ((Get-Date) - $boot).TotalSeconds,
        $(if ($c) { "$($c.Status) (problem $($c.Problem))" } else { 'missing' }),
        $(if ($s) { "$($s.Status) (problem $($s.Problem))" } else { 'missing' }),
        $(if ($a) { 'OK' } else { 'missing' }))
    # Any ASMedia-attached device stuck with an error (e.g. descriptor request failed) is worth recording.
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^USB\\' -and $_.Status -eq 'Error' } |
        ForEach-Object { Log ("  USB device in error: {0} [{1}] problem {2}" -f $_.FriendlyName, $_.InstanceId, $_.Problem) }
}

Log '---- boot check started'
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while (-not (Get-StrixAudio) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
Log-State 'after wait'
if (Get-StrixAudio) { Log 'STRIX present, nothing to do.'; exit 0 }

for ($i = 1; $i -le $MaxRestarts; $i++) {
    $c = Get-Controller
    if (-not $c) { Log 'ASMedia controller not present at all - cannot restart it (hardware/PCIe link issue).'; exit 2 }
    Log "Restart attempt $i of controller $($c.InstanceId)"
    $out = & pnputil.exe /restart-device "$($c.InstanceId)" 2>&1
    Log ("  pnputil: " + (($out | Out-String).Trim() -replace '\s+', ' '))
    $deadline = (Get-Date).AddSeconds($SettleSeconds)
    while (-not (Get-StrixAudio) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    Log-State "after restart $i"
    if (Get-StrixAudio) { Log 'STRIX recovered.'; exit 0 }
}
Log 'STRIX still missing after all restart attempts.'
exit 1
