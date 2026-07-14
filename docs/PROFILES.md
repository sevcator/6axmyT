# App profiles: neutralizing an app's own native detectors

The native core (unmount + libc PLT hooks + property faking) defeats the common
file-, mount-, `PATH`- and property-based root checks. Some apps ship their own
detection library and reach it through Java `native` bridge methods. Those run
inside the app's own `.so`, which may be loaded *after* Zygisk's early PLT hooks,
so a per-app **Java-level** hook is the reliable way to neutralize them.

## The pattern (validated)

Many detectors follow:

```
class FooNativeBridge {
    private native String nativeCollectSnapshot();   // runs the native probe
    // Java parser: blank snapshot  ->  "clean / no signal"
}
```

So hooking `nativeCollectSnapshot()` (via ART method hooking) and returning a
**crafted clean snapshot** makes the detector report clean without the native
probe ever running. Notes learned in practice:

- Returning `""` usually yields an *"unavailable / reduced coverage"* verdict,
  not a *clean* one. To get a genuinely clean result, return a snapshot that
  parses to "nothing suspicious" (study the parser to learn the schema).
- Detectors that ALSO check at the Java level (e.g. `new File("/…/su").exists()`)
  are already covered by the native core's file-hiding hooks.
- Keep values **consistent** across every read path the app uses (reflection,
  native, `getprop`), or a cross-source coherence check will flag the mismatch.

## Wiring (extension, not shipped in v1)

1. Build a `hooks.dex` with your profile classes and ship it in the module root.
2. In `postAppSpecialize` (native), for cloaked targets, load `hooks.dex` into
   the app class loader and call your entry point with `(ClassLoader appLoader)`.
3. Use an ART hooking library — [LSPlant](https://github.com/LSPosed/LSPlant)
   is the maintained choice — to hook the target bridge methods. Register hooks
   as each `*NativeBridge` class loads (hook a `ClassLoader`/`defineClass` path,
   or eagerly `Class.forName(name, false, appLoader)` the known bridge classes).

`customize.sh` already installs `hooks.dex` if present, so a profile build only
needs to add the DEX and the native load-call.

## Native late-loaded libraries

The native core hooks libc PLT entries **once**, at specialize time, over the
libraries already mapped. An app's own detector `.so` is usually `dlopen()`d
later and is therefore not covered. Re-committing Zygisk's PLT hook on every
`dlopen` was tried and is **unsafe** — it aborts the app when a load happens on
a sensitive thread (e.g. the render thread during EGL driver init). Covering
late-loaded libs reliably needs a runtime-safe hook library such as
[bytehook](https://github.com/bytedance/bytehook), which is built for
multi-threaded, repeated, late-binding hooking. That's the intended upgrade path
for the native layer.
