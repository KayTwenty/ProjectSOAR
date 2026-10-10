# Passively prints packets from the STRIX RAID PRO control box for -Seconds seconds.
# Packet (17 bytes): [0]=report id [1]=len [2]=checksum [3]=seq [4]=cmd [5]=data len [6..]=data
param([int]$Seconds = 30)
. "$PSScriptRoot\HidInspect.ps1" | Out-Null
$path = [HidInspect]::Paths() | Where-Object { $_ -match 'vid_0b05&pid_180[cd]' } | Select-Object -First 1
if (-not $path) { throw 'Control box HID interface not found' }
$ErrorActionPreference = 'Stop'
$h = [HidInspect]::CreateFileW($path, [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)  # GENERIC_READ|GENERIC_WRITE
if ($h.IsInvalid) { throw "Open failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
$fs = New-Object IO.FileStream($h, [IO.FileAccess]::ReadWrite, 17, $false)
$cmds = @{ 1 = 'key'; 2 = 'host state'; 3 = 'ack'; 5 = 'box status'; 6 = 'box version'; 7 = 'headphone'; 8 = 'mic' }
$keys = @{ 0 = 'A pressed'; 1 = 'B pressed'; 2 = 'B long press'; 3 = 'Rotary inc'; 4 = 'Rotary dec' }
$deadline = (Get-Date).AddSeconds($Seconds)
"Listening on $path for $Seconds s..."
$buf = New-Object byte[] 17
$task = $fs.ReadAsync($buf, 0, 17)
while ((Get-Date) -lt $deadline) {
    if (-not $task.Wait(250)) { continue }
    $n = $task.Result
    $p = $buf[0..($n - 1)]
    $cmd = $p[4]; $name = $cmds[[int]$cmd]
    $detail = if ($cmd -eq 1) { $keys[[int]$p[6]] } else { '' }
    "{0:HH:mm:ss.fff}  {1}  cmd={2:X2} {3} {4}" -f (Get-Date), (($p | ForEach-Object { $_.ToString('X2') }) -join ' '), $cmd, $name, $detail
    $buf = New-Object byte[] 17
    $task = $fs.ReadAsync($buf, 0, 17)
}
"Done."
[Environment]::Exit(0)
