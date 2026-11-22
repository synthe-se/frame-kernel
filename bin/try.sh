#!/usr/bin/env bash
# The frame, tried: restarted, and its product waited for. With --install <product directory> the
# product's system goes first to the free slot over the Wi-Fi (install.sh); with --flash the
# kernel image (build/boot.img: `just boot`) is written to `boot`: from Linux itself when it is
# up (sent over the Wi-Fi, the eMMC's addressing proved first by reading U-Boot's head where
# layout.txt says and finding boot's header, then written, read back and compared), else from the
# loader (rkwrite.py; the reset pinhole). With --ram the new kernel only runs: sent to /tmp and
# started by kexec, `boot` untouched, so that cutting the power comes back to what is flashed.
# Every wait has a deadline and fails the script, loudly; each step is timed.
# With --logo, U-Boot's first picture: the `resource` partition, read, its logo replaced, written
# back and read back, under the same proof of addressing.
# With --settle, a system already offered to the frame (switch.sh) is waited for the same way.
# Usage: bin/try.sh [--install <product directory> [--kernel]] [--settle] [--logo] [--flash | --ram]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$REPO/build/boot.img"
FRAME_HOME="${FRAME_HOME:-$HOME/maison-frame}"
export PATH="$FRAME_HOME/bin:$PATH"
# rkdeveloptool writes a log/ into its working directory: a temporary one, never the repo
RKDIR=$(mktemp -d)
rk() { (cd "$RKDIR" && rkdeveloptool "$@"); }

step() { echo "[$(date +%H:%M:%S)] $*"; }
# Linux up: its USB console, else its SSH (console.sh takes either)
console() { "$REPO/bin/console.sh" true 8 >/dev/null 2>&1; }
# this boot's own number: the frame restarts faster than a console can be seen to go
boot_id() { "$REPO/bin/console.sh" 'cat /proc/sys/kernel/random/boot_id' 8 2>/dev/null; }
before=
restarted() { local now; now=$(boot_id) && [ -n "$now" ] && [ "$now" != "$before" ]; }
loader() { rk ld 2>/dev/null | grep -q Loader; }
# wait_for <what> <seconds> <test…>
wait_for() {
	local what=$1 secs=$2 i
	shift 2
	for ((i = 0; i < secs; i += 2)); do "$@" && return 0; sleep 2; done
	echo "timeout: $what, after ${secs}s" >&2
	exit 1
}
c() { "$REPO/bin/console.sh" "$@"; }
# the unit the system says a boot is judged on; a system from before this repository has Maison's
product_active() { [ "$(c 'systemctl is-active "$(cat /etc/frame/unit 2>/dev/null || echo maison-ui)"' 20 2>/dev/null)" = active ]; }
# where the frame keeps its slots, as the system that runs says
slots_of() { c 'for lib in /usr/local/lib/frame-slots /usr/local/lib/maison-slots; do [ ! -e $lib ] || { . $lib; break; }; done; echo $slots' 20; }

install='' flash=false ram=false logo=false kernel='' settle=false
while [ $# -gt 0 ]; do
	case "$1" in --install) install=${2:?--install <product directory>}; shift ;; --kernel) kernel=--kernel ;; --settle) settle=true ;; --flash) flash=true ;; --ram) ram=true ;; --logo) logo=true ;; *) echo "unknown: $1" >&2; exit 2 ;; esac
	shift
done
if $flash && $ram; then echo "--flash or --ram" >&2; exit 2; fi

if [ -n "$install" ]; then
	wait_for "the frame (USB console or SSH, Linux up)" 120 console
	step "sending the system to the free slot over the Wi-Fi (about 30 s)"
	"$REPO/bin/install.sh" "$install" $kernel
	settle=true
fi

BACKUP="$FRAME_HOME/backup"
start_of() { awk -v p="$1" -F'[ =]' '$1==p {print $3}' "$BACKUP/layout.txt"; }
size_of() { awk -v p="$1" -F'[ =]' '$1==p {print $5}' "$BACKUP/layout.txt"; }

# the eMMC as Linux sees it is the layout's: U-Boot's head where it says, boot's header where it says
proved() {
	local uboot head_sum
	uboot=$(start_of mmcblk0p1)
	head_sum=$(head -c 4096 "$BACKUP/mmcblk0p1.img" | shasum -a 256 | cut -c1-64)
	[ "$(c "dd if=/dev/mmcblk0 bs=512 skip=$uboot count=8 2>/dev/null | sha256sum | cut -c1-64" 90)" = "$head_sum" ] ||
		{ echo "the eMMC's addressing is not the layout's (U-Boot's head differs): nothing written" >&2; exit 1; }
	[ "$(c "dd if=/dev/mmcblk0 bs=512 skip=$1 count=1 2>/dev/null | head -c 8; echo" 90)" = "ANDROID!" ] ||
		{ echo "no boot image header at sector $1: nothing written" >&2; exit 1; }
}

if $logo; then
	wait_for "the frame (USB console or SSH, Linux up)" 120 console
	proved "$(start_of mmcblk0p5)"
	start=$(start_of mmcblk0p3) sectors=$(size_of mmcblk0p3)
	dir=$(mktemp -d)
	step "reading the resource partition"
	"$REPO/bin/frame-read.sh" "dd if=/dev/mmcblk0 bs=512 skip=$start count=$sectors 2>/dev/null" "$dir/resource.img"
	[ "$(head -c 4 "$dir/resource.img")" = RSCE ] || { echo "no resource image at sector $start: nothing written" >&2; exit 1; }
	python3 -I "$REPO/boot/splash.py" logo "$dir/resource.img" "$dir/logo.img"
	"$REPO/bin/send.sh" "$dir/logo.img" /tmp/logo.img
	step "writing it (sector $start, $sectors sectors)"
	c "dd if=/tmp/logo.img of=/dev/mmcblk0 bs=512 seek=$start conv=notrunc,fsync 2>&1 | tail -1; sync; echo 3 > /proc/sys/vm/drop_caches" 120
	want=$(shasum -a 256 "$dir/logo.img" | cut -c1-64)
	got=$(c "dd if=/dev/mmcblk0 bs=512 skip=$start count=$sectors 2>/dev/null | sha256sum | cut -c1-64" 120)
	[ "$got" = "$want" ] || { echo "resource reads back $got, not $want" >&2; exit 1; }
	c 'rm -f /tmp/logo.img' 10
	rm -rf "$dir"
	step "the logo written and read back"
	$flash || $ram || exit 0
fi

before=$(boot_id || true)
if $ram; then
	BUILD="$REPO/build"
	for f in linux/zImage linux/rk3126-amaboo-gbzk-y1000.dtb initramfs.cpio.gz; do
		step "sending $f"
		"$REPO/bin/send.sh" "$BUILD/$f" "/tmp/ram-$(basename "$f")"
	done
	# U-Boot's part of the command line: the new kernel adds its own (CONFIG_CMDLINE_EXTEND)
	step "loading the kernel"
	c 'kexec -l /tmp/ram-zImage --dtb=/tmp/ram-rk3126-amaboo-gbzk-y1000.dtb --initrd=/tmp/ram-initramfs.cpio.gz --command-line="$(for lib in /usr/local/lib/frame-slots /usr/local/lib/maison-slots; do [ ! -e $lib ] || { . $lib; break; }; done; uboot_line)"' 60
	c 'systemctl kexec' 10 || true
elif $flash && console; then
	[ -f "$IMG" ] || { echo "no $IMG: just boot first" >&2; exit 1; }
	boot=$(start_of mmcblk0p5)
	sectors=$(($(wc -c <"$IMG") / 512))
	[ "$sectors" -le "$(size_of mmcblk0p5)" ] || { echo "$IMG: $sectors sectors, boot holds $(size_of mmcblk0p5)" >&2; exit 1; }
	proved "$boot"
	step "addressing proved: sending $(basename "$IMG")"
	"$REPO/bin/send.sh" "$IMG" /tmp/boot-linux.img
	step "writing it to boot (sector $boot, $sectors sectors)"
	c "dd if=/tmp/boot-linux.img of=/dev/mmcblk0 bs=512 seek=$boot conv=notrunc,fsync 2>&1 | tail -1; sync; echo 3 > /proc/sys/vm/drop_caches" 120
	want=$(shasum -a 256 "$IMG" | cut -c1-64)
	got=$(c "dd if=/dev/mmcblk0 bs=512 skip=$boot count=$sectors 2>/dev/null | sha256sum | cut -c1-64" 120)
	[ "$got" = "$want" ] || { echo "boot reads back $got, not $want: write it again (try.sh --flash), or from the loader" >&2; exit 1; }
	step "boot written and read back"
	c 'rm -f /tmp/boot-linux.img; systemctl reboot' 10 || true
elif $flash; then
	[ -f "$IMG" ] || { echo "no $IMG: just boot first" >&2; exit 1; }
	step "the loader: power off, hold the reset pinhole, power on with the USB-C on this machine"
	wait_for "the loader" 300 loader
	step "writing $(basename "$IMG") to boot (about 1 min)"
	BACKUP="$BACKUP" python3 "$REPO/bin/rkwrite.py" "$IMG" mmcblk0p5
	rk rd
elif console; then
	step "rebooting Linux"
	c 'systemctl reboot' 10 || true
fi

wait_for "the frame to restart" 240 restarted
step "Linux up: waiting for the product"
wait_for "the product's unit active" 180 product_active
step "$(c 'cat /etc/frame/product 2>/dev/null || echo maison' 20) up, $(c 'uname -r' 20)"
if $settle; then
	. "$REPO/bin/frame-state.sh"
	slots=$(slots_of)
	# what the frame says, whole: an answer that did not come is no end of a trial
	settled() { frame_slots 2>/dev/null && [ -z "$pending" ] && [ "$mounted" = "$active" ]; }
	step "the system proving itself (about 1 min)"
	wait_for "the trial to end" 300 settled
	if [ -n "$(c "cat $slots/failed 2>/dev/null; rm -f $slots/failed" 20)" ]; then
		echo "the system failed: the frame went back to the one before it" >&2
		exit 1
	fi
	step "the system is the frame's: slot $(c "sed -n 's/^active=//p' $slots/state" 20)"
fi
