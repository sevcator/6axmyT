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
for f in targets.conf props.conf pif.conf; do
  if [ -f "/data/adb/cloak/$f" ]; then
    ui_print "- Keeping existing /data/adb/cloak/$f"
  else
    cp "$MODPATH/$f" "/data/adb/cloak/$f"
    ui_print "- Installed default /data/adb/cloak/$f"
  fi
  set_perm "/data/adb/cloak/$f" 0 0 0644
done

ui_print "- Edit /data/adb/cloak/targets.conf to choose which apps are cloaked"
ui_print "- Done. Reboot to activate."
