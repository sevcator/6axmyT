#include "spoof.hpp"

#include <android/log.h>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>

#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, "Cloak", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "Cloak", __VA_ARGS__)

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
            set_str(env, ver, "SECURITY_PATCH", v);
        } else if (k == "DEVICE_INITIAL_SDK_INT") {
            set_int(env, ver, "DEVICE_INITIAL_SDK_INT", atoi(v.c_str()));
        } else {
            set_str(env, build, k.c_str(), v);
        }
        ++n;
    }
    env->ExceptionClear();
    LOGD("spoofed %d Build fields for Play certification", n);
}

void load_dex(JNIEnv *env, const std::string &dex_path, const std::string &pif_json) {
    if (!env || dex_path.empty()) return;

    struct stat st;
    if (stat(dex_path.c_str(), &st) != 0) {
        LOGE("DEX not found: %s", dex_path.c_str());
        return;
    }

    // DexClassLoader(String dexPath, String optimizedDirectory, String librarySearchPath, ClassLoader parent)
    jclass clClass = env->FindClass("java/lang/ClassLoader");
    if (!clClass) { env->ExceptionClear(); LOGE("ClassLoader not found"); return; }
    jmethodID getSysCL = env->GetStaticMethodID(clClass, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
    if (!getSysCL) { env->ExceptionClear(); LOGE("getSystemClassLoader not found"); return; }
    jobject sysCL = env->CallStaticObjectMethod(clClass, getSysCL);
    if (!sysCL) { env->ExceptionClear(); LOGE("systemClassLoader null"); return; }

    jclass dexCLClass = env->FindClass("dalvik/system/DexClassLoader");
    if (!dexCLClass) {
        env->ExceptionClear();
        dexCLClass = env->FindClass("dalvik/system/PathClassLoader");
        if (!dexCLClass) { env->ExceptionClear(); LOGE("no DexClassLoader"); return; }
    }

    jmethodID dexCLInit = env->GetMethodID(dexCLClass, "<init>",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V");
    if (!dexCLInit) { env->ExceptionClear(); LOGE("DexClassLoader.<init> not found"); return; }

    jstring jDexPath = env->NewStringUTF(dex_path.c_str());
    jstring jOptDir = nullptr;  // null = default
    jstring jLibDir = nullptr;

    jobject dexCL = env->NewObject(dexCLClass, dexCLInit, jDexPath, jOptDir, jLibDir, sysCL);
    if (env->ExceptionCheck() || !dexCL) {
        env->ExceptionClear();
        LOGE("DexClassLoader instantiation failed");
        return;
    }

    // Load the entry point class
    jmethodID loadClass = env->GetMethodID(dexCLClass, "loadClass",
        "(Ljava/lang/String;)Ljava/lang/Class;");
    if (!loadClass) {
        // Fall back to parent method
        loadClass = env->GetMethodID(clClass, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    }
    if (!loadClass) { env->ExceptionClear(); LOGE("loadClass not found"); return; }

    jstring className = env->NewStringUTF("es.chiteroman.playintegrityfix.EntryPoint");
    jclass entryClass = (jclass) env->CallObjectMethod(dexCL, loadClass, className);
    if (env->ExceptionCheck() || !entryClass) {
        env->ExceptionClear();
        LOGE("EntryPoint class not found in DEX");
        return;
    }

    // Call EntryPoint.init(String json)
    jmethodID initMethod = env->GetStaticMethodID(entryClass, "init", "(Ljava/lang/String;)V");
    if (!initMethod) {
        env->ExceptionClear();
        LOGE("EntryPoint.init() not found");
        return;
    }

    jstring jJson = env->NewStringUTF(pif_json.c_str());
    env->CallStaticVoidMethod(entryClass, initMethod, jJson);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        LOGE("EntryPoint.init() threw exception");
        return;
    }

    LOGD("DEX keystore hook loaded successfully");

    // Cleanup local refs
    env->DeleteLocalRef(jDexPath);
    env->DeleteLocalRef(className);
    env->DeleteLocalRef(jJson);
    env->DeleteLocalRef(dexCL);
    env->DeleteLocalRef(entryClass);
    env->DeleteLocalRef(sysCL);
}

} // namespace cloak
