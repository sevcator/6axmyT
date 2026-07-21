#include "hooks.hpp"

#include <cstring>
#include <cstdint>
#include <cstdarg>
#include <cstdio>
#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <set>
#include <utility>

namespace cloak {

// Config pointer captured at install time (process-global, lives for process life).
static const Config *g_cfg = nullptr;

// ---- path blocklist: what a cloaked app must not be able to see ----
static const char *const kBlockedSubstr[] = {
    "magisk", "zygisk", "lsposed", "lspd", "riru", "shamiko",
    "/data/adb", "supersu", "/su/", "busybox",
    "/system/bin/su", "/system/xbin/su", "/sbin/su",
    "/product/bin/su", "/vendor/bin/su", "/odm/bin/su",
};

static bool basename_is_su(const char *path) {
    const char *b = strrchr(path, '/');
    b = b ? b + 1 : path;
    return strcmp(b, "su") == 0 || strcmp(b, "magisk") == 0 ||
           strcmp(b, "magiskpolicy") == 0 || strcmp(b, "resetprop") == 0;
}

static bool is_blocked(const char *path) {
    if (!path) return false;
    for (const char *s : kBlockedSubstr)
        if (strstr(path, s)) return true;
    return basename_is_su(path);
}

// ---- originals ----
static int  (*o_faccessat)(int, const char *, int, int);
static int  (*o_access)(const char *, int);
static int  (*o_stat)(const char *, struct stat *);
static int  (*o_lstat)(const char *, struct stat *);
static int  (*o_fstatat)(int, const char *, struct stat *, int);
static int  (*o_open)(const char *, int, ...);
static int  (*o_openat)(int, const char *, int, ...);
static ssize_t (*o_readlink)(const char *, char *, size_t);
static ssize_t (*o_readlinkat)(int, const char *, char *, size_t);
static int  (*o_prop_get)(const char *, char *);
static void (*o_prop_read_cb)(const void *, void (*)(void *, const char *, const char *, uint32_t), void *);

// ---- file-existence hiding: pretend blocked paths don't exist ----
static int h_faccessat(int d, const char *p, int m, int f) {
    if (is_blocked(p)) { errno = ENOENT; return -1; }
    return o_faccessat(d, p, m, f);
}
static int h_access(const char *p, int m) {
    if (is_blocked(p)) { errno = ENOENT; return -1; }
    return o_access(p, m);
}
static int h_stat(const char *p, struct stat *s) {
    if (is_blocked(p)) { errno = ENOENT; return -1; }
    return o_stat(p, s);
}
static int h_lstat(const char *p, struct stat *s) {
    if (is_blocked(p)) { errno = ENOENT; return -1; }
    return o_lstat(p, s);
}
static int h_fstatat(int d, const char *p, struct stat *s, int f) {
    if (is_blocked(p)) { errno = ENOENT; return -1; }
    return o_fstatat(d, p, s, f);
}
static int h_open(const char *p, int fl, ...) {
    if (is_blocked(p)) { errno = ENOENT; return -1; }
    int mode = 0;
    if (fl & O_CREAT) { va_list ap; va_start(ap, fl); mode = va_arg(ap, int); va_end(ap); }
    return o_open(p, fl, mode);
}
static int h_openat(int d, const char *p, int fl, ...) {
    if (is_blocked(p)) { errno = ENOENT; return -1; }
    int mode = 0;
    if (fl & O_CREAT) { va_list ap; va_start(ap, fl); mode = va_arg(ap, int); va_end(ap); }
    return o_openat(d, p, fl, mode);
}
static ssize_t h_readlink(const char *p, char *b, size_t n) {
    if (is_blocked(p)) { errno = ENOENT; return -1; }
    return o_readlink(p, b, n);
}
static ssize_t h_readlinkat(int d, const char *p, char *b, size_t n) {
    if (is_blocked(p)) { errno = ENOENT; return -1; }
    return o_readlinkat(d, p, b, n);
}

// ---- hardcoded boot-state props: always spoofed in every cloaked process ----
// Duck Detector reads these to determine "Boot state: Unlocked". We return the
// values a locked, verified-boot device would have. These are informational-only
// labels; changing them has zero effect on actual system behavior.
static const struct { const char *name; const char *value; } kBootProps[] = {
    {"ro.boot.verifiedbootstate",     "green"},
    {"ro.boot.flash.locked",          "1"},
    {"ro.boot.vbmeta.device_state",   "locked"},
    {"sys.oem_unlock_allowed",        "0"},
    {"ro.boot.warranty_bit",          "0"},
    {"ro.warranty_bit",               "0"},
    {"ro.boot.selinux",               "enforcing"},
    {"ro.secureboot.lockstate",       "locked"},
    {"vendor.boot.verifiedbootstate", "green"},
    {"vendor.boot.vbmeta.device_state","locked"},
    {"ro.is_ever_orange",             "0"},
    {"ro.debuggable",                 "0"},
    {"ro.force.debuggable",           "0"},
    {"ro.secure",                     "1"},
    {"ro.adb.secure",                 "1"},
    {"ro.build.type",                 "user"},
    {"ro.build.tags",                 "release-keys"},
    {"ro.product.build.type",         "user"},
    {"ro.system.build.type",          "user"},
    {"ro.system_ext.build.type",      "user"},
    {"ro.vendor.build.type",          "user"},
    {"ro.vendor_dlkm.build.type",     "user"},
    {"ro.bootimage.build.type",       "user"},
    {"ro.boot.veritymode",            "enforcing"},
    {"ro.vendor.boot.warranty_bit",   "0"},
    {"ro.vendor.warranty_bit",        "0"},
    {"ro.boot.realmebootstate",       "green"},
    {"ro.boot.realme.lockstate",      "1"},
};

// Props where "userdebug" in the real value is replaced with "user".
// These have device-specific prefixes so we can't hardcode the full value.
static const char *const kDebugReplaceProps[] = {
    "ro.build.flavor",
    "ro.build.display.id",
};

// Recovery mode props: spoof only when the real value contains "recovery"
static const struct { const char *name; const char *spoof; } kRecoveryProps[] = {
    {"ro.bootmode",           "unknown"},
    {"ro.boot.bootmode",      "unknown"},
    {"vendor.boot.bootmode",  "unknown"},
};

static const char *find_boot_prop(const char *name) {
    for (const auto &bp : kBootProps)
        if (strcmp(name, bp.name) == 0) return bp.value;
    return nullptr;
}

// ---- directory listing hiding: filter magisk entries from readdir ----
static struct dirent *(*o_readdir)(DIR *);
static struct dirent *h_readdir(DIR *dir) {
    struct dirent *entry;
    while ((entry = o_readdir(dir)) != nullptr) {
        if (entry->d_name[0] && (is_blocked(entry->d_name) || basename_is_su(entry->d_name)))
            continue;
        break;
    }
    return entry;
}

// ---- recovery mode prop check ----
static const char *find_recovery_prop(const char *name) {
    for (const auto &rp : kRecoveryProps)
        if (strcmp(name, rp.name) == 0) return rp.spoof;
    return nullptr;
}

static bool is_debug_replace_prop(const char *name) {
    for (const char *p : kDebugReplaceProps)
        if (strcmp(name, p) == 0) return true;
    return false;
}

// In-place replace first occurrence of "userdebug" with "user" in buf.
// Returns new string length.
static int replace_userdebug(char *buf, int len) {
    char *pos = strstr(buf, "userdebug");
    if (!pos) return len;
    // "userdebug" (9) -> "user" (4), shift tail left by 5
    int tail = len - (int)(pos - buf) - 9;
    memmove(pos + 4, pos + 9, tail + 1); // +1 for NUL
    memcpy(pos, "user", 4);
    return len - 5;
}

// ---- property faking (classic API) ----
static int h_prop_get(const char *name, char *value) {
    if (name) {
        const char *bp = find_boot_prop(name);
        if (bp) {
            size_t n = strlen(bp);
            if (n > 91) n = 91;
            memcpy(value, bp, n);
            value[n] = '\0';
            return (int) n;
        }
        // Recovery mode props: only spoof if real value contains "recovery"
        const char *rp = find_recovery_prop(name);
        if (rp) {
            int len = o_prop_get(name, value);
            if (len > 0 && strstr(value, "recovery")) {
                size_t n = strlen(rp);
                memcpy(value, rp, n);
                value[n] = '\0';
                return (int) n;
            }
            return len;
        }
        // Dynamic "userdebug" → "user" replacement for compound props
        if (is_debug_replace_prop(name)) {
            int len = o_prop_get(name, value);
            if (len > 0) return replace_userdebug(value, len);
            return len;
        }
        if (g_cfg) {
            auto it = g_cfg->props.find(name);
            if (it != g_cfg->props.end()) {
                size_t n = it->second.copy(value, 91);
                value[n] = '\0';
                return (int) n;
            }
        }
    }
    return o_prop_get(name, value);
}

// ---- property faking (modern read-callback API) ----
struct CbCtx {
    void (*user_cb)(void *, const char *, const char *, uint32_t);
    void *user_cookie;
};
static thread_local char tl_cb_buf[256];
static void cb_trampoline(void *cookie, const char *name, const char *value, uint32_t serial) {
    auto *ctx = static_cast<CbCtx *>(cookie);
    if (name) {
        const char *bp = find_boot_prop(name);
        if (bp) { value = bp; }
        else {
            const char *rp = find_recovery_prop(name);
            if (rp && value && strstr(value, "recovery")) {
                value = rp;
            } else if (is_debug_replace_prop(name) && value && strstr(value, "userdebug")) {
                size_t n = strlen(value);
                if (n < sizeof(tl_cb_buf)) {
                    memcpy(tl_cb_buf, value, n + 1);
                    replace_userdebug(tl_cb_buf, (int)n);
                    value = tl_cb_buf;
                }
            } else if (g_cfg) {
                auto it = g_cfg->props.find(name);
                if (it != g_cfg->props.end())
                    value = it->second.c_str();
            }
        }
    }
    ctx->user_cb(ctx->user_cookie, name, value, serial);
}
static void h_prop_read_cb(const void *pi,
                           void (*cb)(void *, const char *, const char *, uint32_t),
                           void *cookie) {
    CbCtx ctx{cb, cookie};
    o_prop_read_cb(pi, cb_trampoline, &ctx);
}

// One symbol -> (hook fn, storage for original).
struct HookSpec { const char *sym; void *hook; void **orig; };

static const HookSpec kHooks[] = {
    {"faccessat",  (void *) h_faccessat,  (void **) &o_faccessat},
    {"access",     (void *) h_access,     (void **) &o_access},
    {"stat",       (void *) h_stat,       (void **) &o_stat},
    {"lstat",      (void *) h_lstat,      (void **) &o_lstat},
    {"fstatat",    (void *) h_fstatat,    (void **) &o_fstatat},
    {"open",       (void *) h_open,       (void **) &o_open},
    {"openat",     (void *) h_openat,     (void **) &o_openat},
    {"readlink",   (void *) h_readlink,   (void **) &o_readlink},
    {"readlinkat", (void *) h_readlinkat, (void **) &o_readlinkat},
    {"__system_property_get",           (void *) h_prop_get,     (void **) &o_prop_get},
    {"__system_property_read_callback", (void *) h_prop_read_cb, (void **) &o_prop_read_cb},
    {"readdir",                         (void *) h_readdir,      (void **) &o_readdir},
};

// The Zygisk API patches the GOT of a specific loaded ELF, identified by
// (device, inode). Walk /proc/self/maps and register the hooks for every
// file-backed library currently mapped into this process, then commit once.
//
// NOTE: this is a one-shot pass at specialize time. Libraries an app dlopen()s
// *later* are not covered — Zygisk's PLT hook is not safe to re-commit at
// arbitrary runtime points (it corrupts state when called from e.g. the render
// thread mid graphics-driver load). Covering late-loaded libs would need a
// runtime-safe inline/PLT hook library (e.g. bytehook).
void install_hooks(zygisk::Api *api, const Config *cfg) {
    g_cfg = cfg;

    FILE *maps = fopen("/proc/self/maps", "re");
    if (!maps) return;

    std::set<std::pair<dev_t, ino_t>> seen;
    char line[512];
    while (fgets(line, sizeof line, maps)) {
        unsigned long start, end, off;
        char perms[8];
        unsigned major, minor;
        unsigned long inode;
        char path[400] = {0};
        int n = sscanf(line, "%lx-%lx %7s %lx %x:%x %lu %399[^\n]",
                       &start, &end, perms, &off, &major, &minor, &inode, path);
        if (n < 7 || inode == 0) continue;

        char *p = path;
        while (*p == ' ') ++p;
        if (*p != '/') continue;                 // only real files

        dev_t dev = makedev(major, minor);
        if (!seen.insert({dev, inode}).second) continue;   // once per library

        for (const auto &h : kHooks)
            api->pltHookRegister(dev, inode, h.sym, h.hook, h.orig);
    }
    fclose(maps);

    api->pltHookCommit();
}

} // namespace cloak
