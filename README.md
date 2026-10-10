# ProjectSOAR

Fixes for the ASUS STRIX RAID PRO sound card on Windows 10, now that ASUS has dropped support for it.

I love how this card sounds, but two things broke and ASUS isn't fixing them anymore:

1. The volume dial on the control box stopped working, and the lights around it stopped following the volume.
2. After turning the PC on from cold, the card wouldn't show up in Windows sound settings until I rebooted again.

This repo fixes both. Nothing from ASUS is modified, and no ASUS files are included here. You still need the normal ASUS driver installed.

## What was wrong

**The dial:** the only thing that reads the control box is an ASUS helper called `nhAsusStrixSvc32.exe` (part of Sonic Studio 1.1.23). On my machine it crashed about a minute after every logon, and once it's gone nothing listens to the box. The box itself was fine the whole time. SoarDial is a small service I wrote to take over that job.

**Cold boot:** the card has its own ASMedia ASM1142 USB controller, with the actual audio chip sitting behind it. On a cold start the audio device sometimes never shows up behind that controller. A reboot fixed it, and restarting just the controller fixes it too, which is what StrixBootFix does at startup.

## Requirements

- STRIX RAID PRO with the ASUS driver installed. I tested with driver/Sonic Studio package 1.1.23 and control box firmware 1.14.
- Windows 10 64-bit. I'm on 22H2.
- Admin rights to install.

You don't need to download anything else. The install script compiles SoarDial with the C# compiler that comes with Windows.

## Install

Open PowerShell as administrator in this folder and run:

```powershell
# the dial, buttons and lights
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\SoarDial\Install-SoarDial.ps1

# the cold boot fix
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\BootFix\Install-StrixBootFix.ps1
```

You can install just one of them if you only have one of the problems. To update, run the same script again.

To uninstall, add `-Uninstall`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\SoarDial\Install-SoarDial.ps1 -Uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\BootFix\Install-StrixBootFix.ps1 -Uninstall
```

## SoarDial (the control box)

This installs a Windows service called `SoarDial` to `C:\Program Files\SoarDial`. It starts with Windows and gets restarted automatically if it ever crashes.

What the controls do:

- Turning the dial changes the STRIX volume, 2% per click.
- Pressing the dial mutes and unmutes.
- The RAID mode button isn't mapped to anything yet.
- The ring of 13 orange lights shows the current volume. It also updates when you change the volume somewhere else in Windows.
- The red lights on the sides come on while muted.

Some notes:

- It always controls the STRIX output, even if your default device in Windows is something else.
- If the card isn't there yet (like during a cold boot), it waits for it. If the card drops out, it reconnects.
- If the ASUS helper happens to be running, SoarDial stays out of the way until it closes, so one click never changes the volume twice.
- The log is in `C:\ProgramData\SoarDial\SoarDial.log`.

If you want to try it without installing anything, build it and run it in a terminal. If the service is installed, stop it first, since only one copy can run at a time.

```powershell
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:exe /r:System.ServiceProcess.dll /out:SoarDial.exe .\src\SoarDial\SoarDial.cs
.\SoarDial.exe --console            # add --step 5 for 5% per click
```

## StrixBootFix (cold boot)

This installs a scheduled task called `StrixBootFix` that runs as SYSTEM every time Windows starts:

1. It waits up to 25 seconds for the STRIX audio device (`USB\VID_0B05&PID_180D`). On a normal boot it shows up after about 12 seconds.
2. If it's still missing, it restarts the ASM1142 controller with `pnputil /restart-device` and gives it 12 seconds. It tries this up to 6 times.
3. It writes what happened on every boot to `C:\ProgramData\StrixBootFix\boot.log`.

On my PC the card came back on the second restart after a cold boot that would normally have needed a full reboot.

## Tools

The scripts in `tools/` are what I used to figure out how the control box talks. They might help if you have a different card or firmware.

- `HidInspect.ps1` shows the box's HID interface (report sizes and usages).
- `BoxListen.ps1 -Seconds 60` prints what the box sends while you turn the dial and press buttons.
- `LedProbe.ps1` sends light commands to the box. Use `-Data "0,255,31"` for one command, or `-Sweep` / `-Walk` to step through patterns.

Stop the SoarDial service before using `BoxListen.ps1` or `LedProbe.ps1`, otherwise they'll get in each other's way.

## How the control box talks

The box shows up as HID interface `MI_04` on USB device `VID_0B05 PID_180D`. Windows sees it as a consumer control device, but the reports are a custom ASUS format: 16 bytes plus a report ID byte, 17 in total. Windows doesn't understand them, which is why the dial needs software at all.

### From the box

```
[0] report id (0)   [1] length   [2] checksum   [3] sequence   [4] command   [5] data length   [6..] data
checksum = sequence + command + data length + sum(data)
```

Things that tripped me up:

- Every event comes as two packets: a sync packet (length 1, byte `0xC5`) and then the actual data packet.
- When nothing is happening, the box sends its last event again about every 963 ms. You can tell those repeats apart from real events because the content and timing are identical.
- Buttons send the event twice per press: once when you press and once when you let go.

Commands:

| Command | Meaning | Data |
|---|---|---|
| `0x01` | key | `0` RAID mode button, `1` dial press, `2` dial long press, `3` dial up, `4` dial down |
| `0x02` | host state | |
| `0x03` | ack (comes back after each light command) | |
| `0x05` | box status | |
| `0x06` | box version | major, minor |
| `0x07` | headphones | `1` plugged in, `2` unplugged |
| `0x08` | mic | |

### To the box (lights)

```
[0] 0   [1] 9   [2] 0xC5   [3] checksum   [4] sequence (0)   [5] 0x04   [6] 3   [7] status   [8..9] ring
checksum = sequence + 0x04 + 3 + status + ring low byte + ring high byte
```

- `status` bits: 0 red left, 1 white left, 2 red right, 3 white right, 4 RAID mode light.
- `ring` is a 16-bit little-endian bitmask. Bits 0 to 12 are the 13 orange lights around the dial, starting from the left.

Sending command `0x06` with one data byte (`0x01`) asks the box for its firmware version.

## Known limits

- I've only tested this on my own PC: STRIX RAID PRO, box firmware 1.14, Windows 10 22H2.
- The ASUS software also looks for `PID_180C`, which I think is the STRIX RAID DLX. SoarDial will try to use it, but I haven't tested it and the lights might be laid out differently. If you have one, let me know how it goes.
- The boot fix only helps when the controller is there but the audio device behind it isn't. If the controller itself is missing, that's a hardware or PCIe problem and this can't fix it. The boot log will tell you which one it is.

If something doesn't work, open an issue and attach `C:\ProgramData\SoarDial\SoarDial.log` and/or `C:\ProgramData\StrixBootFix\boot.log`.

## Disclaimer

This isn't an official ASUS project and isn't affiliated with ASUS in any way. I worked out the control box protocol so the hardware would keep working, and no ASUS code or files are included. Use at your own risk.
