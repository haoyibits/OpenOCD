#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build a relocatable openocd-stellar archive for one target:
#
#   contrib/stellar/build.sh <target> <out-dir>
#
# <target> is aarch64-apple-darwin, x86_64-unknown-linux-musl or
# aarch64-unknown-linux-musl. Run it from the top of the source tree with the
# jimtcl submodule checked out; on Linux inside Alpine (musl), so that the
# executable is fully static. libusb and libftdi are built from pinned
# sources and linked statically; no other library is used (StellarLINK is an
# FTDI adapter). The archive holds bin/openocd, share/openocd (the scripts,
# found relative to the executable, and the Linux udev rules) and the
# licences. <out-dir> receives openocd-stellar-<target>.tar.gz and its
# .sha256.
set -eu

LIBUSB_VERSION=1.0.29
LIBUSB_SHA256=5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85
LIBUSB_URL=https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2
LIBFTDI_VERSION=1.5
LIBFTDI_SHA256=7c7091e9c86196148bd41177b4590dccb1510bfe6cea5bf7407ff194482eb049
LIBFTDI_URL=https://www.intra2net.com/en/developer/libftdi/download/libftdi1-$LIBFTDI_VERSION.tar.bz2

fail() {
    echo "build.sh: $*" >&2
    exit 1
}

[ $# -eq 2 ] || fail "usage: contrib/stellar/build.sh <target> <out-dir>"
target=$1
case "$target" in
    *-apple-darwin) os=darwin ;;
    *-linux-musl) os=linux ;;
    *) fail "unsupported target: $target" ;;
esac
[ -f src/openocd.c ] || fail "run this from the top of the OpenOCD source tree"
[ -f jimtcl/configure ] || fail "the jimtcl submodule is missing (git submodule update --init jimtcl)"
# OpenOCD is configured and built in the source tree, which must not hold
# another configuration.
[ ! -f config.status ] || fail "the source tree is already configured; use a fresh checkout or make distclean"
mkdir -p "$2"
out=$(cd "$2" && pwd)
source_dir=$(pwd)
work=${STELLAR_BUILD_DIR:-$source_dir/build-stellar}
deps=$work/deps
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

# fetch <url> <sha256>: download into $work/downloads (kept between runs)
# and unpack into $work/src.
fetch() {
    file=$work/downloads/${1##*/}
    mkdir -p "$work/downloads"
    if [ ! -f "$file" ]; then
        curl -fsSL "$1" -o "$file.part" || fail "cannot download $1"
        mv "$file.part" "$file"
    fi
    [ "$(sha256 "$file")" = "$2" ] || fail "checksum mismatch for $file"
    tar -xjf "$file" -C "$work/src"
}

rm -rf "$work/src" "$work/stage" "$deps"
mkdir -p "$work/src" "$deps"

if [ "$os" = darwin ]; then
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
fi

echo "== libusb $LIBUSB_VERSION"
fetch "$LIBUSB_URL" "$LIBUSB_SHA256"
(
    cd "$work/src/libusb-$LIBUSB_VERSION"
    # Without udev, libusb enumerates through sysfs and hotplugs through
    # netlink, which is all OpenOCD needs and keeps the build static.
    extra=
    [ "$os" = linux ] && extra=--disable-udev
    ./configure --prefix="$deps" --enable-static --disable-shared \
        --disable-examples-build --disable-tests-build $extra
    make -j"$jobs" install
)

echo "== libftdi1 $LIBFTDI_VERSION"
fetch "$LIBFTDI_URL" "$LIBFTDI_SHA256"
mkdir -p "$work/src/libftdi-build"
(
    cd "$work/src/libftdi-build"
    # libftdi 1.5 asks for CMake 2.6, which CMake 4 refuses without the
    # policy minimum. Its install target also links a shared library, which
    # fails against the static libusb, so only the static library is built
    # and installed by hand, with the pkg-config file libftdi would write.
    PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig" cmake "$work/src/libftdi1-$LIBFTDI_VERSION" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$deps" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$deps" \
        -DSTATICLIBS=ON -DFTDIPP=OFF -DFTDI_EEPROM=OFF -DEXAMPLES=OFF \
        -DPYTHON_BINDINGS=OFF -DLINK_PYTHON_LIBRARY=OFF -DDOCUMENTATION=OFF \
        -DBUILD_TESTS=OFF
    make -j"$jobs" ftdi1-static
    mkdir -p "$deps/include/libftdi1"
    cp src/libftdi1.a "$deps/lib/"
    cp "$work/src/libftdi1-$LIBFTDI_VERSION/src/ftdi.h" "$deps/include/libftdi1/"
    cat > "$deps/lib/pkgconfig/libftdi1.pc" <<EOF
prefix=$deps
libdir=\${prefix}/lib
includedir=\${prefix}/include/libftdi1

Name: libftdi1
Description: Library to program and control the FTDI USB controller
Requires: libusb-1.0
Version: $LIBFTDI_VERSION
Libs: -L\${libdir} -lftdi1
Cflags: -I\${includedir}
EOF
)

echo "== openocd"
[ -x configure ] || ./bootstrap nosubmodule
prefix=/opt/openocd-stellar
(
    # libtool drops libusb's -Wl,-framework,… flags when it passes them on
    # through libopenocd.la, so the frameworks go to every link on macOS.
    case "$os" in
        linux) ldflags=-static ;;
        darwin) ldflags="-framework IOKit -framework CoreFoundation -framework Security" ;;
    esac
    # pkg-config sees only the libraries built above, so nothing from the
    # host (Homebrew, distribution packages) is picked up.
    PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig" PKG_CONFIG="pkg-config --static" \
        LDFLAGS="$ldflags" \
        ./configure --prefix="$prefix" \
        --enable-ftdi --enable-dummy --without-capstone --disable-linuxgpiod \
        --disable-jlink --disable-werror \
        --disable-doxygen-html --disable-doxygen-pdf
    make -j"$jobs"
    make install-strip DESTDIR="$work/stage"
)

name=openocd-stellar-$target
package=$work/package/$name
rm -rf "$work/package"
mkdir -p "$package/bin" "$package/share/openocd/contrib" "$package/licenses"
cp "$work/stage$prefix/bin/openocd" "$package/bin/openocd"
cp -R "$work/stage$prefix/share/openocd/." "$package/share/openocd/"
cp "$source_dir/contrib/60-openocd.rules" "$package/share/openocd/contrib/"
cp "$source_dir/COPYING" "$package/COPYING"
cp -R "$source_dir/LICENSES" "$package/licenses/openocd"
cp "$work/src/libusb-$LIBUSB_VERSION/COPYING" "$package/licenses/libusb-COPYING"
cp "$work/src/libftdi1-$LIBFTDI_VERSION/COPYING.LIB" "$package/licenses/libftdi-COPYING.LIB"
revision=$(git -C "$source_dir" describe --tags --always 2>/dev/null || echo unknown)
cat > "$package/SOURCES" <<EOF
openocd-stellar ($target) is OpenOCD (GPL-2.0-or-later) from
https://github.com/haoyibits/OpenOCD, branch openocd-automotive-mcu-r3,
revision $revision, with jimtcl from its submodule. It is statically linked
with:
  libusb $LIBUSB_VERSION (LGPL-2.1-or-later)  $LIBUSB_URL
  libftdi1 $LIBFTDI_VERSION (LGPL-2.1-only)    $LIBFTDI_URL
The release that ships this archive also carries these two source archives.
contrib/stellar/build.sh in the OpenOCD source rebuilds it.
EOF

echo "== checks"
exe=$package/bin/openocd
if [ "$os" = linux ]; then
    # A static executable has no program interpreter.
    if command -v readelf >/dev/null 2>&1 && readelf -l "$exe" | grep -q INTERP; then
        fail "$exe is dynamically linked"
    fi
else
    others=$(otool -L "$exe" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/' || true)
    [ -z "$others" ] || fail "$exe links libraries outside the system: $others"
fi
"$exe" --version 2>&1 | head -1
# The SR6P6 target through the dummy adapter, from a copy in another place
# (scripts must be found relative to the executable), stopping before init.
check=$work/check
rm -rf "$check"
mkdir -p "$check/link"
cp -R "$package" "$check/moved"
ln -s "$check/moved/bin/openocd" "$check/link/openocd-stellar"
output=$("$check/link/openocd-stellar" -f interface/dummy.cfg -c 'transport select jtag' \
    -f target/sr6p6.cfg -c 'echo "targets: [target names]"' -c shutdown 2>&1) ||
    fail "openocd failed: $output"
echo "$output" | grep -q sr6p6.k0c0.core || fail "the SR6P6 target did not load: $output"
grep -q sr6p6_reset_halts "$check/moved/share/openocd/scripts/target/sr6p6.cfg" ||
    fail "target/sr6p6.cfg lacks the fork's fixes"
grep -q 'idVendor}=="0483", ATTRS{idProduct}=="0499"' "$package/share/openocd/contrib/60-openocd.rules" ||
    fail "the udev rules lack StellarLINK 0483:0499"
rm -rf "$check"

tar -czf "$out/$name.tar.gz" -C "$work/package" "$name"
(cd "$out" && sha256 "$name.tar.gz" | sed "s|\$|  $name.tar.gz|" > "$name.tar.gz.sha256")
echo "== $out/$name.tar.gz"
cat "$out/$name.tar.gz.sha256"
