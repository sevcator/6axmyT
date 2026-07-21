# Cloak installer
SKIPUNZIP=0

# Zygisk is required. ZYGISK_ENABLED is only exported by the Magisk app flasher,
# not by `magisk --install-module`, so fall back to the stored setting and to
# the presence of a standalone Zygisk implementation.
ZYG_DB="$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk'" 2>/dev/null | sed 's/.*=//')"
if [ "$ZYGISK_ENABLED" = "0" ] || { [ "$ZYGISK_ENABLED" != "1" ] && [ "$ZYG_DB" = "0" ] && [ ! -d /data/adb/modules/zygisksu ] && [ ! -d /data/adb/modules/rezygisk ]; }; then
  ui_print "! Zygisk appears disabled."
  ui_print "! Enable Zygisk in Magisk (or install ZygiskNext/ReZygisk) and reflash."
  abort   "! Aborting."
fi

ABI="$(getprop ro.product.cpu.abi)"
ui_print "- Device ABI: $ABI"

# The libcloak.so files are shipped under zygisk/<abi>.so per Zygisk convention.
ui_print "- Installing Zygisk library"
set_perm_recursive "$MODPATH/zygisk" 0 0 0755 0644

# First-run config: install defaults, never clobber existing ones
mkdir -p /data/adb/cloak
for f in targets.conf props.conf pif.conf modules.conf; do
  if [ -f "/data/adb/cloak/$f" ]; then
    ui_print "- Keeping existing /data/adb/cloak/$f"
  else
    cp "$MODPATH/$f" "/data/adb/cloak/$f"
    ui_print "- Installed default /data/adb/cloak/$f"
  fi
  set_perm "/data/adb/cloak/$f" 0 0 0644
done

# Drop the certification stamp so the boot service refreshes Play's cached
# "Device is certified" verdict once after this (re)install.
rm -f /data/adb/cloak/.certified

# Ensure GMS is not on the DenyList (blocks Zygisk injection = no cert hook)
magisk --denylist rm com.google.android.gms >/dev/null 2>&1
magisk --denylist rm com.android.vending >/dev/null 2>&1

ui_print ""
ui_print ""
ui_print "- Module manager will auto-install dependencies on first boot"
ui_print "- Edit /data/adb/cloak/modules.conf to manage PI stack modules"
ui_print "- Edit /data/adb/cloak/targets.conf to choose cloaked apps"
ui_print "- Enable features with flag files in /data/adb/cloak/:"
ui_print "    touch /data/adb/cloak/auto_update_fp  — auto-update fingerprint"
ui_print "    touch /data/adb/cloak/auto_blacklist   — auto-detect banking apps"
ui_print "    touch /data/adb/cloak/auto_update      — self-update from GitHub"
ui_print "- Tap the action button in Magisk for dashboard + manual updates"
ui_print "- Done. Reboot to activate."
