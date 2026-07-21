#!/system/bin/sh
# 6axmyT Manager — Magisk action button dashboard

CONF="/data/adb/cloak"
MODDIR="${0%/*}"

ui_print() { echo "$1"; }

VER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
ui_print "=============================="
ui_print "  6axmyT Manager $VER"
ui_print "=============================="

# ---------- Dependency modules ----------
echo ""
ui_print "[*] Managed Modules:"
if [ -f "$CONF/modules.conf" ]; then
    sh "$MODDIR/manager.sh" update
else
    ui_print "  [!] modules.conf not found"
    ui_print "  Copy from $MODDIR/modules.conf to $CONF/"
fi

# ---------- Play Integrity ----------
echo ""
ui_print "[*] Play Integrity:"
if [ -f "$CONF/pif.conf" ]; then
    FP=$(grep '^FINGERPRINT=' "$CONF/pif.conf" 2>/dev/null | cut -d= -f2-)
    MODEL=$(grep '^MODEL=' "$CONF/pif.conf" 2>/dev/null | cut -d= -f2-)
    ui_print "  Fingerprint : ${FP:-unknown}"
    ui_print "  Spoofing as : ${MODEL:-unknown}"
else
    ui_print "  Certification: OFF (no pif.conf)"
fi
[ -f "$CONF/auto_update_fp" ] \
    && ui_print "  Auto-update FP: ON" \
    || ui_print "  Auto-update FP: OFF"

# ---------- Cloaking ----------
echo ""
ui_print "[*] Cloaking:"
MODE=$(grep '^mode' "$CONF/targets.conf" 2>/dev/null | cut -d= -f2- | tr -d ' ')
COUNT=$(grep -v '^#' "$CONF/targets.conf" 2>/dev/null | grep -v '^mode' | grep -v '^$' | wc -l | tr -d ' ')
ui_print "  Mode   : ${MODE:-whitelist}"
ui_print "  Targets: $COUNT app(s)"
[ -f "$CONF/auto_blacklist" ] \
    && ui_print "  Auto-scan: ON" \
    || ui_print "  Auto-scan: OFF"

# ---------- System ----------
echo ""
ui_print "[*] System:"
DL_GMS=$(magisk --denylist ls 2>/dev/null | grep -c 'com.google.android.gms')
[ "$DL_GMS" -gt 0 ] \
    && ui_print "  DenyList: WARNING — GMS listed (breaks hooks!)" \
    || ui_print "  DenyList: clean"
ui_print "  verifiedbootstate : $(getprop ro.boot.verifiedbootstate)"
ui_print "  flash.locked      : $(getprop ro.boot.flash.locked)"
ui_print "  vbmeta.device_state: $(getprop ro.boot.vbmeta.device_state)"
[ -f "$CONF/auto_update" ] \
    && ui_print "  Self-update: ON" \
    || ui_print "  Self-update: OFF"

# ---------- Maintenance ----------
echo ""
ui_print "[*] Maintenance:"
for pkg in com.google.android.gms com.android.vending; do
    magisk --denylist rm "$pkg" >/dev/null 2>&1
done
ui_print "  DenyList cleaned"

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
    ui_print "  App scan: $ADDED new"
fi

# ---------- Log ----------
echo ""
if [ -f "$CONF/manager.log" ]; then
    ui_print "[*] Recent log:"
    tail -5 "$CONF/manager.log" | while read -r line; do
        ui_print "  $line"
    done
fi

# ---------- Config hints ----------
echo ""
ui_print "[*] Config: $CONF/"
ui_print "  modules.conf  — managed modules registry"
ui_print "  targets.conf  — cloaked apps list"
ui_print "  pif.conf      — PI fingerprint"
ui_print "  Flag files: auto_update, auto_update_fp, auto_blacklist"

echo ""
ui_print "=============================="
ui_print "  Done"
ui_print "=============================="
