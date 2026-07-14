#include "spoof.hpp"

#include <android/log.h>
#include <cstdlib>
#include <cstring>

#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, "Cloak", __VA_ARGS__)

namespace cloak {

static void set_str(JNIEnv *env, jclass cls, const char *field, const std::string &val) {
    if (!cls) return;
    jfieldID fid = env->GetStaticFieldID(cls, field, "Ljava/lang/String;");
    if (!fid) { env->ExceptionClear(); return; }
    jstring s = env->NewStringUTF(val.c_str());
    env->SetStaticObjectField(cls, fid, s);
    env->DeleteLocalRef(s);
}

static void set_int(JNIEnv *env, jclass cls, const char *field, int val) {
    if (!cls) return;
    jfieldID fid = env->GetStaticFieldID(cls, field, "I");
    if (!fid) { env->ExceptionClear(); return; }
    env->SetStaticIntField(cls, fid, val);
}

void spoof_build(JNIEnv *env, const Config &cfg) {
    if (!env || cfg.gms_build.empty()) return;

    jclass build = env->FindClass("android/os/Build");
    if (!build) { env->ExceptionClear(); return; }
    jclass ver = env->FindClass("android/os/Build$VERSION");
    if (!ver) env->ExceptionClear();

    int n = 0;
    for (const auto &kv : cfg.gms_build) {
        const std::string &k = kv.first;
        const std::string &v = kv.second;
        if (k == "SECURITY_PATCH") {
            set_str(env, ver, "SECURITY_PATCH", v);          // android.os.Build$VERSION
        } else if (k == "DEVICE_INITIAL_SDK_INT") {
            set_int(env, ver, "DEVICE_INITIAL_SDK_INT", atoi(v.c_str()));
        } else {
            set_str(env, build, k.c_str(), v);               // android.os.Build.<K>
        }
        ++n;
    }
    env->ExceptionClear();
    LOGD("spoofed %d Build fields for Play certification", n);
}

} // namespace cloak
