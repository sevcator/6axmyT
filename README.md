# 6axmyT

**Make your device undetectable for some apps.**

A configurable Zygisk module that makes root **invisible to selected apps**,
in-process — without changing anything system-wide. (Magisk module id / internal
codename: `cloak`.)

## Design

For every app process that matches the config, the module — inside that process
only:

- asks the loader to run its denylist unmount (`FORCE_DENYLIST_UNMOUNT`),
  removing Magisk / overlay / tmpfs mounts and `su` bind-mounts, so root
  disappears from the filesystem the app sees;
- installs libc **PLT hooks** that make `su`/magisk paths look non-existent to
  `access`/`stat`/`open`/`readlink` (belt-and-suspenders for anything the
  unmount misses);
- installs libc PLT hooks on `__system_property_get` /
  `__system_property_read_callback` that return **faked property values** from
  `props.conf` (off by default).

The result: file-, mount-, `PATH`- and property-based root checks find nothing,
and **no `su` surface is exposed at all** — the app can neither detect nor
request root. Nothing changes for any other process; no system-wide edits, no
DenyList.

## Configuration

Runtime config lives in `/data/adb/cloak/` (installed from the `module/*.conf`
defaults on first install; never overwritten on upgrade). Edit and reopen the
target app — no reboot needed.

`targets.conf`:

```conf
# mode = whitelist  -> ONLY the apps listed below are cloaked
# mode = blacklist  -> ALL apps are cloaked EXCEPT those listed below
mode = whitelist

ru.nspk.mirpay
ru.nspk.sbpay
```

- Add an app: put its package on its own line (whitelist mode).
- Cloak everything except a few: `mode = blacklist` + list the exceptions.
- Unknown/uninstalled packages are ignored, so extra lines are harmless.

`props.conf` optionally fakes system properties inside cloaked apps. It is
disabled by default: it only reaches libraries mapped at process start, so an
app's own late-loaded native library still reads the real values, which can
create a cross-source drift that property/coherence detectors flag. Root-hiding
does not need it.

## Building

CI builds it on every push — see `.github/workflows/build.yml`. It compiles
`libcloak.so` for all four ABIs with the NDK and packages a flashable
`6axmyT-<ver>.zip` (download from the run's **Artifacts**, or from **Releases**
on a `v*` tag).

Locally you need the Android NDK. Fetch the pinned Zygisk header first, then
compile per ABI (arm64 shown):

```sh
NDK=/path/to/android-ndk
CLANG="$NDK/toolchains/llvm/prebuilt/<host>-x86_64/bin/clang++"
curl -fsSL https://raw.githubusercontent.com/topjohnwu/zygisk-module-sample/master/module/jni/zygisk.hpp \
  -o module/native/zygisk.hpp
"$CLANG" --target=aarch64-linux-android26 -std=c++17 -O2 -fPIC -fvisibility=hidden \
  -shared -I module/native \
  module/native/main.cpp module/native/config.cpp module/native/hooks.cpp \
  -static-libstdc++ -llog -o zygisk/arm64-v8a.so
```

## Layout

```
.github/workflows/build.yml   # CI: build all ABIs + package zip
module/
├── module.prop               # Magisk module metadata
├── customize.sh              # installer (checks Zygisk, installs config)
├── uninstall.sh              # removes /data/adb/cloak on uninstall
├── targets.conf              # default target list (user-editable)
├── props.conf                # default faked props (disabled by default)
└── native/                   # Zygisk module C++ sources (built by CI)
```

## Scope

Native, no DEX: config-driven whitelist/blacklist targeting, root-hiding
(`FORCE_DENYLIST_UNMOUNT` + libc PLT file-hiding), optional property faking.

Out of scope: hardware attestation (TEE / verified-boot key attestation) is
verified off-device and cannot be spoofed in-process on an unlocked bootloader.
An app's own late-`dlopen`'d native detector is likewise not covered by the
one-shot PLT pass (that would need a runtime-safe hook library such as bytehook).
