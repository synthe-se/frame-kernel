#!/usr/bin/env bash
# A product's release for its frames over the air: what bin/system.sh last built for it, its boot
# picture, and with --kernel this build's kernel too (a slot's own, started by kexec: `boot` is
# never written over the air), under build/<product>/release/, its manifest signed with the
# product's release key (sign.sh). With --publish, on to where its frames look (UPDATE_HOST in its
# product.conf, as rsync names it): the files first, `manifest.json` and `manifest.sig` last, which
# a frame reads first.
# Usage: bin/release.sh <product directory> [--kernel] [--publish]
set -euo pipefail
. "$(dirname "$0")/product.sh"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
product "${1:?usage: bin/release.sh <product directory> [--kernel] [--publish]}"
shift
BUILD="$REPO/build/$NAME"
OUT="$BUILD/release"
version=$(cat "$BUILD/version")
kernel=false publish=false
for a in "$@"; do
	case "$a" in --kernel) kernel=true ;; --publish) publish=true ;; *) echo "unknown: $a" >&2; exit 2 ;; esac
done
if $publish; then
	[ -n "$UPDATE_URL" ] && [ -n "$UPDATE_HOST" ] || { echo "$PRODUCT/product.conf: UPDATE_URL and UPDATE_HOST say where a release goes" >&2; exit 1; }
	# what is published must be what its frames were built to look for
	grep -qx "UPDATE_URL='$UPDATE_URL'" "$BUILD/product.env" || { echo "the image in $BUILD was not built for $UPDATE_URL: bin/system.sh first" >&2; exit 1; }
fi

rm -rf "$OUT"
mkdir -p "$OUT/$version"
cp "$BUILD/rootfs.squashfs" "$OUT/$version/"
python3 -I "$REPO/boot/splash.py" product "$PRODUCT" "$OUT/$version"
if $kernel; then
	cp "$REPO/build/linux/zImage" "$OUT/$version/"
	cp "$REPO/build/linux/rk3126-amaboo-gbzk-y1000.dtb" "$OUT/$version/board.dtb"
	cp "$REPO/build/initramfs.cpio.gz" "$OUT/$version/initramfs.cpio.gz"
fi
"$REPO/bin/sign.sh" "$PRODUCT" "$version" "$OUT/$version"
mv "$OUT/$version/manifest.json" "$OUT/$version/manifest.sig" "$OUT/"
ls -la "$OUT" "$OUT/$version"
if $publish; then
	rsync -a "$OUT/$version" "$UPDATE_HOST/"
	rsync -a "$OUT/manifest.json" "$OUT/manifest.sig" "$UPDATE_HOST/"
	echo "published: $NAME $version, at $UPDATE_URL"
fi
