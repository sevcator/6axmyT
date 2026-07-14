# 6axmyT

**Make your device undetectable for some apps.**

A configurable Zygisk module that makes root **invisible to selected apps**
in-process, with an optional hook layer for neutralizing app-side detection —
without changing anything system-wide. (Magisk module id / internal codename:
`cloak`.)

## Design

Two layers:

1. **Native in-process cloaking (core, always on for targets).**
   For every app process that matches the config, the Zygisk module, inside that
   process only:
   - asks the loader to run its denylist unmount (`FORCE_DENYLIST_UNMOUNT`),
     removing Magisk / overlay / tmpfs mounts and `su` bind-mounts — root
     disappears from the filesystem the app sees,
   - installs libc **PLT hooks** that make `su`/magisk paths look non-existent to
     `access`/`stat`/`open`/`readlink` (belt-and-suspenders for anything the
     unmount misses), and
   - installs libc PLT hooks on `__system_property_get` /
     `__system_property_read_callback` that return **faked property values**
     (from `props.conf`) — only inside cloaked apps.
   The result: file-, mount-, `PATH`- and property-based root checks find
   nothing, and **no `su` surface is exposed at all** — the app can neither
   detect nor request root. Nothing is changed for any other process.

2. **Companion-DEX hook layer (optional, per-app profiles — see `docs/PROFILES.md`).**
   For apps that run their own *native* detection library (e.g. a bespoke
   `libdetector.so` reached through Java `native` bridge methods), the module can
   additionally load a companion DEX and hook those specific Java bridge methods
   in-process. This is the approach validated separately; it is documented as an
   extension and is **not required** for the native core above.

Nothing is written to system properties globally and no DenyList is required —
everything happens inside the target process.

## Configuration

Runtime config lives at `/data/adb/cloak/targets.conf` (installed from
`config/targets.conf` on first install; never overwritten on upgrade).

```conf
# mode = whitelist  -> ONLY the apps listed below are cloaked
# mode = blacklist  -> ALL apps are cloaked EXCEPT those listed below
mode = whitelist

ru.nspk.mirpay
ru.nspk.sbpay
```

- Add an app to anti-detection: put its package on its own line (whitelist mode).
- Cloak everything except a few apps: set `mode = blacklist` and list the
  exceptions (e.g. your banking app's own allowlist, dev tools).

Edit the file and reopen the target app — no reboot needed.

## Building

Local builds need the Android NDK; CI does it for you. See
`.github/workflows/build.yml`. The workflow builds `libcloak.so` for all four
ABIs and packages a flashable `cloak-<ver>.zip`.

Manual:

```sh
ANDROID_NDK_HOME=/path/to/ndk ./scripts/build.sh
# -> out/cloak-<ver>.zip
```

## Layout

```
antidetect/
├── config/targets.conf            # default target list (shipped, user-editable)
├── config/props.conf              # default faked props (shipped, user-editable)
├── magisk-module/                 # Magisk module skeleton (packaged)
├── native/                        # Zygisk module C++ (libcloak.so)
├── scripts/build.sh               # fetch header + native build + zip
├── docs/PROFILES.md               # optional companion-DEX hook layer
└── .github/workflows/build.yml    # CI
```

## Status (v1 — native, no DEX required)

- Config parsing (whitelist/blacklist) + per-app injection decision: done.
- Root companion (serves root-only config to app processes): done.
- Root-hiding: `FORCE_DENYLIST_UNMOUNT` + libc PLT hooks hiding su/magisk paths
  from file checks: done.
- Property faking inside cloaked apps via libc PLT hooks
  (`__system_property_get`, `__system_property_read_callback`): done.
- App-specific Java-level detector neutralization (hooking an app's own native
  bridge methods): documented extension, see `docs/PROFILES.md`.

Hardware attestation (TEE / verified-boot key attestation) is **out of scope**:
it is verified off-device and cannot be spoofed in-process on an unlocked
bootloader.
