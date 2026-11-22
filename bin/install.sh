#!/usr/bin/env bash
# A product's system, from this machine to the frame's free slot over the Wi-Fi, Linux up: what
# bin/system.sh last built for it, its boot picture (boot/splash.py), and with --kernel this
# build's kernel too (without it, the slot runs on what boots it). Each file is sent under another
# name, its SHA-256 checked on the frame, then renamed (send.sh); the slot's manifest is made and
# signed here (sign.sh), and the frame tries it at its next boot (boot/initramfs.py, frame-commit).
# Usage: bin/install.sh <product directory> [--kernel]
set -euo pipefail
. "$(dirname "$0")/product.sh"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
product "${1:?usage: bin/install.sh <product directory> [--kernel]}"
case "${2:-}" in "" | --kernel) ;; *) echo "$2: only --kernel" >&2; exit 2 ;; esac
IMG="$REPO/build/$NAME/rootfs.squashfs"
[ -f "$IMG" ] || { echo "no $IMG: bin/system.sh $1 first" >&2; exit 1; }
c() { "$REPO/bin/console.sh" "$@"; }
c true 10 >/dev/null || { echo "the frame answers neither on its console nor over SSH (Linux up?)" >&2; exit 1; }

# never while the frame tries a system: its free slot would be the one it runs from
. "$REPO/bin/frame-state.sh"
frame_settled || exit 1
tool=$(c 'for t in /usr/local/sbin/frame-slot /usr/local/sbin/maison-slot; do [ ! -x $t ] || { echo $t; break; }; done' 20)
slot=$([ "$active" = a ] && echo b || echo a)
# a frame two products share: the free slot is this install's to overwrite, so the product that
# runs, when it is another one, is put aside whole first (switch.sh brings it back)
if [ "$running" != "$NAME" ]; then
	parked=/android-data/frame/parked
	c "set -e; rm -rf $parked/$running.new; mkdir -p $parked/$running.new; cp $slots/$active/* $parked/$running.new/; /usr/local/bin/frame-seal check --whole $parked/$running.new >/dev/null; rm -rf $parked/$running; mv $parked/$running.new $parked/$running; sync; echo \"$running put aside\"" 180
fi
c "rm -rf $slots/$slot; mkdir -p $slots/$slot; sync" 20
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cp "$IMG" "$dir/rootfs.squashfs"
python3 -I "$REPO/boot/splash.py" product "$PRODUCT" "$dir"
if [ "${2:-}" = --kernel ]; then
	cp "$REPO/build/linux/zImage" "$dir/zImage"
	cp "$REPO/build/linux/rk3126-amaboo-gbzk-y1000.dtb" "$dir/board.dtb"
	cp "$REPO/build/initramfs.cpio.gz" "$dir/initramfs.cpio.gz"
fi
"$REPO/bin/sign.sh" "$PRODUCT" "$(cat "$REPO/build/$NAME/version")" "$dir"
cat "$REPO/build/$NAME/version" >"$dir/version"
# for a frame whose `boot` is from before the manifests: its sums
(cd "$dir" && shasum -a 256 -- rootfs.squashfs splash.raw splash.conf $([ ! -e zImage ] || echo zImage board.dtb initramfs.cpio.gz) >sums)
for f in "$dir"/*; do "$REPO/bin/send.sh" "$f" "$slots/$slot/$(basename "$f")"; done
c "$tool offer $slot" 60
echo "$NAME $(cat "$REPO/build/$NAME/version"): slot $slot, tried at the next boot"
