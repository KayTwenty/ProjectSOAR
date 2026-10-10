# Sends "led table" packets (cmd 0x04) to the STRIX RAID PRO control box.
# Out packet (17 bytes): [0]=0 [1]=len(=datalen+6) [2]=0xC5 [3]=checksum [4]=seq 0 [5]=cmd [6]=datalen [7..]=data
# checksum = seq + cmd + datalen + sum(data). LED data = 3 bytes: [mask] [level lo] [level hi]
#   LedProbe.ps1 -Data "31,5,0"            send one packet (decimal bytes, comma separated)
#   LedProbe.ps1 -Sweep                     step through test patterns, 3 s each
#   LedProbe.ps1 -Walk                      light ring positions 1..16 one at a time
param([string]$Data, [switch]$Sweep, [switch]$Walk, [int]$HoldSeconds = 3)
$ErrorActionPreference = 'Stop'
$bytes = if ($Data) { [byte[]]($Data.Trim('"') -split ',' | ForEach-Object { [byte]$_.Trim() }) }
. "$PSScriptRoot\HidInspect.ps1" | Out-Null
$path = [HidInspect]::Paths() | Where-Object { $_ -match 'vid_0b05&pid_180[cd]' } | Select-Object -First 1
if (-not $path) { throw 'Control box HID interface not found' }
$h = [HidInspect]::CreateFileW($path, [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($h.IsInvalid) { throw "Open failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
$fs = New-Object IO.FileStream($h, [IO.FileAccess]::ReadWrite, 17, $false)

function Send-Led([byte[]]$d) {
    $p = New-Object byte[] 17
    $p[1] = 6 + $d.Length; $p[2] = 0xC5; $p[4] = 0; $p[5] = 4; $p[6] = $d.Length
    [Array]::Copy($d, 0, $p, 7, $d.Length)
    $sum = $p[4] + $p[5] + $p[6]; foreach ($b in $d) { $sum += $b }
    $p[3] = [byte]($sum -band 0xFF)
    $fs.Write($p, 0, 17); $fs.Flush()
    "{0:HH:mm:ss}  sent mask=0x{1:X2} b2={2} b3={3}   [{4}]" -f (Get-Date), $d[0], $d[1], $d[2], (($p | ForEach-Object { $_.ToString('X2') }) -join ' ')
}

if ($Walk) {
    for ($i = 0; $i -lt 16; $i++) {
        $bits = 1 -shl $i
        Write-Host ("Light #{0,-2}  " -f ($i + 1)) -NoNewline
        Send-Led ([byte[]]@(0, ($bits -band 0xFF), ($bits -shr 8)))
        Start-Sleep $HoldSeconds
    }
    Send-Led ([byte[]]@(0, 0, 0)) | Out-Null
} elseif ($Sweep) {
    $patterns = @(
        @(0x00, 0, 0), @(0x01, 0, 0), @(0x02, 0, 0), @(0x04, 0, 0), @(0x08, 0, 0), @(0x10, 0, 0), @(0x1F, 0, 0),
        @(0x00, 1, 0), @(0x00, 3, 0), @(0x00, 6, 0), @(0x00, 10, 0), @(0x00, 50, 0), @(0x00, 100, 0),
        @(0x00, 0, 1), @(0x00, 0, 5), @(0x00, 0, 10)
    )
    foreach ($pat in $patterns) { Send-Led ([byte[]]$pat); Start-Sleep $HoldSeconds }
} elseif ($bytes) {
    Send-Led $bytes
} else { throw 'Pass -Data b1,b2,b3 or -Sweep' }
$fs.Dispose()
