#pragma once
#include <jni.h>
#include "config.hpp"

namespace cloak {

// Overwrite android.os.Build / Build.VERSION fields in the current process with
// the certified-device values from cfg.gms_build (via JNI SetStaticObjectField).
// This is what makes Google Play Integrity's basic evaluation (Play Protect
// certification + MEETS_BASIC_INTEGRITY) see a certified fingerprint instead of
// the real rooted device. Call in postAppSpecialize of the GMS processes,
// before GMS reads Build.
void spoof_build(JNIEnv *env, const Config &cfg);

} // namespace cloak
