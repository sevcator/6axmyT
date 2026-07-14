#!/system/bin/sh
# 6axmyT — Google Play certification, made automatic.
#
# The Zygisk library (spoof.cpp) already rewrites android.os.Build inside every
# GMS/DroidGuard process the moment it spawns, so on a clean boot the check-in
# and integrity code already read the certified profile. This late_start
# service only does the two things an in-process hook cannot do by itself:
#
#   1. keep GMS + Play Store OFF the Magisk DenyList — a denylisted process is
#      never injected by Zygisk, so the certification hook would silently never
#      run inside it;
#   2. on the first boot after (re)install, refresh Play's cached certification
#      once, so the "Device is certified" verdict flips over on its own without
#      you having to clear GMS/Play Store data by hand. Login is preserved
#      (force-stop, not `pm clear`).

MODDIR=${0%/*}
CONF=/data/adb/cloak

# Wait for the framework, then give GMS a moment to come up.
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 30

# 1) GMS + Play Store must not be denylisted, or the cert hook never reaches them.
for p in com.google.android.gms com.android.vending; do
  magisk --denylist rm "$p" >/dev/null 2>&1
done

# 2) One-time certification refresh (only if pif.conf is present = feature on).
#    A stamp file makes this run just once after install; a normal boot after
#    that is already certified and we never touch Play again.
STAMP="$CONF/.certified"
if [ -f "$CONF/pif.conf" ] && [ ! -f "$STAMP" ]; then
  # Respawn GMS + Play Store so they come back already-spoofed and re-check-in
  # with Google. force-stop keeps the user's Google account/login intact.
  am force-stop com.google.android.gms  >/dev/null 2>&1
  am force-stop com.android.vending     >/dev/null 2>&1
  # Best-effort nudge for an immediate Google Services check-in so the server
  # re-evaluates certification with the certified fingerprint right away.
  am broadcast -a android.server.checkin.CHECKIN          >/dev/null 2>&1
  am broadcast -a com.google.android.gms.CHECKIN_NOW      >/dev/null 2>&1
  touch "$STAMP"
fi
