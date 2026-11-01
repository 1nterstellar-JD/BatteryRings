using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public static class HidIo
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr data);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr data, out HIDP_CAPS caps);
    [DllImport("hid.dll")] static extern int HidP_GetValueCaps(int type, [Out] byte[] caps, ref ushort len, IntPtr pd);
    [DllImport("hid.dll")] static extern int HidP_GetButtonCaps(int type, [Out] byte[] caps, ref ushort len, IntPtr pd);
    [DllImport("hid.dll")] static extern bool HidD_GetManufacturerString(SafeFileHandle h, byte[] b, int l);
    [DllImport("hid.dll")] static extern bool HidD_GetProductString(SafeFileHandle h, byte[] b, int l);

    // Returns [manufacturer string, product string]
    public static string[] Strings(string path)
    {
        using (var h = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (h.IsInvalid) return new string[] { "", "" };
            var a = new byte[256]; var b = new byte[256];
            HidD_GetManufacturerString(h, a, 256); HidD_GetProductString(h, b, 256);
            return new string[] { System.Text.Encoding.Unicode.GetString(a).TrimEnd('\0'), System.Text.Encoding.Unicode.GetString(b).TrimEnd('\0') };
        }
    }

    // Report IDs used by reports of the given type (0 = Input, 1 = Output, 2 = Feature)
    public static int[] ReportIds(string path, int type)
    {
        var set = new System.Collections.Generic.SortedSet<int>();
        using (var h = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            IntPtr pd;
            if (h.IsInvalid || !HidD_GetPreparsedData(h, out pd)) return new int[0];
            try
            {
                // HIDP_VALUE_CAPS / HIDP_BUTTON_CAPS are 72 bytes; ReportID is at offset 2
                ushort n = 128; var buf = new byte[72 * 128];
                if (HidP_GetValueCaps(type, buf, ref n, pd) == 0x00110000) for (int i = 0; i < n; i++) set.Add(buf[i * 72 + 2]);
                n = 128; buf = new byte[72 * 128];
                if (HidP_GetButtonCaps(type, buf, ref n, pd) == 0x00110000) for (int i = 0; i < n; i++) set.Add(buf[i * 72 + 2]);
            }
            finally { HidD_FreePreparsedData(pd); }
        }
        var arr = new int[set.Count]; set.CopyTo(arr); return arr;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS
    {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
            NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices,
            NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    // Returns [UsagePage, Usage, InputLen, OutputLen, FeatureLen], or null on failure
    public static int[] Caps(string path)
    {
        using (var h = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (h.IsInvalid) return null;
            IntPtr pd;
            if (!HidD_GetPreparsedData(h, out pd)) return null;
            try
            {
                HIDP_CAPS c;
                HidP_GetCaps(pd, out c);
                return new int[] { c.UsagePage, c.Usage, c.InputReportByteLength, c.OutputReportByteLength, c.FeatureReportByteLength };
            }
            finally { HidD_FreePreparsedData(pd); }
        }
    }

    // Writes one output report and reads the reply. Input reports whose first `match` bytes differ
    // from the request are skipped (stale data). Returns null on error or timeout.
    // A device that did not answer (usually asleep) is not asked again for BackoffSeconds,
    // so frequent refreshes don't wait for the same timeout over and over. 0 = disabled.
    public static int BackoffSeconds = 15;
    static readonly System.Collections.Generic.Dictionary<string, DateTime> backoff =
        new System.Collections.Generic.Dictionary<string, DateTime>();

    public static byte[] Transact(string path, byte[] packet, int outSize, int inSize, int timeoutMs, int match)
    {
        string key = path + "|" + BitConverter.ToString(packet, 0, Math.Min(3, packet.Length));
        lock (backoff)
        {
            DateTime until;
            if (backoff.TryGetValue(key, out until) && DateTime.Now < until) return null;
        }
        byte[] r = TransactOnce(path, packet, outSize, inSize, timeoutMs, match);
        lock (backoff)
        {
            if (r != null) backoff.Remove(key);
            else if (lastWasTimeout && BackoffSeconds > 0) backoff[key] = DateTime.Now.AddSeconds(BackoffSeconds);
        }
        return r;
    }

    // Forget all back-off entries (e.g. after a device was plugged in)
    public static void ResetBackoff() { lock (backoff) backoff.Clear(); }

    // ---- Logitech HID++ 2.0 ----
    // Windows splits a receiver's HID++ interface into a short (7-byte, report 0x10) and a long
    // (20-byte, report 0x11) collection. The request goes out as a long report; the reply may come
    // back on either collection, and "device not connected" errors (0x8F) only on the short one,
    // so both are read at the same time.
    // Returns: reply parameters (16 bytes) on success; {0x8F|0xFF, errorCode} on a HID++ error;
    //          null on timeout (then backs off like Transact).
    public static byte[] Hidpp(string shortPath, string longPath, byte idx, byte feat, byte funcSw, byte[] prm, int timeoutMs)
    {
        string key = longPath + "|hidpp|" + idx;
        lock (backoff)
        {
            DateTime until;
            if (backoff.TryGetValue(key, out until) && DateTime.Now < until) return null;
        }
        byte[] r = HidppOnce(shortPath, longPath, idx, feat, funcSw, prm, timeoutMs);
        lock (backoff)
        {
            if (r != null) backoff.Remove(key);
            else if (BackoffSeconds > 0) backoff[key] = DateTime.Now.AddSeconds(BackoffSeconds);
        }
        return r;
    }

    static byte[] HidppOnce(string shortPath, string longPath, byte idx, byte feat, byte funcSw, byte[] prm, int timeoutMs)
    {
        var hl = CreateFile(longPath, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
        if (hl.IsInvalid) return null;
        SafeFileHandle hs = null;
        if (!string.IsNullOrEmpty(shortPath))
        {
            hs = CreateFile(shortPath, 0x80000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
            if (hs.IsInvalid) { hs.Dispose(); hs = null; }
        }
        var fl = new FileStream(hl, FileAccess.ReadWrite, 1, true);
        var fs = hs != null ? new FileStream(hs, FileAccess.Read, 1, true) : null;
        try
        {
            var pkt = new byte[20];
            pkt[0] = 0x11; pkt[1] = idx; pkt[2] = feat; pkt[3] = funcSw;
            if (prm != null) Array.Copy(prm, 0, pkt, 4, Math.Min(prm.Length, 16));
            if (!fl.WriteAsync(pkt, 0, 20).Wait(timeoutMs)) return null;

            var bl = new byte[20]; var bs = new byte[7];
            Task<int> tl = fl.ReadAsync(bl, 0, 20);
            Task<int> ts = fs != null ? fs.ReadAsync(bs, 0, 7) : null;
            var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
            byte idx2 = (byte)(idx ^ 0xFF);   // Bluetooth devices may answer 0x00 for 0xFF
            while (true)
            {
                int left = (int)(deadline - DateTime.Now).TotalMilliseconds;
                if (left <= 0) return null;
                var tasks = ts != null ? new Task[] { tl, ts } : new Task[] { tl };
                int which = Task.WaitAny(tasks, left);
                if (which < 0) return null;
                if (which == 0)
                {
                    if (tl.IsFaulted) return null;
                    if (bl[0] == 0x11 && (bl[1] == idx || bl[1] == idx2))
                    {
                        if (bl[2] == feat && bl[3] == funcSw) { var p = new byte[16]; Array.Copy(bl, 4, p, 0, 16); return p; }
                        if (bl[2] == 0xFF && bl[3] == feat && bl[4] == funcSw) return new byte[] { 0xFF, bl[5] };
                        if (bl[2] == 0x8F && bl[3] == feat && bl[4] == funcSw) return new byte[] { 0x8F, bl[5] };
                    }
                    bl = new byte[20]; tl = fl.ReadAsync(bl, 0, 20);
                }
                else
                {
                    if (ts.IsFaulted) { ts = null; continue; }
                    if (bs[0] == 0x10 && (bs[1] == idx || bs[1] == idx2))
                    {
                        if (bs[2] == 0x8F && bs[3] == feat && bs[4] == funcSw) return new byte[] { 0x8F, bs[5] };
                        if (bs[2] == 0xFF && bs[3] == feat && bs[4] == funcSw) return new byte[] { 0xFF, bs[5] };
                        if (bs[2] == feat && bs[3] == funcSw) { var p = new byte[16]; Array.Copy(bs, 4, p, 0, 3); return p; }
                    }
                    bs = new byte[7]; ts = fs.ReadAsync(bs, 0, 7);
                }
            }
        }
        catch { return null; }
        finally
        {
            try { fl.Dispose(); } catch { }
            if (fs != null) try { fs.Dispose(); } catch { }
        }
    }

    [DllImport("hid.dll")] static extern bool HidD_SetFeature(SafeFileHandle h, byte[] buf, int len);
    [DllImport("hid.dll")] static extern bool HidD_GetFeature(SafeFileHandle h, byte[] buf, int len);

    // Read a feature report (read-only). Returns null on failure.
    public static byte[] GetFeature(string path, byte reportId, int size)
    {
        using (var h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (h.IsInvalid) return null;
            var b = new byte[size]; b[0] = reportId;
            return HidD_GetFeature(h, b, size) ? b : null;
        }
    }

    // Send a feature report, wait, then read the feature report with the same id (request/response
    // protocols such as Razer's). Returns null on failure.
    public static byte[] FeatureTransact(string path, byte[] report, int size, int delayMs)
    {
        using (var h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (h.IsInvalid) return null;
            var b = new byte[size];
            Array.Copy(report, b, Math.Min(report.Length, size));
            if (!HidD_SetFeature(h, b, size)) return null;
            System.Threading.Thread.Sleep(delayMs);
            var r = new byte[size]; r[0] = report[0];
            return HidD_GetFeature(h, r, size) ? r : null;
        }
    }

    [ThreadStatic] static bool lastWasTimeout;

    static byte[] TransactOnce(string path, byte[] packet, int outSize, int inSize, int timeoutMs, int match)
    {
        lastWasTimeout = false;
        var h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero); // RW, share RW, OPEN_EXISTING, OVERLAPPED
        if (h.IsInvalid) return null;
        using (var fs = new FileStream(h, FileAccess.ReadWrite, 1, true))
        {
            try
            {
                var buf = new byte[outSize];
                Array.Copy(packet, buf, Math.Min(packet.Length, outSize));
                if (!fs.WriteAsync(buf, 0, outSize).Wait(timeoutMs)) { lastWasTimeout = true; return null; }
                var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
                while (true)
                {
                    var resp = new byte[inSize];
                    var left = (int)(deadline - DateTime.Now).TotalMilliseconds;
                    if (left <= 0) { lastWasTimeout = true; return null; }
                    if (!fs.ReadAsync(resp, 0, inSize).Wait(left)) { lastWasTimeout = true; return null; }
                    bool ok = true;
                    for (int i = 0; i < match && i < packet.Length; i++) if (resp[i] != packet[i]) { ok = false; break; }
                    if (ok) return resp;
                }
            }
            catch { return null; }
        }
    }
}

public static class HidListen
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);

    // Read-only: collects input reports pushed by the device within durationMs (writes nothing)
    public static System.Collections.Generic.List<byte[]> Listen(string path, int inSize, int durationMs, int max)
    {
        var list = new System.Collections.Generic.List<byte[]>();
        var h = CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero); // GENERIC_READ
        if (h.IsInvalid) h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
        if (h.IsInvalid) return null;
        using (var fs = new FileStream(h, FileAccess.Read, 1, true))
        {
            var deadline = DateTime.Now.AddMilliseconds(durationMs);
            try
            {
                while (list.Count < max)
                {
                    var left = (int)(deadline - DateTime.Now).TotalMilliseconds;
                    if (left <= 0) break;
                    var buf = new byte[inSize];
                    if (!fs.ReadAsync(buf, 0, inSize).Wait(left)) break;
                    list.Add(buf);
                }
            }
            catch { }
        }
        return list;
    }
}

public static class XInput
{
    [StructLayout(LayoutKind.Sequential)] public struct BATTERY { public byte Type; public byte Level; }
    [StructLayout(LayoutKind.Sequential)] public struct STATE { public uint Packet; public ushort Buttons; public byte LT, RT; public short LX, LY, RX, RY; }
    [DllImport("xinput1_4.dll")] static extern int XInputGetState(int idx, out STATE s);
    [DllImport("xinput1_4.dll")] static extern int XInputGetBatteryInformation(int idx, byte devType, out BATTERY b);

    // Returns [type, level] (type: 0 disconnected, 1 wired, 2 alkaline, 3 NiMH, 0xFF unknown; level 0-3), or null
    public static int[] Battery(int idx)
    {
        try
        {
            STATE s;
            if (XInputGetState(idx, out s) != 0) return null;
            BATTERY b;
            if (XInputGetBatteryInformation(idx, 0, out b) != 0) return null;
            return new int[] { b.Type, b.Level };
        }
        catch { return null; }
    }
}
