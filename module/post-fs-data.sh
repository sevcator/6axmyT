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
