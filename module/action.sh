#!/system/bin/sh
# 6axmyT Manager — Magisk module action button
# Shows status and runs maintenance tasks on demand.

CONF="/data/adb/cloak"
MODDIR="${0%/*}"

ui_print() { echo "$1"; }

ui_print "=============================="
ui_print "  6axmyT Manager"
ui_print "=============================="
echo ""

# Current version
VER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
ui_print "[*] Version: $VER"

# Feature status
echo ""
ui_print "[*] Features:"
[ -f "$CONF/pif.conf" ] && {
    FP=$(grep '^FINGERPRINT=' "$CONF/pif.conf" 2>/dev/null | cut -d= -f2-)
    ui_print "  Play certification : ON"
    ui_print "  Fingerprint        : ${FP:-unknown}"
} || ui_print "  Play certification : OFF (no pif.conf)"

[ -f "$CONF/auto_update_fp" ] \
    && ui_print "  Auto-update FP     : ON" \
    || ui_print "  Auto-update FP     : OFF (touch $CONF/auto_update_fp to enable)"

[ -f "$CONF/auto_blacklist" ] \
    && ui_print "  Auto-blacklist     : ON" \
    || ui_print "  Auto-blacklist     : OFF (touch $CONF/auto_blacklist to enable)"

[ -f "$CONF/auto_update" ] \
    && ui_print "  Self-update        : ON" \
    || ui_print "  Self-update        : OFF (touch $CONF/auto_update to enable)"

# Target mode and count
echo ""
MODE=$(grep '^mode' "$CONF/targets.conf" 2>/dev/null | cut -d= -f2- | tr -d ' ')
COUNT=$(grep -v '^#' "$CONF/targets.conf" 2>/dev/null | grep -v '^mode' | grep -v '^$' | wc -l | tr -d ' ')
ui_print "[*] Targets: $COUNT apps (mode: ${MODE:-whitelist})"

# DenyList status
echo ""
DL_GMS=$(magisk --denylist ls 2>/dev/null | grep -c 'com.google.android.gms')
[ "$DL_GMS" -gt 0 ] \
    && ui_print "[!] WARNING: GMS is on DenyList — cert hook won't work!" \
    || ui_print "[*] DenyList: GMS not listed (good)"

# Boot state props
echo ""
ui_print "[*] Boot state spoofing:"
ui_print "  verifiedbootstate  : $(getprop ro.boot.verifiedbootstate)"
ui_print "  flash.locked       : $(getprop ro.boot.flash.locked)"
ui_print "  vbmeta.device_state: $(getprop ro.boot.vbmeta.device_state)"
ui_print "  oem_unlock_allowed : $(getprop sys.oem_unlock_allowed)"
ui_print "  warranty_bit       : $(getprop ro.boot.warranty_bit)"

# Run maintenance now
echo ""
ui_print "[*] Running maintenance..."

# Clean DenyList
for pkg in com.google.android.gms com.android.vending; do
    magisk --denylist rm "$pkg" >/dev/null 2>&1
done
ui_print "  DenyList cleaned"

# Quick app scan
if [ -f "$CONF/auto_blacklist" ] && [ -f "$CONF/targets.conf" ]; then
    INSTALLED=$(pm list packages 2>/dev/null | sed 's/package://')
    ADDED=0
    for app in \
        ru.nspk.mirpay ru.nspk.sbpay ru.sberbankmobile \
        com.idamob.tinkoff.android ru.vtb24.mobilebanking.android \
        ru.alfabank.mobile.android ru.gazprombank.android.mobilebank.app \
        ru.raiffeisennews ru.rosbank.android ru.mkb.mobile \
        ru.rshb.dbo com.openbank ru.sovcombank.halva \
        ru.yoo.money com.yandex.bank ru.ozon.fintech.finance \
        com.qiwi.wallet com.axlebolt.standoff2; do
        if echo "$INSTALLED" | grep -qx "$app" 2>/dev/null; then
            if ! grep -qx "$app" "$CONF/targets.conf" 2>/dev/null; then
                echo "$app" >> "$CONF/targets.conf"
                ADDED=$((ADDED + 1))
            fi
        fi
    done
    ui_print "  App scan: $ADDED new apps added"
fi

# Last log entries
echo ""
if [ -f "$CONF/manager.log" ]; then
    ui_print "[*] Last log:"
    tail -5 "$CONF/manager.log" | while read -r line; do
        ui_print "  $line"
    done
fi

echo ""
ui_print "=============================="
ui_print "  Done"
ui_print "=============================="
