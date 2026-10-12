#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

launcher="$ROOT/bin/omarchy-launch-chromium"
installer="$ROOT/install/user/hardware/fix-hybrid-chromium.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

pci_path="$test_tmp/sys/bus/pci/devices"
drm_path="$test_tmp/sys/class/drm"
dri_path="$test_tmp/dev/dri"
driver_path="$test_tmp/usr/lib/dri"
mesa_egl="$test_tmp/usr/share/glvnd/egl_vendor.d/50_mesa.json"
stub_bin="$test_tmp/bin"
output="$test_tmp/chromium.log"

mkdir -p \
  "$pci_path/0000:00:02.0" \
  "$pci_path/0000:01:00.0" \
  "$drm_path/card0" \
  "$drm_path/card1" \
  "$drm_path/renderD128" \
  "$drm_path/renderD129" \
  "$dri_path" \
  "$driver_path" \
  "$(dirname "$mesa_egl")" \
  "$stub_bin"

printf '0x8086\n' >"$pci_path/0000:00:02.0/vendor"
printf '0\n' >"$pci_path/0000:00:02.0/boot_vga"
printf '0x10de\n' >"$pci_path/0000:01:00.0/vendor"
printf '1\n' >"$pci_path/0000:01:00.0/boot_vga"
ln -s "$pci_path/0000:01:00.0" "$drm_path/card0/device"
ln -s "$pci_path/0000:00:02.0" "$drm_path/card1/device"
ln -s "$pci_path/0000:01:00.0" "$drm_path/renderD128/device"
ln -s "$pci_path/0000:00:02.0" "$drm_path/renderD129/device"
touch "$dri_path/card0" "$dri_path/card1" "$dri_path/renderD128" "$dri_path/renderD129"
touch "$driver_path/i965_drv_video.so" "$mesa_egl"
ln -s "$dri_path/card1" "$test_tmp/gpu-intel"
ln -s "$dri_path/card0" "$test_tmp/gpu-nvidia"

cat >"$stub_bin/chromium" <<'SH'
#!/bin/bash

printf 'LIBVA_DRIVER_NAME=%s\n' "${LIBVA_DRIVER_NAME:-}"
printf '__EGL_VENDOR_LIBRARY_FILENAMES=%s\n' "${__EGL_VENDOR_LIBRARY_FILENAMES:-}"
printf 'DRI_PRIME=%s\n' "${DRI_PRIME:-}"
printf 'arg=%s\n' "$@"
SH
chmod +x "$stub_bin/chromium"

# Run the production launcher with Chromium replaced by a recorder. The sysfs,
# device, and driver roots are already injectable so this exercises its real
# selection logic rather than a test copy of it.
launcher_under_test="$test_tmp/omarchy-launch-chromium"
sed "s|exec /usr/bin/chromium|exec $stub_bin/chromium|" "$launcher" >"$launcher_under_test"
chmod +x "$launcher_under_test"

run_launcher() {
  env \
    -u LIBVA_DRIVER_NAME \
    -u __EGL_VENDOR_LIBRARY_FILENAMES \
    -u DRI_PRIME \
    OMARCHY_MESA_EGL="$mesa_egl" \
    OMARCHY_PCI_DEVICES_PATH="$pci_path" \
    OMARCHY_DRM_PATH="$drm_path" \
    OMARCHY_DRI_DEVICE_PATH="$dri_path" \
    OMARCHY_DRI_DRIVER_PATH="$driver_path" \
    TEST_OUTPUT="$output" \
    "$@" >"$output"
}

# MacBookPro11,3 layout: firmware and every connector belong to NVIDIA, while
# Aquamarine renders on Intel. Chromium must follow Aquamarine, not boot_vga.
run_launcher \
  AQ_DRM_DEVICES="$test_tmp/gpu-intel:$test_tmp/gpu-nvidia" \
  "$launcher_under_test" https://example.test

grep -Fxq 'LIBVA_DRIVER_NAME=i965' "$output" ||
  fail "the Chromium launcher selects Haswell's installed VA-API driver" "$(cat "$output")"
grep -Fxq "__EGL_VENDOR_LIBRARY_FILENAMES=$mesa_egl" "$output" ||
  fail "the Chromium launcher selects Mesa EGL for an Aquamarine iGPU" "$(cat "$output")"
grep -Fxq 'DRI_PRIME=pci-0000_00_02_0' "$output" ||
  fail "the Chromium launcher selects Aquamarine's PCI device" "$(cat "$output")"
grep -Fxq "arg=--render-node-override=$dri_path/renderD129" "$output" ||
  fail "the Chromium launcher selects Aquamarine's render node" "$(cat "$output")"
grep -Fxq 'arg=https://example.test' "$output" ||
  fail "the Chromium launcher preserves Chromium arguments" "$(cat "$output")"
pass "Chromium follows Aquamarine's Intel renderer on a muxed NVIDIA-display Mac"

# A caller's deliberate node selection has higher priority than the automatic
# one, while DRI_PRIME still keeps Mesa on Aquamarine's device.
run_launcher \
  AQ_DRM_DEVICES="$test_tmp/gpu-intel:$test_tmp/gpu-nvidia" \
  "$launcher_under_test" --render-node-override=/dev/dri/renderD140

grep -Fxq 'arg=--render-node-override=/dev/dri/renderD140' "$output" ||
  fail "the Chromium launcher preserves a caller render-node override" "$(cat "$output")"
(( $(grep -c '^arg=--render-node-override=' "$output") == 1 )) ||
  fail "the Chromium launcher does not duplicate a render-node override" "$(cat "$output")"
pass "Chromium preserves a caller's render-node override"

# With no compositor override, an NVIDIA boot/display GPU is intentional and
# the wrapper must not silently reroute an ordinary desktop to its spare iGPU.
run_launcher env -u AQ_DRM_DEVICES "$launcher_under_test"

grep -Fxq 'LIBVA_DRIVER_NAME=' "$output" ||
  fail "the Chromium launcher leaves VA-API alone on an NVIDIA display" "$(cat "$output")"
grep -Fxq '__EGL_VENDOR_LIBRARY_FILENAMES=' "$output" ||
  fail "the Chromium launcher leaves EGL alone on an NVIDIA display" "$(cat "$output")"
grep -Fxq 'DRI_PRIME=' "$output" ||
  fail "the Chromium launcher leaves Mesa GPU selection alone on an NVIDIA display" "$(cat "$output")"
! grep -q '^arg=--render-node-override=' "$output" ||
  fail "the Chromium launcher leaves the render node alone on an NVIDIA display" "$(cat "$output")"
pass "Chromium stays on an NVIDIA display when Aquamarine has no override"

# The pre-existing path remains valid when the iGPU really is boot_vga.
printf '1\n' >"$pci_path/0000:00:02.0/boot_vga"
printf '0\n' >"$pci_path/0000:01:00.0/boot_vga"
run_launcher env -u AQ_DRM_DEVICES "$launcher_under_test"

grep -Fxq 'LIBVA_DRIVER_NAME=i965' "$output" ||
  fail "the Chromium launcher selects VA-API for an iGPU display" "$(cat "$output")"
grep -Fxq "__EGL_VENDOR_LIBRARY_FILENAMES=$mesa_egl" "$output" ||
  fail "the Chromium launcher selects Mesa EGL for an iGPU display" "$(cat "$output")"
grep -Fxq 'DRI_PRIME=' "$output" ||
  fail "the Chromium launcher needs no DRI override for an iGPU display" "$(cat "$output")"
! grep -q '^arg=--render-node-override=' "$output" ||
  fail "the Chromium launcher needs no node override for an iGPU display" "$(cat "$output")"
pass "Chromium still follows an integrated boot/display GPU"

# Exercise the install gate separately. Both hardware helpers are stubbed: the
# interesting case is NVIDIA owning the display while AQ_DRM_DEVICES says the
# compositor's primary renderer is Intel.
cat >"$stub_bin/omarchy-hw-nvidia" <<'SH'
#!/bin/bash
exit "${NVIDIA_PRESENT:-1}"
SH
cat >"$stub_bin/omarchy-hw-nvidia-display" <<'SH'
#!/bin/bash
exit "${NVIDIA_DISPLAY:-1}"
SH
chmod +x "$stub_bin/omarchy-hw-nvidia" "$stub_bin/omarchy-hw-nvidia-display"

stock_desktop="$test_tmp/usr/share/applications/chromium.desktop"
omarchy_path="$test_tmp/omarchy"
test_home="$test_tmp/home"
mkdir -p "$(dirname "$stock_desktop")" "$omarchy_path/bin" "$test_home"
cp "$launcher" "$omarchy_path/bin/omarchy-launch-chromium"
cat >"$stock_desktop" <<'DESKTOP'
[Desktop Entry]
Exec=/usr/bin/chromium %U
Actions=incognito;

[Desktop Action incognito]
Exec=chromium --incognito
DESKTOP

run_installer() {
  HOME="$test_home" \
    PATH="$stub_bin:$PATH" \
    NVIDIA_PRESENT=0 \
    NVIDIA_DISPLAY=0 \
    OMARCHY_PATH="$omarchy_path" \
    OMARCHY_STOCK_CHROMIUM_DESKTOP="$stock_desktop" \
    OMARCHY_MESA_EGL="$mesa_egl" \
    OMARCHY_DRM_PATH="$drm_path" \
    "$@"
}

user_desktop="$test_home/.local/share/applications/chromium.desktop"
run_installer env -u AQ_DRM_DEVICES bash "$installer"
[[ ! -e $user_desktop ]] ||
  fail "the Chromium override is not installed for an NVIDIA display without an AQ override"
pass "the installer leaves an ordinary NVIDIA display alone"

run_installer env \
  AQ_DRM_DEVICES="$test_tmp/gpu-intel:$test_tmp/gpu-nvidia" \
  bash "$installer"
[[ -f $user_desktop ]] ||
  fail "the Chromium override is installed when Aquamarine renders on Intel"
(( $(grep -c "^Exec=$omarchy_path/bin/omarchy-launch-chromium" "$user_desktop") == 2 )) ||
  fail "every Chromium desktop action uses the wrapper" "$(cat "$user_desktop")"
pass "the installer covers an Aquamarine iGPU behind an NVIDIA display"
