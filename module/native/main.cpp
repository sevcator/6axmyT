#include <sys/types.h>   // dev_t / ino_t used by zygisk.hpp
#include "zygisk.hpp"
#include "config.hpp"
#include "hooks.hpp"
#include "spoof.hpp"

#include <android/log.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdint>
#include <string>

#define LOG_TAG "Cloak"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

using zygisk::Api;
using zygisk::AppSpecializeArgs;

namespace {

// ---- length-prefixed socket helpers ----
bool xwrite(int fd, const void *buf, size_t len) {
    auto *p = static_cast<const uint8_t *>(buf);
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) return false;
        p += n; len -= n;
    }
    return true;
}
bool xread(int fd, void *buf, size_t len) {
    auto *p = static_cast<uint8_t *>(buf);
    while (len) {
        ssize_t n = read(fd, p, len);
        if (n <= 0) return false;
        p += n; len -= n;
    }
    return true;
}
bool write_str(int fd, const std::string &s) {
    uint32_t n = (uint32_t) s.size();
    return xwrite(fd, &n, sizeof n) && xwrite(fd, s.data(), n);
}
bool read_str(int fd, std::string &out) {
    uint32_t n = 0;
    if (!xread(fd, &n, sizeof n)) return false;
    if (n > (16u << 20)) return false;  // 16 MiB sanity cap
    out.resize(n);
    return n == 0 || xread(fd, out.data(), n);
}

const char *CONF_DIR = "/data/adb/cloak";

} // namespace

class CloakModule : public zygisk::ModuleBase {
public:
    void onLoad(Api *api, JNIEnv *env) override {
        api_ = api;
        env_ = env;
    }

    void preAppSpecialize(AppSpecializeArgs *args) override {
        cloak_ = false;
        spoofGms_ = false;
        std::string pkg = jstr(args->nice_name);
        if (pkg.empty()) { dontUnload_ = false; return; }

        if (!fetch_config()) { dontUnload_ = false; return; }

        // Google Play Integrity / Play Protect certification: spoof a certified
        // Build fingerprint in the GMS processes (DroidGuard runs in
        // com.google.android.gms.unstable). Enabled when pif.conf is present.
        bool isGms = pkg.rfind("com.google.android.gms", 0) == 0;
        if (isGms && !cfg_.gms_build.empty()) {
            spoofGms_ = true;
        }

        if (cfg_.shouldCloak(pkg) || spoofGms_) {
            cloak_ = cfg_.shouldCloak(pkg);
            dontUnload_ = true;
            api_->setOption(zygisk::FORCE_DENYLIST_UNMOUNT);
            LOGD("%s %s", spoofGms_ ? "certify+cloak" : "cloaking", pkg.c_str());
        }
    }

    void postAppSpecialize(const AppSpecializeArgs *) override {
        if (spoofGms_) {
            cloak::spoof_build(env_, cfg_);

            // Load the DEX hook to intercept KeyStore attestation.
            // This blocks hardware attestation chains (which reveal the unlocked
            // bootloader) and forces DroidGuard down the software/basic evaluation
            // path — the best shot at DEVICE_INTEGRITY without a keybox.
            if (!dexPath_.empty()) {
                std::string pif_json = cfg_.pif_json();
                cloak::load_dex(env_, dexPath_, pif_json);
            }
        }
        if (cloak_ || spoofGms_) {
            cloak::install_hooks(api_, &cfg_);
        }
        if (!dontUnload_) {
            api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
        }
    }

private:
    Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    cloak::Config cfg_;     // lives for the process; hooks hold a pointer to it
    std::string dexPath_;   // path to classes.dex (from companion)
    bool cloak_ = false;
    bool spoofGms_ = false;
    bool dontUnload_ = false;

    std::string jstr(jstring s) {
        if (!s) return "";
        const char *c = env_->GetStringUTFChars(s, nullptr);
        std::string r = c ? c : "";
        if (c) env_->ReleaseStringUTFChars(s, c);
        return r;
    }

    // Ask the root companion for the config files and parse them.
    bool fetch_config() {
        int fd = api_->connectCompanion();
        if (fd < 0) { LOGE("companion connect failed"); return false; }
        uint8_t req = 1;
        std::string targets, props, pif, dex_path;
        bool ok = xwrite(fd, &req, 1) &&
                  read_str(fd, targets) &&
                  read_str(fd, props) &&
                  read_str(fd, pif) &&
                  read_str(fd, dex_path);
        close(fd);
        if (!ok) { LOGE("companion read failed"); return false; }
        cfg_ = cloak::parse_config(targets, props, pif);
        dexPath_ = dex_path;
        return true;
    }
};

// ---- root companion: serves the config files to app processes ----
static const char *MODULE_DIR = "/data/adb/modules/cloak";

static std::string find_dex_path() {
    // After FORCE_DENYLIST_UNMOUNT, /data/adb/modules/ is hidden from the app
    // process. Copy the DEX to /data/local/tmp where it remains visible.
    std::string src = std::string(MODULE_DIR) + "/classes.dex";
    std::string dst = "/data/local/tmp/cloak_classes.dex";
    struct stat st;
    if (stat(src.c_str(), &st) != 0) return "";
    // Always copy (module update may have changed the DEX)
    std::string data = cloak::read_file(src);
    if (data.empty()) return "";
    FILE *f = fopen(dst.c_str(), "we");
    if (!f) return "";
    fwrite(data.data(), 1, data.size(), f);
    fclose(f);
    chmod(dst.c_str(), 0644);
    return dst;
}

static void companion_handler(int client) {
    uint8_t req = 0;
    if (!xread(client, &req, 1)) return;
    std::string targets  = cloak::read_file(std::string(CONF_DIR) + "/targets.conf");
    std::string props    = cloak::read_file(std::string(CONF_DIR) + "/props.conf");
    std::string pif      = cloak::read_file(std::string(CONF_DIR) + "/pif.conf");
    std::string dex_path = find_dex_path();
    write_str(client, targets);
    write_str(client, props);
    write_str(client, pif);
    write_str(client, dex_path);
}

REGISTER_ZYGISK_MODULE(CloakModule)
REGISTER_ZYGISK_COMPANION(companion_handler)
