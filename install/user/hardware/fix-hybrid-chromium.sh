# Work around cross-GPU EGL / DMA-BUF incompatibility on hybrid NVIDIA + iGPU laptops.
#
# Usually the integrated GPU drives the display. Muxed Intel Macs are the
# exception: NVIDIA owns the connectors and boot_vga while AQ_DRM_DEVICES makes
# Intel the compositor's primary renderer. In both layouts Chromium must render
# on the same GPU as Hyprland or cross-GPU buffer handling can produce black
# screens, flicker, Nouveau command errors, and GPU-process crashes.
#
# Fix: for Chromium only, route launches through omarchy-launch-chromium, which
# follows AQ_DRM_DEVICES before boot_vga, forces Mesa EGL, selects the matching
# render node and VA-API driver, and leaves system-wide EGL alone.
#
# See: https://github.com/basecamp/omarchy/issues/4901

STOCK_DESKTOP="${OMARCHY_STOCK_CHROMIUM_DESKTOP:-/usr/share/applications/chromium.desktop}"
USER_DESKTOP="$HOME/.local/share/applications/chromium.desktop"
MESA_EGL="${OMARCHY_MESA_EGL:-/usr/share/glvnd/egl_vendor.d/50_mesa.json}"
WRAPPER="$OMARCHY_PATH/bin/omarchy-launch-chromium"
drm_path="${OMARCHY_DRM_PATH:-/sys/class/drm}"

# Nothing to override, required bits missing, or user already has an override
[[ -f $STOCK_DESKTOP ]] || exit 0
[[ -f $MESA_EGL ]] || exit 0
[[ -x $WRAPPER ]] || exit 0
[[ -f $USER_DESKTOP ]] && exit 0

# Only act when NVIDIA is present and the integrated GPU either owns the
# display or is Aquamarine's explicitly configured primary renderer. A desktop
# with an iGPU beside an NVIDIA display card and no override stays untouched.
omarchy-hw-nvidia || exit 0
if omarchy-hw-nvidia-display; then
  [[ -n ${AQ_DRM_DEVICES:-} ]] || exit 0
  aq_primary=${AQ_DRM_DEVICES%%:*}
  aq_drm_name=$(basename "$(readlink -f "$aq_primary")")
  aq_vendor_file="$drm_path/$aq_drm_name/device/vendor"
  [[ -f $aq_vendor_file ]] || exit 0
  case $(< "$aq_vendor_file") in
    0x8086 | 0x1002) ;;
    *) exit 0 ;;
  esac
fi

mkdir -p "$(dirname "$USER_DESKTOP")"

# Route every Exec= line through the wrapper so Desktop Actions (new-window,
# incognito) get the fix too. The first token is kept a single command, so
# callers that parse Exec= (like bin/omarchy-launch-browser) keep working.
# Match both Exec=/usr/bin/chromium and bare Exec=chromium, followed by a
# space or end-of-line so we don't accidentally match chromium-browser or
# similar variants.
TMP_DESKTOP=$(mktemp "${USER_DESKTOP}.tmp.XXXXXX") || exit 1
trap 'rm -f "$TMP_DESKTOP"' EXIT

sed -E "s@^Exec=(/usr/bin/chromium|chromium)( |\$)@Exec=$WRAPPER\2@" \
  "$STOCK_DESKTOP" >"$TMP_DESKTOP"

# Verify the substitution actually happened; otherwise we'd leave a dead
# override that blocks future runs (the script exits early if $USER_DESKTOP
# exists). If the stock .desktop format has drifted, bail out cleanly.
if ! grep -q "^Exec=$WRAPPER" "$TMP_DESKTOP"; then
  exit 0
fi

mv "$TMP_DESKTOP" "$USER_DESKTOP"
trap - EXIT
