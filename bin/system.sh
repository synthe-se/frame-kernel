#!/usr/bin/env bash
# A product's system for the frame, from Buildroot (system/buildroot/base_defconfig, then the
# product's own `defconfig`): the toolchain, the frame's tools and the product's programs against
# it, then all of it as a squashfs. Built in an arm64 Debian (the build host's architecture), in
# Docker volumes, one per set of packages; the sources are pinned and checked.
# The product is a directory of its own repository (README « A product »): what it is called
# (product.conf), its files (rootfs/), its units to enable (preset), its release key, and how its
# programs are built (build.sh on this machine, build-target.sh against the frame's libraries).
# Out: build/<product>/rootfs.squashfs and its version, what bin/install.sh sends.
# Usage: bin/system.sh <product directory>
set -euo pipefail
. "$(dirname "$0")/docker.sh"
. "$(dirname "$0")/product.sh"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
product "${1:?usage: bin/system.sh <product directory>}"
HOME_DIR="${FRAME_HOME:-$HOME/maison-frame}"
SRC="$HOME_DIR/src"
OUT="$REPO/build/$NAME"
VERSION=2026.08.1
SHA256=34fb7bea8a213ffde39cc02e61703391560f26e0850f03138c722d0b09880f2b
RUST=$(sed -n 's/^rust-version = "\(.*\)"$/\1/p' "$REPO/tools/Cargo.toml")
TARGET=armv7-unknown-linux-gnueabihf
SSH_CA="$HOME_DIR/keys/ssh_ca.pub"
[ -s "$SSH_CA" ] || "$REPO/bin/ssh-cert.sh"
# an image number that only goes up
IMAGE_VERSION=$(date -u +%Y%m%d%H%M)
[ -n "$RUST" ] || { echo "tools/Cargo.toml says no rust-version" >&2; exit 1; }

tarball="$SRC/buildroot-$VERSION.tar.xz"
[ -f "$tarball" ] || curl -sfL "https://buildroot.org/downloads/buildroot-$VERSION.tar.xz" -o "$tarball"
echo "$SHA256  $tarball" | shasum -a 256 -c - >/dev/null

# the product's files, and what its build on this machine adds to them
rm -rf "$OUT/staging"
mkdir -p "$OUT/staging"
[ ! -d "$PRODUCT/rootfs" ] || cp -R "$PRODUCT/rootfs/." "$OUT/staging/"
[ ! -x "$PRODUCT/build.sh" ] || "$PRODUCT/build.sh" "$OUT/staging"
# the slot's check, the initramfs's own: static, built here with nothing but the Rust toolchain
(cd "$REPO/tools/seal" && cargo build -q --release --locked --target armv7-unknown-linux-musleabihf)
mkdir -p "$OUT/staging/usr/local/bin"
cp "$REPO/tools/seal/target/armv7-unknown-linux-musleabihf/release/frame-seal" "$OUT/staging/usr/local/bin/"
cat "$REPO/system/buildroot/base_defconfig" >"$OUT/defconfig"
[ ! -s "$PRODUCT/defconfig" ] || cat "$PRODUCT/defconfig" >>"$OUT/defconfig"
product_env >"$OUT/product.env"
echo "IMAGE_VERSION=$IMAGE_VERSION" >>"$OUT/product.env"
release_pub="$PRODUCT/release.pub"
[ -s "$release_pub" ] || release_pub=/dev/null
[ -z "$UPDATE_URL" ] || [ "$release_pub" != /dev/null ] || { echo "$PRODUCT: an update address and no release.pub" >&2; exit 1; }

# one tree per set of packages: a product that adds none shares the frame's own
sum=$(cat "$REPO"/system/buildroot/*.patch "$OUT/defconfig" | shasum -a 256 | cut -c1-12)
docker volume create "frame-buildroot-$sum" >/dev/null
docker volume create frame-buildroot-dl >/dev/null
docker volume create frame-cargo >/dev/null
docker run --rm --platform linux/arm64 -v "frame-buildroot-$sum:/build" -v frame-buildroot-dl:/dl -v frame-cargo:/cache -v "$SRC:/src:ro" \
	-v "$REPO:/frame:ro" -v "$REPO:/frame-kernel:ro" -v "$PRODUCT:/product:ro" -v "$PRODUCT_REPO:/product-repo:ro" -v "$OUT:/out" \
	-v "$OUT/staging:/staging:ro" -v "$OUT/product.env:/product.env:ro" -v "$release_pub:/release.pub:ro" -v "$SSH_CA:/ssh-ca.pub:ro" \
	-e RUST="$RUST" -e TARGET="$TARGET" -e VERSION="$VERSION" -e FIRST="$BUILDROOT_FIRST" debian:trixie sh -euc '
	export DEBIAN_FRONTEND=noninteractive FORCE_UNSAFE_CONFIGURE=1 BR2_DL_DIR=/dl
	apt-get -qq update
	apt-get -qq install -y --no-install-recommends build-essential file wget cpio unzip rsync bc python3 perl \
		git curl cmake pkg-config ca-certificates xz-utils bzip2 >/dev/null 2>&1
	cd /build
	if [ ! -d buildroot-$VERSION ]; then
		tar xJf /src/buildroot-$VERSION.tar.xz
		for p in /frame/system/buildroot/*.patch; do patch -d buildroot-$VERSION -p1 -s -F0 <"$p"; done
	fi
	cd buildroot-$VERSION
	m="make O=/build/out"
	$m BR2_DEFCONFIG=/out/defconfig defconfig >/dev/null
	# the file must have been taken whole, as the kernel'"'"'s (the last word on a symbol is the product'"'"'s)
	missing=$(grep -E "^BR2_[A-Za-z0-9_]+=" /out/defconfig | while read -r l; do grep -qx "$l" /build/out/.config || echo "$l"; done)
	[ -z "$missing" ] || { echo "not taken by kconfig: $missing" >&2; exit 1; }
	date; $m toolchain $FIRST >/build/deps.log 2>&1 || { tail -30 /build/deps.log; exit 1; }
	# the tools and the product'"'"'s programs, against what the frame runs
	date
	H=/build/out/host; S=$H/arm-buildroot-linux-gnueabihf/sysroot
	export CARGO_HOME=/cache/cargo RUSTUP_HOME=/cache/rustup CARGO_TARGET_DIR=/cache/target
	[ -x /cache/cargo/bin/rustup ] || curl -sSf https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain none
	export PATH=/cache/cargo/bin:$H/bin:$PATH
	rustup toolchain install $RUST --target $TARGET --profile minimal >/dev/null 2>&1
	export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER=/frame/system/buildroot/link-gcc
	export CC_armv7_unknown_linux_gnueabihf=arm-buildroot-linux-gnueabihf-gcc CXX_armv7_unknown_linux_gnueabihf=arm-buildroot-linux-gnueabihf-g++
	export CMAKE_TOOLCHAIN_FILE_armv7_unknown_linux_gnueabihf=$H/share/buildroot/toolchainfile.cmake
	export PKG_CONFIG_ALLOW_CROSS=1 PKG_CONFIG_SYSROOT_DIR=$S PKG_CONFIG_LIBDIR=$S/usr/lib/pkgconfig:$S/usr/share/pkgconfig
	export RUST TARGET
	cd /frame/tools
	cargo +$RUST build --locked --release --target $TARGET --bin frame-update --bin frame-wifid --bin frame-power-key
	for tool in frame-update frame-wifid frame-power-key; do cp /cache/target/$TARGET/release/$tool /tmp/; done
	# the product'"'"'s programs that link the frame'"'"'s libraries: into /tmp/product, laid out as the root
	mkdir -p /tmp/product
	[ ! -x /product/build-target.sh ] || /product/build-target.sh /tmp/product
	date; cd /build/buildroot-$VERSION
	$m >/build/make.log 2>&1 || { tail -30 /build/make.log; exit 1; }
	cp /build/out/images/rootfs.squashfs /out/
	cp /build/out/.config /out/buildroot.config
	date; du -sh /build/out/target; ls -la /out/rootfs.squashfs
'
echo "$IMAGE_VERSION" >"$OUT/version"
echo "$NAME $IMAGE_VERSION: $OUT/rootfs.squashfs"
