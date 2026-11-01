/*
 * hidapi logging proxy DLL
 * Usage: rename the target program's hidapi.dll to hidapi_real.dll and put this DLL next to it as hidapi.dll.
 * Every call is forwarded to hidapi_real.dll; HID reports sent/received are logged to hidlog.txt.
 * Build: tcc -shared -o hidapi.dll hidapi_proxy.c
 */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

typedef intptr_t (*F6)(intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t);

static HMODULE g_real;
static CRITICAL_SECTION g_cs;
static FILE *g_log;
static DWORD g_t0;

#define MAXDEV 64
static intptr_t g_dev[MAXDEV];
static char g_path[MAXDEV][160];

static FARPROC real_fn(const char *name)
{
    if (!g_real) {
        char p[MAX_PATH]; HMODULE self;
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)real_fn, &self);
        GetModuleFileNameA(self, p, MAX_PATH);
        char *s = strrchr(p, '\\'); if (s) s[1] = 0;
        strcat(p, "hidapi_real.dll");
        g_real = LoadLibraryA(p);
    }
    return g_real ? GetProcAddress(g_real, name) : NULL;
}

static void open_log(void)
{
    char p[MAX_PATH]; HMODULE self;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)open_log, &self);
    GetModuleFileNameA(self, p, MAX_PATH);
    char *s = strrchr(p, '\\'); if (s) s[1] = 0;
    strcat(p, "hidlog.txt");
    g_log = fopen(p, "a");
    g_t0 = GetTickCount();
}

static const char *dev_name(intptr_t dev)
{
    for (int i = 0; i < MAXDEV; i++) if (g_dev[i] == dev) return g_path[i];
    return "?";
}

static void log_buf(const char *tag, intptr_t dev, const unsigned char *d, int n)
{
    if (!g_log || !d || n <= 0) return;
    EnterCriticalSection(&g_cs);
    int last = n - 1;
    while (last > 0 && d[last] == 0) last--;
    fprintf(g_log, "%8lu %-3s %-40.40s len=%-3d", GetTickCount() - g_t0, tag, dev_name(dev), n);
    for (int i = 0; i <= last; i++) fprintf(g_log, " %02X", d[i]);
    fprintf(g_log, "\n");
    fflush(g_log);
    LeaveCriticalSection(&g_cs);
}

/* ---- VID/PID spoofing (protocol research only) ----
 * hidproxy.cfg, one rule per line:  spoof 3654:5055=3654:4255
 * Meaning: when the program enumerates 3654:5055, enumerate 3654:4255 instead and rewrite the IDs back to 3654:5055 */
#define MAXSPOOF 8
static int g_nspoof;
static unsigned g_sv[MAXSPOOF], g_sp[MAXSPOOF], g_tv[MAXSPOOF], g_tp[MAXSPOOF];

static void load_cfg(void)
{
    char p[MAX_PATH]; HMODULE self;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)load_cfg, &self);
    GetModuleFileNameA(self, p, MAX_PATH);
    char *s = strrchr(p, '\\'); if (s) s[1] = 0;
    strcat(p, "hidproxy.cfg");
    FILE *f = fopen(p, "r"); if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f) && g_nspoof < MAXSPOOF) {
        unsigned a, b, c, d;
        if (sscanf(line, " spoof %x:%x=%x:%x", &a, &b, &c, &d) == 4) {
            g_sv[g_nspoof] = a; g_sp[g_nspoof] = b; g_tv[g_nspoof] = c; g_tp[g_nspoof] = d; g_nspoof++;
        }
    }
    fclose(f);
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r)
{
    if (reason == DLL_PROCESS_ATTACH) {
        InitializeCriticalSection(&g_cs); open_log(); load_cfg();
        if (g_log) for (int i = 0; i < g_nspoof; i++)
            fprintf(g_log, "CFG spoof %04X:%04X -> %04X:%04X\n", g_sv[i], g_sp[i], g_tv[i], g_tp[i]);
        if (g_log) fflush(g_log);
    }
    return TRUE;
}

/* ---- plain forwarding ---- */
#define FWD(name) \
    __declspec(dllexport) intptr_t name(intptr_t a, intptr_t b, intptr_t c, intptr_t d, intptr_t e, intptr_t f) { \
        static F6 p; if (!p) p = (F6)real_fn(#name); return p ? p(a, b, c, d, e, f) : 0; }

FWD(hid_init)
FWD(hid_exit)
FWD(hid_free_enumeration)
FWD(hid_error)
FWD(hid_get_device_info)
FWD(hid_get_indexed_string)
FWD(hid_get_manufacturer_string)
FWD(hid_get_product_string)
FWD(hid_get_report_descriptor)
FWD(hid_get_serial_number_string)
FWD(hid_open)
FWD(hid_set_nonblocking)
FWD(hid_version)
FWD(hid_version_str)
FWD(hid_winapi_descriptor_reconstruct_pp_data)
FWD(hid_winapi_get_container_id)

/* ---- logging wrappers ---- */
/* struct hid_device_info: char *path; unsigned short vendor_id, product_id; ... next pointer at offset 56 (hidapi 0.14, x64) */
__declspec(dllexport) intptr_t hid_enumerate(intptr_t vid, intptr_t pid)
{
    static F6 p; if (!p) p = (F6)real_fn("hid_enumerate");
    unsigned v = (unsigned)(vid & 0xFFFF), q = (unsigned)(pid & 0xFFFF);
    int sp = -1;
    for (int i = 0; i < g_nspoof; i++) if (g_sv[i] == v && g_sp[i] == q) sp = i;
    intptr_t r = sp >= 0 ? p(g_tv[sp], g_tp[sp], 0, 0, 0, 0) : p(vid, pid, 0, 0, 0, 0);
    /* rewrite target IDs back to the IDs the program asked for (offset 8 = vendor_id, 10 = product_id) */
    for (char *d = (char *)r; d; d = *(char **)(d + 56))
        for (int i = 0; i < g_nspoof; i++)
            if (*(unsigned short *)(d + 8) == g_tv[i] && *(unsigned short *)(d + 10) == g_tp[i]) {
                *(unsigned short *)(d + 8) = (unsigned short)g_sv[i];
                *(unsigned short *)(d + 10) = (unsigned short)g_sp[i];
            }
    if (g_log) {
        EnterCriticalSection(&g_cs);
        int n = 0;
        for (char *d = (char *)r; d && n < 500; d = *(char **)(d + 56)) n++;
        fprintf(g_log, "%8lu ENUM vid=%04X pid=%04X%s -> %d devices\n", GetTickCount() - g_t0, v, q,
                sp >= 0 ? " (spoofed)" : "", n);
        for (char *d = (char *)r; d; d = *(char **)(d + 56))
            fprintf(g_log, "           usage_page=%04X usage=%04X  %s\n", *(unsigned short *)(d + 48),
                    *(unsigned short *)(d + 50), *(char **)d);
        fflush(g_log);
        LeaveCriticalSection(&g_cs);
    }
    return r;
}

__declspec(dllexport) intptr_t hid_open_path(const char *path)
{
    static F6 p; if (!p) p = (F6)real_fn("hid_open_path");
    intptr_t dev = p((intptr_t)path, 0, 0, 0, 0, 0);
    if (g_log) {
        EnterCriticalSection(&g_cs);
        fprintf(g_log, "%8lu OPEN %s -> %p\n", GetTickCount() - g_t0, path ? path : "(null)", (void *)dev);
        fflush(g_log);
        if (dev) for (int i = 0; i < MAXDEV; i++) if (!g_dev[i] || g_dev[i] == dev) {
            g_dev[i] = dev;
            /* keep only the "vid_xxxx&pid_xxxx&mi_xx&colxx" part */
            const char *s = path ? strstr(path, "vid_") : NULL; if (!s && path) s = strstr(path, "VID_");
            snprintf(g_path[i], sizeof(g_path[i]), "%.40s", s ? s : (path ? path : "?"));
            char *h = strchr(g_path[i], '#'); if (h) *h = 0;
            break;
        }
        LeaveCriticalSection(&g_cs);
    }
    return dev;
}

__declspec(dllexport) intptr_t hid_close(intptr_t dev)
{
    static F6 p; if (!p) p = (F6)real_fn("hid_close");
    return p(dev, 0, 0, 0, 0, 0);
}

__declspec(dllexport) int hid_write(intptr_t dev, const unsigned char *d, size_t n)
{
    static F6 p; if (!p) p = (F6)real_fn("hid_write");
    log_buf("W", dev, d, (int)n);
    return (int)p(dev, (intptr_t)d, (intptr_t)n, 0, 0, 0);
}

__declspec(dllexport) int hid_read(intptr_t dev, unsigned char *d, size_t n)
{
    static F6 p; if (!p) p = (F6)real_fn("hid_read");
    int r = (int)p(dev, (intptr_t)d, (intptr_t)n, 0, 0, 0);
    if (r > 0) log_buf("R", dev, d, r);
    return r;
}

__declspec(dllexport) int hid_read_timeout(intptr_t dev, unsigned char *d, size_t n, int ms)
{
    static F6 p; if (!p) p = (F6)real_fn("hid_read_timeout");
    int r = (int)p(dev, (intptr_t)d, (intptr_t)n, ms, 0, 0);
    if (r > 0) log_buf("R", dev, d, r);
    return r;
}

__declspec(dllexport) int hid_send_feature_report(intptr_t dev, const unsigned char *d, size_t n)
{
    static F6 p; if (!p) p = (F6)real_fn("hid_send_feature_report");
    log_buf("SF", dev, d, (int)n);
    return (int)p(dev, (intptr_t)d, (intptr_t)n, 0, 0, 0);
}

__declspec(dllexport) int hid_get_feature_report(intptr_t dev, unsigned char *d, size_t n)
{
    static F6 p; if (!p) p = (F6)real_fn("hid_get_feature_report");
    int r = (int)p(dev, (intptr_t)d, (intptr_t)n, 0, 0, 0);
    if (r > 0) log_buf("GF", dev, d, r);
    return r;
}

__declspec(dllexport) int hid_get_input_report(intptr_t dev, unsigned char *d, size_t n)
{
    static F6 p; if (!p) p = (F6)real_fn("hid_get_input_report");
    int r = (int)p(dev, (intptr_t)d, (intptr_t)n, 0, 0, 0);
    if (r > 0) log_buf("GI", dev, d, r);
    return r;
}
