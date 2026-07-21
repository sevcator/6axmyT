#!/system/bin/sh
# 6axmyT Manager — late_start service
# Runs once per boot after framework is up. Handles:
#   1. DenyList maintenance (GMS must stay OFF it)
#   2. One-time Play certification refresh after install
#   3. Auto-update fingerprint from pifsync
#   4. Auto-detect banking/payment apps and add to targets.conf
#   5. Dependency module management (Shamiko, TEESimulator, PIF)
#   6. Self-update from GitHub releases

MODDIR="${0%/*}"
CONF="/data/adb/cloak"
LOG_TAG="6axmyT"
LOG_FILE="$CONF/manager.log"

log() { echo "$(date '+%H:%M:%S') $1" >> "$LOG_FILE" 2>/dev/null; }
truncate_log() { [ -f "$LOG_FILE" ] && tail -100 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"; }

# Wait for boot + network
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 15

mkdir -p "$CONF"
truncate_log
log "=== boot service start ==="

# ---------- 1. DenyList maintenance ----------
# GMS MUST NOT be denylisted or Zygisk won't inject our hook into it.
for pkg in com.google.android.gms com.android.vending; do
    magisk --denylist rm "$pkg" >/dev/null 2>&1
done
log "denylist: cleaned GMS/vending"

# ---------- 2. One-time certification refresh ----------
STAMP="$CONF/.certified"
if [ -f "$CONF/pif.conf" ] && [ ! -f "$STAMP" ]; then
    log "cert: first boot after install, refreshing Play certification"
    am force-stop com.google.android.gms  >/dev/null 2>&1
    am force-stop com.android.vending     >/dev/null 2>&1
    sleep 5
    am broadcast -a android.server.checkin.CHECKIN     >/dev/null 2>&1
    am broadcast -a com.google.android.gms.CHECKIN_NOW >/dev/null 2>&1
    touch "$STAMP"
    log "cert: refresh done"
fi

# ---------- 3. Auto-update fingerprint ----------
update_fingerprint() {
    [ ! -f "$CONF/auto_update_fp" ] && return
    log "fp: checking pifsync for fresh fingerprint"

    local TMP="$CONF/.pif_new.tmp"
    local URL="https://raw.githubusercontent.com/ponces/pifsync/main/pif.json"

    # Try multiple download methods (busybox wget, curl, toybox)
    local JSON=""
    if command -v curl >/dev/null 2>&1; then
        JSON=$(curl -fsSL --connect-timeout 10 --max-time 30 "$URL" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        JSON=$(wget -qO- --timeout=30 "$URL" 2>/dev/null)
    fi

    [ -z "$JSON" ] && { log "fp: download failed (no network?)"; return; }

    # Parse JSON into key=value (no jq on most Android devices).
    # Expected format: {"FINGERPRINT":"...", "MODEL":"...", ...}
    local NEW_FP=$(echo "$JSON" | sed -n 's/.*"FINGERPRINT" *: *"\([^"]*\)".*/\1/p')
    [ -z "$NEW_FP" ] && { log "fp: parse failed"; return; }

    local CUR_FP=$(grep '^FINGERPRINT=' "$CONF/pif.conf" 2>/dev/null | cut -d= -f2-)
    if [ "$NEW_FP" = "$CUR_FP" ]; then
        log "fp: already up to date ($NEW_FP)"
        return
    fi

    # Build new pif.conf from JSON
    {
        echo "# Auto-updated by 6axmyT manager"
        echo "# $(date '+%Y-%m-%d %H:%M')"
        echo ""
        for key in FINGERPRINT BRAND DEVICE MANUFACTURER MODEL PRODUCT ID TAGS TYPE SECURITY_PATCH DEVICE_INITIAL_SDK_INT; do
            local val=$(echo "$JSON" | sed -n "s/.*\"$key\" *: *\"\{0,1\}\([^\",$}]*\).*/\1/p" | head -1)
            [ -n "$val" ] && echo "$key=$val"
        done
    } > "$TMP"

    # Validate: must have FINGERPRINT line
    if grep -q '^FINGERPRINT=' "$TMP"; then
        cp "$CONF/pif.conf" "$CONF/pif.conf.bak" 2>/dev/null
        mv "$TMP" "$CONF/pif.conf"
        chmod 644 "$CONF/pif.conf"
        rm -f "$STAMP"  # force cert refresh on next boot
        log "fp: updated to $NEW_FP"
        # Force-stop GMS so it respawns with new fingerprint
        am force-stop com.google.android.gms >/dev/null 2>&1
    else
        rm -f "$TMP"
        log "fp: validation failed, keeping current"
    fi
}

# ---------- 4. Auto-detect banking/payment apps ----------
KNOWN_APPS="
ru.nspk.mirpay
ru.nspk.sbpay
ru.sberbankmobile
com.idamob.tinkoff.android
ru.vtb24.mobilebanking.android
ru.alfabank.mobile.android
ru.gazprombank.android.mobilebank.app
ru.raiffeisennews
ru.rosbank.android
ru.mkb.mobile
ru.rshb.dbo
ru.letobank.Prometheus
com.openbank
ru.sovcombank.halva
com.sovcombank.club
ru.yoo.money
com.yandex.bank
ru.ozon.fintech.finance
com.qiwi.wallet
ru.psbank.online
ru.bpc.mobilebank
com.bspb.android
ru.mcb.android
ru.homecredit.mycredit
com.ubrir.app
ru.absolutbank.mobile
com.tcsbank.business
ru.sberbank.sberbankid
com.google.android.apps.walletnfcrel
com.samsung.android.spay
com.axlebolt.standoff2
com.pubg.krmobile
com.garena.game.ffrefire
com.dts.freefireth
com.riotgames.league.wildrift
"

auto_scan_apps() {
    [ ! -f "$CONF/auto_blacklist" ] && return
    log "scan: checking installed apps against known list"

    local TARGETS="$CONF/targets.conf"
    [ ! -f "$TARGETS" ] && return

    local ADDED=0
    local INSTALLED
    INSTALLED=$(pm list packages 2>/dev/null | sed 's/package://')

    for app in $KNOWN_APPS; do
        app=$(echo "$app" | tr -d '\r\n ')
        [ -z "$app" ] && continue
        # Check if installed AND not already in targets.conf
        if echo "$INSTALLED" | grep -qx "$app" 2>/dev/null; then
            if ! grep -qx "$app" "$TARGETS" 2>/dev/null; then
                echo "$app" >> "$TARGETS"
                ADDED=$((ADDED + 1))
                log "scan: added $app"
            fi
        fi
    done
    [ $ADDED -gt 0 ] && log "scan: added $ADDED new apps to targets.conf"
    [ $ADDED -eq 0 ] && log "scan: no new apps found"
}

# ---------- 5. Dependency module management ----------
manage_deps() {
    [ -f "$CONF/modules.conf" ] || return
    log "deps: starting module check"
    sh "$MODDIR/manager.sh" boot
}
manage_deps

# ---------- 6. Self-update ----------
self_update() {
    [ ! -f "$CONF/auto_update" ] && return
    log "update: checking GitHub for new release"

    local CUR_VER=$(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
    [ -z "$CUR_VER" ] && return

    local API_URL="https://api.github.com/repos/sevcator/6axmyT/releases/latest"
    local RELEASE=""
    if command -v curl >/dev/null 2>&1; then
        RELEASE=$(curl -fsSL --connect-timeout 10 --max-time 30 "$API_URL" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        RELEASE=$(wget -qO- --timeout=30 "$API_URL" 2>/dev/null)
    fi
    [ -z "$RELEASE" ] && { log "update: download failed"; return; }

    local TAG=$(echo "$RELEASE" | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$TAG" ] && { log "update: parse failed"; return; }

    # Parse version: v1.2.3 -> 10203
    local VN="${TAG#v}"
    local A=$(echo "$VN" | cut -d. -f1)
    local B=$(echo "$VN" | cut -d. -f2)
    local C=$(echo "$VN" | cut -d. -f3)
    local NEW_VER=$(( ${A:-0} * 10000 + ${B:-0} * 100 + ${C:-0} ))

    if [ "$NEW_VER" -le "$CUR_VER" ] 2>/dev/null; then
        log "update: already latest (${TAG}, code=${CUR_VER})"
        return
    fi

    log "update: new version $TAG available (${NEW_VER} > ${CUR_VER})"

    local ZIP_URL=$(echo "$RELEASE" | sed -n 's/.*"browser_download_url" *: *"\([^"]*\.zip\)".*/\1/p' | head -1)
    [ -z "$ZIP_URL" ] && { log "update: no zip URL found"; return; }

    local TMP="/data/local/tmp/6axmyT-update.zip"
    local DL_OK=""
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 10 --max-time 120 -o "$TMP" "$ZIP_URL" 2>/dev/null && DL_OK=1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=120 -O "$TMP" "$ZIP_URL" 2>/dev/null && DL_OK=1
    fi

    if [ -n "$DL_OK" ] && [ -f "$TMP" ]; then
        magisk --install-module "$TMP" >/dev/null 2>&1
        rm -f "$TMP"
        log "update: installed $TAG, will activate on next reboot"
    else
        rm -f "$TMP"
        log "update: download failed"
    fi
}

# ---------- Run all tasks ----------
update_fingerprint
auto_scan_apps
self_update
log "=== boot service done ==="
