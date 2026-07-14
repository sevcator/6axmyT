#include <sys/types.h>   // dev_t / ino_t used by zygisk.hpp
#include "zygisk.hpp"
#include "config.hpp"
#include "hooks.hpp"

#include <android/log.h>
#include <sys/socket.h>
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
        std::string pkg = jstr(args->nice_name);
        if (pkg.empty()) { dontUnload_ = false; return; }

        if (!fetch_config()) { dontUnload_ = false; return; }

        if (cfg_.shouldCloak(pkg)) {
            cloak_ = true;
            dontUnload_ = true;
            // Ask the loader to run its denylist unmount for this process:
            // removes Magisk mounts, su bind-mounts, tmpfs -> root becomes
            // invisible at the filesystem level for this app only.
            api_->setOption(zygisk::FORCE_DENYLIST_UNMOUNT);
            LOGD("cloaking %s", pkg.c_str());
        }
    }

    void postAppSpecialize(const AppSpecializeArgs *) override {
        if (cloak_) {
            // libc PLT hooks: hide leftover su/magisk paths + fake props,
            // scoped to this process only.
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
    bool cloak_ = false;
    bool dontUnload_ = false;

    std::string jstr(jstring s) {
        if (!s) return "";
        const char *c = env_->GetStringUTFChars(s, nullptr);
        std::string r = c ? c : "";
        if (c) env_->ReleaseStringUTFChars(s, c);
        return r;
    }

    // Ask the root companion for the two config files and parse them.
    bool fetch_config() {
        int fd = api_->connectCompanion();
        if (fd < 0) { LOGE("companion connect failed"); return false; }
        uint8_t req = 1;
        std::string targets, props;
        bool ok = xwrite(fd, &req, 1) &&
                  read_str(fd, targets) &&
                  read_str(fd, props);
        close(fd);
        if (!ok) { LOGE("companion read failed"); return false; }
        cfg_ = cloak::parse_config(targets, props);
        return true;
    }
};

// ---- root companion: serves the config files to app processes ----
static void companion_handler(int client) {
    uint8_t req = 0;
    if (!xread(client, &req, 1)) return;
    std::string targets = cloak::read_file(std::string(CONF_DIR) + "/targets.conf");
    std::string props   = cloak::read_file(std::string(CONF_DIR) + "/props.conf");
    write_str(client, targets);
    write_str(client, props);
}

REGISTER_ZYGISK_MODULE(CloakModule)
REGISTER_ZYGISK_COMPANION(companion_handler)
