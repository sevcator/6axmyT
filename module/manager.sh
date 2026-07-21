#!/system/bin/sh
# 6axmyT Dependency Manager — download, install, and update PI stack modules
#
# Usage:
#   manager.sh status  — show module versions + check for updates
#   manager.sh update  — download and install available updates
#   manager.sh boot    — boot-time auto-management (silent, logs to file)

CONF="/data/adb/cloak"
MODDIR="${0%/*}"
REGISTRY="$CONF/modules.conf"
LOG_FILE="$CONF/manager.log"
TMP_DIR="/data/local/tmp/6axmyT"
CMD="${1:-status}"

log() { echo "$(date '+%H:%M:%S') [deps] $1" >> "$LOG_FILE" 2>/dev/null; }

fetch() {
    local url="$1" out="$2"
    if [ -n "$out" ]; then
        command -v curl >/dev/null 2>&1 && { curl -fsSL --connect-timeout 15 --max-time 120 -o "$out" "$url" 2>/dev/null; return $?; }
        command -v wget >/dev/null 2>&1 && { wget -q --timeout=120 -O "$out" "$url" 2>/dev/null; return $?; }
    else
        command -v curl >/dev/null 2>&1 && { curl -fsSL --connect-timeout 15 --max-time 60 "$url" 2>/dev/null; return $?; }
        command -v wget >/dev/null 2>&1 && { wget -qO- --timeout=60 "$url" 2>/dev/null; return $?; }
    fi
    return 1
}

parse_json() {
    local j="$1"
    UJ_VER=$(echo "$j"  | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' | head -1)
    UJ_CODE=$(echo "$j" | sed -n 's/.*"versionCode" *: *\([0-9]*\).*/\1/p' | head -1)
    UJ_ZIP=$(echo "$j"  | sed -n 's/.*"zipUrl" *: *"\([^"]*\)".*/\1/p' | head -1)
}

installed_ver() {
    local prop="/data/adb/modules/$1/module.prop"
    [ -f "$prop" ] || return 1
    INST_VER=$(grep '^version=' "$prop" | cut -d= -f2-)
    INST_CODE=$(grep '^versionCode=' "$prop" | cut -d= -f2-)
}

do_install() {
    local id="$1" url="$2" ver="$3"
    mkdir -p "$TMP_DIR"
    local zip="$TMP_DIR/${id}.zip"
    log "$id: downloading $ver"
    fetch "$url" "$zip" || { log "$id: download failed"; rm -f "$zip"; return 1; }
    [ -s "$zip" ]       || { log "$id: empty zip";       rm -f "$zip"; return 1; }
    magisk --install-module "$zip" >/dev/null 2>&1 \
        || { log "$id: magisk install failed"; rm -f "$zip"; return 1; }
    rm -f "$zip"
    log "$id: installed $ver (reboot to activate)"
    return 0
}

# --- main ---

[ ! -f "$REGISTRY" ] && {
    [ "$CMD" != "boot" ] && echo "  [!] modules.conf not found at $REGISTRY"
    log "modules.conf not found"
    exit 1
}

UPDATED=0 ERRORS=0 LATEST=0 SKIPPED=0 NEW=0

while IFS='|' read -r mid name url enabled _ || [ -n "$mid" ]; do
    case "$mid" in \#*|"") continue ;; esac
    mid=$(echo "$mid" | tr -d ' \r')
    name=$(echo "$name" | tr -d '\r')
    url=$(echo "$url" | tr -d ' \r')
    enabled=$(echo "$enabled" | tr -d ' \r')

    if [ "$enabled" != "1" ]; then
        [ "$CMD" != "boot" ] && echo "  [-] $name: disabled"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    json=$(fetch "$url")
    if [ -z "$json" ]; then
        [ "$CMD" != "boot" ] && echo "  [!] $name: network error"
        log "$mid: fetch failed"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    parse_json "$json"
    if [ -z "$UJ_CODE" ] || [ -z "$UJ_ZIP" ]; then
        [ "$CMD" != "boot" ] && echo "  [!] $name: bad updateJson"
        log "$mid: parse failed"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    if installed_ver "$mid"; then
        if [ "$UJ_CODE" -gt "$INST_CODE" ] 2>/dev/null; then
            if [ "$CMD" = "status" ]; then
                echo "  [^] $name: $INST_VER -> $UJ_VER available"
            else
                [ "$CMD" != "boot" ] && echo "  [^] $name: $INST_VER -> $UJ_VER"
                do_install "$mid" "$UJ_ZIP" "$UJ_VER" && {
                    UPDATED=$((UPDATED + 1))
                    [ "$CMD" != "boot" ] && echo "      updated!"
                }
            fi
        else
            [ "$CMD" != "boot" ] && echo "  [ok] $name: $INST_VER"
            LATEST=$((LATEST + 1))
        fi
    else
        if [ "$CMD" = "status" ]; then
            echo "  [+] $name: not installed ($UJ_VER available)"
        else
            [ "$CMD" != "boot" ] && echo "  [+] $name: installing $UJ_VER..."
            do_install "$mid" "$UJ_ZIP" "$UJ_VER" && {
                NEW=$((NEW + 1))
                [ "$CMD" != "boot" ] && echo "      installed!"
            }
        fi
    fi
done < "$REGISTRY"

TOTAL=$((UPDATED + NEW))
log "done: updated=$UPDATED new=$NEW latest=$LATEST errors=$ERRORS skipped=$SKIPPED"
[ $TOTAL -gt 0 ] && log "REBOOT REQUIRED for $TOTAL module(s)"

if [ "$CMD" != "boot" ]; then
    echo ""
    [ $TOTAL -gt 0 ] && echo "  [!] Reboot to activate $TOTAL module(s)"
    [ $ERRORS -gt 0 ] && echo "  [!] $ERRORS error(s) — see $CONF/manager.log"
    [ $TOTAL -eq 0 ] && [ $ERRORS -eq 0 ] && echo "  All modules up to date."
fi

rmdir "$TMP_DIR" 2>/dev/null
exit 0
