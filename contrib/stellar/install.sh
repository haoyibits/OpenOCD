#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Install openocd-stellar (OpenOCD for ST Stellar with StellarLINK and the
# SR6P6 fixes) from the GitHub releases of haoyibits/OpenOCD:
#
#   curl -fsSL https://github.com/haoyibits/OpenOCD/releases/latest/download/install.sh | sh
#
# The archive (bin/openocd and its scripts) goes to OPENOCD_STELLAR_PREFIX,
# a link named openocd-stellar to OPENOCD_STELLAR_BIN_DIR. OpenOCD finds its
# scripts relative to the executable, so nothing else is configured. On
# Linux the script prints the udev rules to install for StellarLINK (that
# needs root, which this script never uses).
#
# Environment:
#   OPENOCD_STELLAR_VERSION   release tag (default: latest), e.g. v0.12.0-stellar.2
#   OPENOCD_STELLAR_PREFIX    install directory (default: ~/.local/lib/openocd-stellar)
#   OPENOCD_STELLAR_BIN_DIR   directory of the openocd-stellar link (default: ~/.local/bin)
#   OPENOCD_STELLAR_REPO      GitHub repository (default: haoyibits/OpenOCD)
#   OPENOCD_STELLAR_BASE_URL  download from this URL instead of GitHub (mirrors, testing)
set -eu

repo="${OPENOCD_STELLAR_REPO:-haoyibits/OpenOCD}"
version="${OPENOCD_STELLAR_VERSION:-latest}"
prefix="${OPENOCD_STELLAR_PREFIX:-$HOME/.local/lib/openocd-stellar}"
bin_dir="${OPENOCD_STELLAR_BIN_DIR:-$HOME/.local/bin}"

fail() {
    echo "install.sh: $*" >&2
    exit 1
}

case "$(uname -s)" in
    Darwin) os=apple-darwin ;;
    Linux) os=unknown-linux-musl ;;
    *) fail "unsupported operating system: $(uname -s)" ;;
esac
case "$(uname -m)" in
    arm64 | aarch64) arch=aarch64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
esac
[ "$os-$arch" = apple-darwin-x86_64 ] && fail "Intel Macs are not supported; use an Apple silicon Mac"
target="$arch-$os"
name="openocd-stellar-$target"
asset="$name.tar.gz"
if [ -n "${OPENOCD_STELLAR_BASE_URL:-}" ]; then
    base="$OPENOCD_STELLAR_BASE_URL"
elif [ "$version" = latest ]; then
    base="https://github.com/$repo/releases/latest/download"
else
    base="https://github.com/$repo/releases/download/$version"
fi

command -v curl >/dev/null 2>&1 || fail "curl is required"
case "$prefix" in
    /*) ;;
    *) fail "OPENOCD_STELLAR_PREFIX must be an absolute path: $prefix" ;;
esac
parent="$(dirname "$prefix")"
mkdir -p "$parent" "$bin_dir"
# Unpacked next to the install directory, so that the final move is a rename.
temporary="$(mktemp -d "$parent/.openocd-stellar.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT INT TERM

echo "Downloading $asset ($version)"
curl -fsSL "$base/$asset" -o "$temporary/$asset" || fail "cannot download $base/$asset"
curl -fsSL "$base/$asset.sha256" -o "$temporary/$asset.sha256" || fail "cannot download the checksum"

expected="$(cut -d ' ' -f 1 "$temporary/$asset.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$temporary/$asset" | cut -d ' ' -f 1)"
else
    actual="$(shasum -a 256 "$temporary/$asset" | cut -d ' ' -f 1)"
fi
[ "$expected" = "$actual" ] || fail "checksum mismatch for $asset"

tar -xzf "$temporary/$asset" -C "$temporary"
new="$temporary/$name"
[ -x "$new/bin/openocd" ] || fail "$asset has no bin/openocd"
if [ "$os" = apple-darwin ]; then
    xattr -dr com.apple.quarantine "$new" 2>/dev/null || true
fi
"$new/bin/openocd" --version >/dev/null 2>&1 || fail "the downloaded openocd does not run on this machine"

if [ -e "$prefix" ]; then
    [ -x "$prefix/bin/openocd" ] ||
        fail "$prefix exists and is not an openocd-stellar installation; remove it or set OPENOCD_STELLAR_PREFIX"
    mv "$prefix" "$temporary/previous"
fi
if ! mv "$new" "$prefix"; then
    [ -e "$temporary/previous" ] && mv "$temporary/previous" "$prefix"
    fail "cannot move the new installation to $prefix"
fi
ln -sf "$prefix/bin/openocd" "$bin_dir/openocd-stellar"

version_line="$("$bin_dir/openocd-stellar" --version 2>&1 | head -n 1)"
echo "Installed $version_line"
echo "  $prefix"
echo "  $bin_dir/openocd-stellar -> $prefix/bin/openocd"

case ":$PATH:" in
    *":$bin_dir:"*)
        found="$(command -v openocd-stellar 2>/dev/null || true)"
        if [ -n "$found" ] && [ "$found" != "$bin_dir/openocd-stellar" ]; then
            echo "Note: openocd-stellar on PATH is $found, which comes before $bin_dir"
        fi
        ;;
    *) echo "Note: $bin_dir is not on PATH; add it to your shell profile, e.g. export PATH=\"$bin_dir:\$PATH\"" ;;
esac

if [ "$os" = unknown-linux-musl ]; then
    rules="$prefix/share/openocd/contrib/60-openocd.rules"
    if ! grep -qs 'idProduct}=="0499"' /etc/udev/rules.d/*.rules /lib/udev/rules.d/*.rules /usr/lib/udev/rules.d/*.rules; then
        echo
        echo "To use StellarLINK without root, install the udev rules once:"
        echo "  sudo cp \"$rules\" /etc/udev/rules.d/"
        echo "  sudo udevadm control --reload-rules && sudo udevadm trigger"
        echo "Without a local desktop session (e.g. over SSH) also join the plugdev group:"
        echo "  sudo usermod -aG plugdev \"\$USER\"   (then log in again)"
    fi
fi
