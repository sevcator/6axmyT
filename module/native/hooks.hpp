#pragma once
#include <sys/types.h>   // dev_t / ino_t used by zygisk.hpp
#include "config.hpp"
#include "zygisk.hpp"

namespace cloak {

// Install libc PLT hooks (file-existence hiding + property faking) for the
// current process using the Zygisk API. `cfg` must outlive the process (store
// it statically). Safe to call once from postAppSpecialize.
void install_hooks(zygisk::Api *api, const Config *cfg);

} // namespace cloak
