# Dumps HID capabilities for the STRIX RAID PRO control box interface (VID_0B05 PID_180C/180D).
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class HidInspect {
    [StructLayout(LayoutKind.Sequential)] public struct GUID_ { public int a; public short b; public short c; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public byte[] d; }
    [StructLayout(LayoutKind.Sequential)] public struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)] public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }
    [StructLayout(LayoutKind.Sequential)] public struct HIDP_CAPS {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
            NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices,
            NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }
    // HIDP_VALUE_CAPS / HIDP_BUTTON_CAPS are both 72 bytes; read the fields we need by offset.
    [DllImport("hid.dll")] public static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] public static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
    [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr p);
    [DllImport("hid.dll")] public static extern int HidP_GetCaps(IntPtr p, out HIDP_CAPS c);
    [DllImport("hid.dll")] public static extern int HidP_GetValueCaps(int type, byte[] caps, ref ushort len, IntPtr p);
    [DllImport("hid.dll")] public static extern int HidP_GetButtonCaps(int type, byte[] caps, ref ushort len, IntPtr p);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SetupDiGetClassDevsW(ref Guid g, IntPtr e, IntPtr h, int f);
    [DllImport("setupapi.dll")] public static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA did);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)] public static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr s, ref SP_DEVICE_INTERFACE_DATA did, IntPtr buf, int size, out int req, IntPtr dev);
    [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern SafeFileHandle CreateFileW(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);

    public static string[] Paths() {
        Guid g; HidD_GetHidGuid(out g);
        IntPtr set = SetupDiGetClassDevsW(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
        var list = new System.Collections.Generic.List<string>();
        for (int i = 0; ; i++) {
            var did = new SP_DEVICE_INTERFACE_DATA(); did.cbSize = Marshal.SizeOf(did);
            if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref did)) break;
            int req; SetupDiGetDeviceInterfaceDetailW(set, ref did, IntPtr.Zero, 0, out req, IntPtr.Zero);
            IntPtr buf = Marshal.AllocHGlobal(req);
            Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
            if (SetupDiGetDeviceInterfaceDetailW(set, ref did, buf, req, out req, IntPtr.Zero))
                list.Add(Marshal.PtrToStringUni(buf + 4));
            Marshal.FreeHGlobal(buf);
        }
        SetupDiDestroyDeviceInfoList(set);
        return list.ToArray();
    }

    static string Caps(int type, int count, IntPtr pp, bool value) {
        if (count == 0) return "";
        var buf = new byte[72 * count]; ushort n = (ushort)count;
        if (value) HidP_GetValueCaps(type, buf, ref n, pp); else HidP_GetButtonCaps(type, buf, ref n, pp);
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < n; i++) {
            int o = 72 * i;
            ushort page = BitConverter.ToUInt16(buf, o); byte rid = buf[o + 2]; bool isRange = buf[o + 4] != 0;
            ushort usageOrMin = BitConverter.ToUInt16(buf, o + 56), usageMax = BitConverter.ToUInt16(buf, o + 58);
            string extra = "";
            if (value) {
                ushort bitSize = BitConverter.ToUInt16(buf, o + 18), reportCount = BitConverter.ToUInt16(buf, o + 20);
                int lmin = BitConverter.ToInt32(buf, o + 40), lmax = BitConverter.ToInt32(buf, o + 44);
                extra = string.Format(" bits={0} count={1} logical={2}..{3}", bitSize, reportCount, lmin, lmax);
            }
            sb.AppendFormat("    {0} {1}: reportId={2} page=0x{3:X4} usage=0x{4:X4}{5}{6}\n",
                type == 0 ? "IN " : type == 1 ? "OUT" : "FEA", value ? "value " : "button", rid, page, usageOrMin,
                isRange ? "..0x" + usageMax.ToString("X4") : "", extra);
        }
        return sb.ToString();
    }

    public static string Describe(string path) {
        using (var h = CreateFileW(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return "  open failed: " + Marshal.GetLastWin32Error();
            var a = new HIDD_ATTRIBUTES(); a.Size = Marshal.SizeOf(a); HidD_GetAttributes(h, ref a);
            IntPtr pp; if (!HidD_GetPreparsedData(h, out pp)) return "  no preparsed data";
            HIDP_CAPS c; HidP_GetCaps(pp, out c);
            string s = string.Format("  VID={0:X4} PID={1:X4} ver={2:X4} TLC page=0x{3:X4} usage=0x{4:X4}\n  report bytes: in={5} out={6} feature={7}\n",
                a.VendorID, a.ProductID, a.VersionNumber, c.UsagePage, c.Usage, c.InputReportByteLength, c.OutputReportByteLength, c.FeatureReportByteLength);
            s += Caps(0, c.NumberInputButtonCaps, pp, false) + Caps(0, c.NumberInputValueCaps, pp, true)
               + Caps(1, c.NumberOutputButtonCaps, pp, false) + Caps(1, c.NumberOutputValueCaps, pp, true)
               + Caps(2, c.NumberFeatureButtonCaps, pp, false) + Caps(2, c.NumberFeatureValueCaps, pp, true);
            HidD_FreePreparsedData(pp);
            return s;
        }
    }
}
'@
foreach ($p in [HidInspect]::Paths() | Where-Object { $_ -match 'vid_0b05&pid_180[cd]' }) {
    $p
    [HidInspect]::Describe($p)
}
