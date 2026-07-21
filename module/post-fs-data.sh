#!/system/bin/sh
# 6axmyT post-fs-data — runs BEFORE zygote, after system.prop is applied.
# Fix compound properties that embed "userdebug" (ro.build.flavor,
# ro.build.display.id). Simple build.type variants are handled by system.prop.

MODDIR=${0%/*}

for prop in ro.build.flavor ro.build.display.id; do
    val=$(resetprop "$prop" 2>/dev/null)
    case "$val" in *userdebug*)
        resetprop "$prop" "$(echo "$val" | sed 's/userdebug/user/g')"
    ;;esac
done

# Set vbmeta digest to match TEE attestation's verifiedBootHash.
# The bootloader on some devices (OnePlus 6) doesn't pass this in cmdline,
# but TEE attestation reports verifiedBootHash — Duck Detector cross-checks
# the two and flags "Digest missing" or "did not match".
# The cached hash is written by service.sh after a KeyStore attestation probe.
VBHASH="/data/adb/cloak/vbmeta_hash"
if [ -z "$(getprop ro.boot.vbmeta.digest 2>/dev/null)" ] && [ -f "$VBHASH" ]; then
    DIGEST=$(cat "$VBHASH" 2>/dev/null | head -1 | tr -d '[:space:]')
    [ -n "$DIGEST" ] && resetprop ro.boot.vbmeta.digest "$DIGEST"
fi
