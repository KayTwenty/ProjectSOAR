// SoarDial - replacement for the crashing ASUS nhAsusStrixSvc32 control-box handler.
// Reads the STRIX RAID PRO control box (USB VID_0B05 PID_180C/180D, HID interface MI_04)
// and maps its dial/buttons to Windows volume.
//
// Box protocol (reverse engineered from nhAsusStrixSvc32.exe 1.1.23 + live capture):
//   17-byte input reports: [0]=report id 0 [1]=len [2]=checksum [3]=seq [4]=cmd [5]=data len [6..]=data
//   Each event is a sync packet (len 1, byte 0xC5) followed by a data packet.
//   cmd 0x01 = key event: 0=A pressed, 1=B pressed, 2=B long press, 3=rotary inc, 4=rotary dec
//   checksum = seq + cmd + datalen + sum(data)
//   While idle the box re-sends the last packet pair every ~963 ms; those repeats are filtered out.
//   Output "led table" (cmd 0x04): [0]=0 [1]=9 [2]=0xC5 [3]=checksum [4]=seq 0 [5]=0x04 [6]=3
//     [7]=status lights: bit0 red left, bit1 white left, bit2 red right, bit3 white right, bit4 RAID mode
//     [8..9]=ring lights, little-endian bitmask, bit0 = leftmost of 13 orange LEDs around the dial
//
// Build: C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:exe /r:System.ServiceProcess.dll /out:SoarDial.exe SoarDial.cs
// Runs as the "SoarDial" Windows service (see Install-SoarDial.ps1); log: C:\ProgramData\SoarDial\SoarDial.log
// Args:  --console   run in the foreground and log to stdout   --step N   volume step in percent (default 2)
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace SoarDial
{
    static class Program
    {
        const byte KeyA = 0, KeyB = 1, KeyBLong = 2, RotaryInc = 3, RotaryDec = 4;
        const double RepeatMinMs = 920, RepeatMaxMs = 1010;

        static bool console;
        static float step = 0.02f;
        static volatile LedUpdater leds;
        static volatile SafeFileHandle readHandle;
        static readonly ManualResetEvent stopping = new ManualResetEvent(false);
        static string logPath;

        [DllImport("kernel32.dll")] static extern bool CancelIoEx(SafeFileHandle h, IntPtr overlapped);

        static int Main(string[] args)
        {
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--console") console = true;
                else if (args[i] == "--step" && i + 1 < args.Length) step = float.Parse(args[++i]) / 100f;
            }
            logPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SoarDial", "SoarDial.log");
            Directory.CreateDirectory(Path.GetDirectoryName(logPath));
            TrimLog();

            if (!console) { ServiceBase.Run(new DialService()); return 0; }
            Console.CancelKeyPress += (s, e) => { e.Cancel = true; Stop(); };
            return Run();
        }

        // Main loop: (re)connects to the box until Stop() is called.
        internal static int Run()
        {
            bool created;
            using (new Mutex(true, @"Global\SoarDial", out created))
            {
                if (!created) { Log("Already running, exiting."); return 1; }
                Log("SoarDial started, step " + (step * 100) + "%");
                while (!stopping.WaitOne(0))
                {
                    try { RunSession(); }
                    catch (Exception e) { if (!stopping.WaitOne(0)) Log("Session ended: " + e.Message); }
                    stopping.WaitOne(3000);
                }
                Log("SoarDial stopped.");
                return 0;
            }
        }

        internal static void Stop()
        {
            stopping.Set();
            var h = readHandle;
            if (h != null && !h.IsClosed) CancelIoEx(h, IntPtr.Zero); // unblocks the pending ReadFile
        }

        // One open-read-close cycle against the box; returns/throws when the device goes away.
        static void RunSession()
        {
            string path = Hid.FindPath("vid_0b05&pid_180d") ?? Hid.FindPath("vid_0b05&pid_180c");
            if (path == null) return;
            using (var handle = Hid.Open(path, false))
            using (var stream = new FileStream(handle, FileAccess.Read, 17, false))
            using (var leds = new LedUpdater(path))
            {
                Log("Connected to control box: " + path);
                Program.leds = leds;
                readHandle = handle;
                var buf = new byte[17];
                byte[] lastData = null;
                var sinceLast = Stopwatch.StartNew();
                bool expectData = false;
                while (!stopping.WaitOne(0))
                {
                    int n = stream.Read(buf, 0, 17);
                    if (n < 7) continue;
                    if (buf[1] == 1 && buf[2] == 0xC5) { expectData = true; continue; } // sync packet
                    if (!expectData) continue;
                    expectData = false;
                    if (!ChecksumOk(buf)) { Log("Bad checksum: " + Hex(buf)); continue; }

                    double gap = sinceLast.Elapsed.TotalMilliseconds;
                    bool first = lastData == null;
                    bool same = !first && SameEvent(lastData, buf);
                    sinceLast.Restart();
                    lastData = (byte[])buf.Clone();
                    if (first) continue; // the box replays its last event on connect; use it as the baseline
                    if (same && gap >= RepeatMinMs && gap <= RepeatMaxMs) continue; // idle re-send

                    if (buf[4] == 0x01 && buf[5] >= 1) HandleKey(buf[6]);
                    else if (console) Log("Packet: " + Hex(buf));
                }
            }
        }

        static bool ChecksumOk(byte[] p)
        {
            int len = p[5], sum = p[3] + p[4] + len;
            for (int i = 0; i < len && 6 + i < p.Length; i++) sum += p[6 + i];
            return (byte)sum == p[2];
        }

        static bool SameEvent(byte[] a, byte[] b)
        {
            int len = Math.Min(6 + b[5], b.Length);
            for (int i = 1; i < len; i++) if (a[i] != b[i]) return false;
            return true;
        }

        // Buttons report once on press and again on release; act on the first and drop the second.
        const double ButtonReleaseMs = 600;
        static int lastButton = -1;
        static readonly Stopwatch sinceButton = Stopwatch.StartNew();

        static void HandleKey(byte key)
        {
            if (AsusServiceAlive()) { if (console) Log("ASUS service running, ignoring key " + key); return; }
            if (key == KeyA || key == KeyB || key == KeyBLong)
            {
                bool release = key == lastButton && sinceButton.Elapsed.TotalMilliseconds < ButtonReleaseMs;
                lastButton = release ? -1 : key;
                sinceButton.Restart();
                if (release) return;
            }
            try
            {
                switch (key)
                {
                    case RotaryInc: Audio.Step(+step); break;
                    case RotaryDec: Audio.Step(-step); break;
                    case KeyB: Audio.ToggleMute(); break; // pressing the dial
                    case KeyA: case KeyBLong: if (console) Log("Button " + (key == KeyA ? "RAID mode" : "dial long press") + " not mapped"); break;
                }
                var l = leds;
                if (l != null) l.Poke();
            }
            catch (Exception e) { Log("Audio error: " + e.Message); }
        }

        internal static bool AsusServiceAlive()
        {
            var procs = Process.GetProcessesByName("nhAsusStrixSvc32");
            foreach (var p in procs) p.Dispose();
            return procs.Length > 0;
        }

        static string Hex(byte[] b) { return BitConverter.ToString(b).Replace('-', ' '); }

        internal static void Log(string msg)
        {
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + msg;
            if (console) Console.WriteLine(line);
            try { File.AppendAllText(logPath, line + Environment.NewLine); } catch { }
        }

        static void TrimLog()
        {
            try { if (File.Exists(logPath) && new FileInfo(logPath).Length > 1 << 20) File.Delete(logPath); } catch { }
        }
    }

    sealed class DialService : ServiceBase
    {
        Thread worker;

        public DialService()
        {
            ServiceName = "SoarDial";
            CanStop = true;
            CanShutdown = true;
        }

        protected override void OnStart(string[] args)
        {
            worker = new Thread(() => Program.Run()) { IsBackground = true, Name = "SoarDial" };
            worker.SetApartmentState(ApartmentState.MTA);
            worker.Start();
        }

        protected override void OnStop() { Program.Stop(); if (worker != null) worker.Join(5000); }
        protected override void OnShutdown() { OnStop(); }
    }

    // Mirrors the STRIX volume/mute onto the box LEDs. Writes go through their own handle so they
    // never wait behind the blocking read on the input handle.
    sealed class LedUpdater : IDisposable
    {
        const int RingLeds = 13;
        const byte RedLeft = 0x01, RedRight = 0x04;

        readonly SafeFileHandle handle;
        readonly FileStream stream;
        readonly Thread thread;
        readonly AutoResetEvent wake = new AutoResetEvent(true);
        volatile bool stop;
        int lastState = -1;

        public LedUpdater(string path)
        {
            handle = Hid.Open(path, true);
            stream = new FileStream(handle, FileAccess.Write, 17, false);
            thread = new Thread(Loop) { IsBackground = true, Name = "LedUpdater" };
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
        }

        public void Poke() { if (!stop) wake.Set(); }

        void Loop()
        {
            while (!stop)
            {
                wake.WaitOne(200);
                if (stop) break;
                try
                {
                    if (Program.AsusServiceAlive()) { lastState = -1; continue; }
                    float level; bool mute;
                    Audio.Read(out level, out mute);
                    byte status; int ring;
                    if (mute) { status = RedLeft | RedRight; ring = 0; }
                    else
                    {
                        status = 0;
                        int lit = (int)Math.Ceiling(level * RingLeds - 0.001);
                        ring = (1 << Math.Max(0, Math.Min(RingLeds, lit))) - 1;
                    }
                    int state = status << 16 | ring;
                    if (state == lastState) continue;
                    Send(status, ring);
                    lastState = state;
                }
                catch (Exception e) { Program.Log("LED update failed: " + e.Message); lastState = -1; Thread.Sleep(1000); }
            }
        }

        void Send(byte status, int ring)
        {
            var p = new byte[17];
            p[1] = 9; p[2] = 0xC5; p[4] = 0; p[5] = 0x04; p[6] = 3;
            p[7] = status; p[8] = (byte)(ring & 0xFF); p[9] = (byte)(ring >> 8);
            p[3] = (byte)(p[4] + p[5] + p[6] + p[7] + p[8] + p[9]);
            stream.Write(p, 0, 17);
            stream.Flush();
        }

        public void Dispose()
        {
            stop = true;
            wake.Set();
            thread.Join(2000);
            stream.Dispose();
            handle.Dispose();
        }
    }

    static class Hid
    {
        [StructLayout(LayoutKind.Sequential)]
        struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

        [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode)] static extern IntPtr SetupDiGetClassDevsW(ref Guid g, IntPtr e, IntPtr h, int f);
        [DllImport("setupapi.dll")] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA did);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode)] static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr s, ref SP_DEVICE_INTERFACE_DATA did, IntPtr buf, int size, out int req, IntPtr dev);
        [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFileW(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);

        public static string FindPath(string match)
        {
            Guid g; HidD_GetHidGuid(out g);
            IntPtr set = SetupDiGetClassDevsW(ref g, IntPtr.Zero, IntPtr.Zero, 0x12); // DIGCF_PRESENT | DIGCF_DEVICEINTERFACE
            try
            {
                for (int i = 0; ; i++)
                {
                    var did = new SP_DEVICE_INTERFACE_DATA(); did.cbSize = Marshal.SizeOf(did);
                    if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref did)) return null;
                    int req; SetupDiGetDeviceInterfaceDetailW(set, ref did, IntPtr.Zero, 0, out req, IntPtr.Zero);
                    IntPtr buf = Marshal.AllocHGlobal(req);
                    try
                    {
                        Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                        if (!SetupDiGetDeviceInterfaceDetailW(set, ref did, buf, req, out req, IntPtr.Zero)) continue;
                        string path = Marshal.PtrToStringUni(buf + 4);
                        if (path.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0) return path;
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                }
            }
            finally { SetupDiDestroyDeviceInfoList(set); }
        }

        public static SafeFileHandle Open(string path, bool write)
        {
            // GENERIC_READ or GENERIC_WRITE, share read|write, OPEN_EXISTING
            var h = CreateFileW(path, write ? 0x40000000u : 0x80000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (h.IsInvalid) throw new IOException("Open failed, error " + Marshal.GetLastWin32Error());
            return h;
        }
    }

    // Minimal Core Audio interop: targets the active STRIX render endpoint, else the default one.
    static class Audio
    {
        static readonly Guid CLSID_MMDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        static readonly Guid IID_IAudioEndpointVolume = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        static PROPERTYKEY PKEY_FriendlyName = new PROPERTYKEY { fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), pid = 14 };

        [StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public int pid; }
        [StructLayout(LayoutKind.Sequential)] struct PROPVARIANT { public ushort vt; ushort r1, r2, r3; public IntPtr p; IntPtr p2; }
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT pv);

        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceEnumerator
        {
            int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
            int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        }

        [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceCollection
        {
            int GetCount(out int count);
            int Item(int index, out IMMDevice device);
        }

        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDevice
        {
            int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
            int OpenPropertyStore(int access, out IPropertyStore store);
            int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        }

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IPropertyStore
        {
            int GetCount(out int count);
            int GetAt(int index, out PROPERTYKEY key);
            int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        }

        [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioEndpointVolume
        {
            int RegisterControlChangeNotify(IntPtr notify);
            int UnregisterControlChangeNotify(IntPtr notify);
            int GetChannelCount(out int count);
            int SetMasterVolumeLevel(float levelDb, ref Guid ctx);
            int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
            int GetMasterVolumeLevel(out float levelDb);
            int GetMasterVolumeLevelScalar(out float level);
            int SetChannelVolumeLevel(int ch, float levelDb, ref Guid ctx);
            int SetChannelVolumeLevelScalar(int ch, float level, ref Guid ctx);
            int GetChannelVolumeLevel(int ch, out float levelDb);
            int GetChannelVolumeLevelScalar(int ch, out float level);
            int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
            int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
        }

        static Guid ctx = Guid.Empty;

        static IAudioEndpointVolume Endpoint(out string name)
        {
            var en = (IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator));
            IMMDevice target = null; name = null;
            IMMDevice def;
            if (en.GetDefaultAudioEndpoint(0, 1, out def) == 0) // eRender, eMultimedia
            {
                string n = FriendlyName(def);
                if (n != null && n.IndexOf("STRIX", StringComparison.OrdinalIgnoreCase) >= 0) { target = def; name = n; }
            }
            if (target == null)
            {
                IMMDeviceCollection col;
                if (en.EnumAudioEndpoints(0, 1, out col) == 0) // eRender, DEVICE_STATE_ACTIVE
                {
                    int count; col.GetCount(out count);
                    for (int i = 0; i < count && target == null; i++)
                    {
                        IMMDevice d; col.Item(i, out d);
                        string n = FriendlyName(d);
                        if (n != null && n.IndexOf("STRIX", StringComparison.OrdinalIgnoreCase) >= 0) { target = d; name = n; }
                    }
                }
            }
            if (target == null) { target = def; name = def != null ? FriendlyName(def) : null; }
            if (target == null) throw new InvalidOperationException("No audio output device");
            Guid iid = IID_IAudioEndpointVolume; object o;
            Marshal.ThrowExceptionForHR(target.Activate(ref iid, 1 /* CLSCTX_INPROC_SERVER */, IntPtr.Zero, out o));
            return (IAudioEndpointVolume)o;
        }

        static string FriendlyName(IMMDevice d)
        {
            IPropertyStore ps;
            if (d.OpenPropertyStore(0, out ps) != 0) return null;
            PROPVARIANT v;
            if (ps.GetValue(ref PKEY_FriendlyName, out v) != 0) return null;
            string s = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : null; // VT_LPWSTR
            PropVariantClear(ref v);
            return s;
        }

        public static void Step(float delta)
        {
            string name; var vol = Endpoint(out name);
            float level; vol.GetMasterVolumeLevelScalar(out level);
            float next = Math.Max(0f, Math.Min(1f, level + delta));
            vol.SetMasterVolumeLevelScalar(next, ref ctx);
            if (delta > 0) vol.SetMute(false, ref ctx);
            Program.Log(string.Format("Volume {0:0}% -> {1:0}% ({2})", level * 100, next * 100, name));
        }

        public static void Read(out float level, out bool mute)
        {
            string name; var vol = Endpoint(out name);
            vol.GetMasterVolumeLevelScalar(out level);
            vol.GetMute(out mute);
        }

        public static void ToggleMute()
        {
            string name; var vol = Endpoint(out name);
            bool mute; vol.GetMute(out mute);
            vol.SetMute(!mute, ref ctx);
            Program.Log((mute ? "Unmuted" : "Muted") + " (" + name + ")");
        }
    }
}
