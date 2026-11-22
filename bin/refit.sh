#!/usr/bin/env bash
# A frame refitted: its eMMC as the vendor laid it out for Android (recovery, system, cache,
# userdata…) becomes one partition of the frame's own, `data`, everything after `boot`, a fresh
# ext4 (with fs-verity), and the `boot` that knows it. What is before `boot` (the loader, U-Boot,
# its picture) is never written: the reset pinhole stays the way back, whatever happens here.
# In stages, each said and checked:
#   prepare   what the frame must keep is read from it (its Wi-Fi's network, its SSH host key,
#             its clock, and the products' own directories: FRAME_KEEP="<names>" for more
#             than this product's), and what the refit writes is made: the slot
#             (signed), the maintenance start (the product's system in RAM), a small image of the
#             partition for the loader, should the frame be left with nothing to start
#   dry       the maintenance start, by kexec, and everything `go` needs looked at: nothing written
#   probe     the first megabyte of the vendor's recovery is zeroed and the frame restarted cold:
#             whether U-Boot starts `boot` without it (it comes back from the backup, by the loader)
#   go        from the maintenance start: `boot` written and read back, the partition made, what
#             was kept put back, the slot laid, and the frame restarted on it
# Between the partition's making and the restart the eMMC holds nothing that starts by itself. If
# the power goes there: the reset pinhole, then `bin/rkwrite.py build/boot.img mmcblk0p5` and
# `bin/rkwrite.py build/refit/data.img data`.
# Usage: bin/refit.sh <product directory> prepare | dry | probe | go
set -euo pipefail
. "$(dirname "$0")/product.sh"
. "$(dirname "$0")/frame-state.sh"
. "$(dirname "$0")/frame-ssh.sh"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
product "${1:?usage: bin/refit.sh <product directory> prepare | dry | probe | go}"
stage=${2:?prepare | dry | probe | go}
FRAME_HOME="${FRAME_HOME:-$HOME/maison-frame}"
BACKUP="$FRAME_HOME/backup"
WORK="$REPO/build/refit"
c() { "$REPO/bin/console.sh" "$@"; }
step() { echo "[$(date +%H:%M:%S)] $*"; }
stop() { echo "refit: $*" >&2; exit 1; }
start_of() { awk -v p="$1" -F'[ =]' '$1==p {print $3}' "$BACKUP/layout.txt"; }
size_of() { awk -v p="$1" -F'[ =]' '$1==p {print $5}' "$BACKUP/layout.txt"; }
BOOT=$(start_of mmcblk0p5)
DATA=$((BOOT + $(size_of mmcblk0p5)))
END=$(awk -F'[ =]' '{ e = $3 + $5; if (e > m) m = e } END { print m }' "$BACKUP/layout.txt")
[ "$BOOT" = 90112 ] && [ "$DATA" = 118784 ] || stop "layout.txt does not say the frame this was written for (boot at $BOOT, data at $DATA)"

# the eMMC as Linux sees it is the layout's: U-Boot's head where it says, boot's header where it says
proved() {
	local uboot head_sum
	uboot=$(start_of mmcblk0p1)
	head_sum=$(head -c 4096 "$BACKUP/mmcblk0p1.img" | shasum -a 256 | cut -c1-64)
	[ "$(c "dd if=/dev/mmcblk0 bs=512 skip=$uboot count=8 2>/dev/null | sha256sum | cut -c1-64" 90)" = "$head_sum" ] ||
		stop "the eMMC's addressing is not the layout's (U-Boot's head differs): nothing written"
	[ "$(c "dd if=/dev/mmcblk0 bs=512 skip=$BOOT count=1 2>/dev/null | head -c 8; echo" 90)" = "ANDROID!" ] ||
		stop "no boot image header at sector $BOOT: nothing written"
}
# write_at <file on the frame> <sector> <sectors>: never before `boot`, read back and compared
write_at() {
	local file=$1 at=$2 n=$3 want got
	[ "$at" -ge "$BOOT" ] && [ $((at + n)) -le "$END" ] || stop "sector $at (+$n) is outside boot and data: not written"
	want=$(c "head -c $((n * 512)) $file | sha256sum | cut -c1-64" 120)
	c "dd if=$file of=/dev/mmcblk0 bs=512 seek=$at count=$n conv=notrunc,fsync 2>&1 | tail -1; sync; echo 3 >/proc/sys/vm/drop_caches" 300
	got=$(c "dd if=/dev/mmcblk0 bs=512 skip=$at count=$n 2>/dev/null | sha256sum | cut -c1-64" 300)
	[ -n "$want" ] && [ "$got" = "$want" ] || stop "sector $at reads back $got, not $want"
}
boot_id() { c 'cat /proc/sys/kernel/random/boot_id' 8 2>/dev/null; }
restarted() { local now; now=$(boot_id) && [ -n "$now" ] && [ "$now" != "$before" ]; }
wait_for() {
	local what=$1 secs=$2 i
	shift 2
	for ((i = 0; i < secs; i += 2)); do "$@" && return 0; sleep 2; done
	stop "timeout: $what, after ${secs}s"
}
maintenance() { [ "$(c "awk '\$2 == \"/data\" { print \$3 }' /proc/mounts" 20)" = tmpfs ]; }

case "$stage" in
prepare)
	[ -s "$REPO/build/$NAME/rootfs.squashfs" ] || stop "no build/$NAME/rootfs.squashfs: just image $1"
	for built in boot.img initramfs.cpio.gz; do
		[ "$REPO/build/$built" -nt "$REPO/build/linux/zImage" ] && [ "$REPO/build/$built" -nt "$REPO/boot/initramfs.py" ] ||
			stop "build/$built is older than the kernel or the initramfs it holds: just boot <products>"
	done
	grep -q 'blkdevparts=mmcblk0:-@59392K(data)' "$REPO/build/linux/.config" || stop "the kernel built does not declare the data partition"
	frame_settled || exit 1
	rm -rf "$WORK"
	mkdir -p "$WORK/keep" "$WORK/payload/data/frame" "$WORK/slot"
	step "reading what the frame keeps"
	root=$(c '[ -d /android-data ] && echo /android-data || echo /data' 20)
	# the frame's own, and each product's directory (FRAME_KEEP: names there, this product's by default)
	kept=$(c "cd $root && for f in frame/ssh frame/timesync frame/wifi.known frame/wifi.conf ${FRAME_KEEP:-$NAME}; do [ ! -e \$f ] || echo \$f; done" 20)
	[ -n "$kept" ] || stop "the frame says it keeps nothing"
	# shellcheck disable=SC2086  # one word a path
	frame_ssh "tar cf - -C $root $(printf '%s ' $kept)" >"$WORK/keep.tar"
	tar tf "$WORK/keep.tar" >"$WORK/keep.list"
	grep -q '^frame/ssh/ssh_host_ed25519_key$' "$WORK/keep.list" || stop "the frame's SSH host key is not in what was read"
	tar xf "$WORK/keep.tar" -C "$WORK/keep"
	# the network the frame is on, as its wpa_supplicant runs it now (a frame from before this
	# repository had it from Android's own file)
	if [ -s "$WORK/keep/frame/wifi.conf" ]; then
		cp "$WORK/keep/frame/wifi.conf" "$WORK/wifi.conf"
	else
		c "sed -n '/^network={/,/^}/p' /etc/wpa_supplicant/wpa_supplicant-wlan0.conf | grep -v scan_freq" 20 >"$WORK/wifi.conf"
	fi
	if ! grep -q '^network={' "$WORK/wifi.conf" || ! grep -q 'ssid=' "$WORK/wifi.conf"; then
		stop "no Wi-Fi network could be read from the frame: it would come back mute"
	fi
	chmod 600 "$WORK/wifi.conf"
	step "what the frame keeps: $(wc -l <"$WORK/keep.list" | tr -d ' ') entries, $(du -sh "$WORK/keep.tar" | cut -f1), and $(grep -c '^network={' "$WORK/wifi.conf") Wi-Fi network(s)"

	step "the slot, signed"
	cp "$REPO/build/$NAME/rootfs.squashfs" "$WORK/slot/"
	python3 -I "$REPO/boot/splash.py" product "$PRODUCT" "$WORK/slot"
	"$REPO/bin/sign.sh" "$PRODUCT" "$(cat "$REPO/build/$NAME/version")" "$WORK/slot"
	cat "$REPO/build/$NAME/version" >"$WORK/slot/version"
	(cd "$REPO/tools/seal" && cargo run -q --release --bin frame-seal -- check --whole "$WORK/slot" "$PRODUCT/release.pub" >/dev/null) || stop "the slot does not pass its own check"

	step "the maintenance start: the system in RAM, with the network and the host key"
	cp "$REPO/build/$NAME/rootfs.squashfs" "$WORK/payload/"
	cp "$WORK/wifi.conf" "$WORK/payload/data/frame/wifi.conf"
	cp -R "$WORK/keep/frame/ssh" "$WORK/payload/data/frame/ssh"
	[ ! -s "$WORK/keep/frame/wifi.known" ] || cp "$WORK/keep/frame/wifi.known" "$WORK/payload/data/frame/"
	# one archive, as it is: the initramfs and what it carries (boot/payload.py says why not two)
	python3 -I "$REPO/boot/initramfs.py" --payload "$WORK/payload" "$REPO/build/tools" "$FRAME_HOME/recon/gslX680.fw" "$WORK/maintenance.cpio"
	mv "$WORK/maintenance.cpio" "$WORK/maintenance.initrd"

	step "the partition's image for the loader, should it come to that"
	mkdir -p "$WORK/dataroot/frame/slots/a"
	tar xf "$WORK/keep.tar" -C "$WORK/dataroot"
	cp "$WORK/wifi.conf" "$WORK/dataroot/frame/wifi.conf"
	cp "$WORK/slot/"* "$WORK/dataroot/frame/slots/a/"
	printf 'active=a\npending=\ntries=0\nboots=1\n' >"$WORK/dataroot/frame/slots/state"
	docker run --rm -v "$WORK:/w" alpine:3.24.3 sh -euc 'apk add -q e2fsprogs >/dev/null
		cp -a /w/dataroot /tmp/root && chown -R 0:0 /tmp/root && chmod 700 /tmp/root/frame/slots /tmp/root/frame/ssh
		rm -f /w/data.img && mke2fs -q -t ext4 -L data -O verity -m 0 -d /tmp/root /w/data.img 256M'
	rm -rf "$WORK/dataroot"
	du -sh "$WORK"/*
	step "prepared: bin/refit.sh $1 dry"
	;;
dry)
	[ -s "$WORK/maintenance.initrd" ] || stop "nothing prepared: bin/refit.sh $1 prepare"
	frame_settled || exit 1
	for f in linux/zImage linux/rk3126-amaboo-gbzk-y1000.dtb refit/maintenance.initrd; do
		step "sending $f"
		"$REPO/bin/send.sh" "$REPO/build/$f" "/tmp/refit-$(basename "$f")" >/dev/null
	done
	# where a maintenance start that fails says why (boot/initramfs.py): a file of the partition's
	# filesystem on a frame already refitted; else a place in the partition to be made, emptied
	# first so that what is read there is its own
	refitted=$(c "grep -q '^/dev/mmcblk0p1 /data ext4' /proc/mounts && echo yes || echo no" 20)
	if [ "$refitted" = yes ]; then
		c 'rm -f /data/frame/maintenance.log; sync' 20
	else
		c "dd if=/dev/zero of=/tmp/refit-zero bs=512 count=256 2>/dev/null" 20
		write_at /tmp/refit-zero $((DATA + 4096)) 256 >/dev/null
	fi
	before=$(boot_id)
	step "the maintenance start"
	c 'for lib in /usr/local/lib/frame-slots /usr/local/lib/maison-slots; do [ ! -e $lib ] || { . $lib; break; }; done
kexec -l /tmp/refit-zImage --dtb=/tmp/refit-rk3126-amaboo-gbzk-y1000.dtb --initrd=/tmp/refit-maintenance.initrd --command-line="$(uboot_line)" && systemctl kexec' 60 || true
	wait_for "the frame in its maintenance start" 180 restarted
	if ! maintenance; then
		# what the maintenance start left, where it says why (boot/initramfs.py)
		c "{ cat /data/frame/maintenance.log 2>/dev/null || dd if=/dev/mmcblk0 bs=512 skip=$((DATA + 4096)) count=256 2>/dev/null | tr -d '\\000'; } | grep -a -A400 '^frame-maintenance-log' | tail -n 70" 30 || true
		stop "the frame came back on its own system, not the maintenance start"
	fi
	step "looked at, nothing written:"
	c "echo \"  system: \$(cat /etc/frame/product) \$(cat /etc/frame/version), \$(uname -r), from RAM\"
part=\$(grep -l '^PARTNAME=data\$' /sys/class/block/*/uevent | head -1); part=\${part%/uevent}
echo \"  data partition: \${part##*/}, start \$(cat \$part/start) (wanted $DATA), \$(cat \$part/size) sectors (wanted $((END - DATA)))\"
echo \"  mounted from the eMMC: \$(grep -c mmcblk /proc/mounts || :) (wanted 0)\"
echo \"  mke2fs: \$(mke2fs -V 2>&1 | head -1)\"; echo \"  resize2fs: \$(command -v resize2fs)\"
echo \"  /data paths in the system: \$(grep -rl android-data /etc/systemd/system /usr/local/sbin /usr/local/lib 2>/dev/null | wc -l) file(s) still say android-data (wanted 0)\"" 40
	proved
	step "addressing proved. The frame is in its maintenance start: bin/refit.sh $1 go, or restart it to leave"
	;;
probe)
	frame_settled || exit 1
	recovery=$(start_of mmcblk0p6)
	[ "$recovery" = "$DATA" ] || stop "the vendor's recovery is not where data starts"
	[ -s "$BACKUP/mmcblk0p6.img" ] || stop "no backup of the vendor's recovery ($BACKUP/mmcblk0p6.img)"
	proved
	want=$(shasum -a 256 "$BACKUP/mmcblk0p6.img" | cut -c1-64)
	got=$(c "dd if=/dev/mmcblk0 bs=512 skip=$recovery count=$(size_of mmcblk0p6) 2>/dev/null | sha256sum | cut -c1-64" 120)
	[ "$got" = "$want" ] || echo "note: the recovery on the frame is not the backup's (a first megabyte already zeroed?)"
	step "zeroing the first megabyte of the vendor's recovery (sector $recovery)"
	c "dd if=/dev/zero of=/tmp/refit-zero bs=512 count=2048 2>/dev/null" 20
	write_at /tmp/refit-zero "$recovery" 2048
	before=$(boot_id)
	step "restarting cold: U-Boot must start boot without a recovery"
	c 'systemctl reboot' 10 || true
	wait_for "the frame after its cold start (else: the reset pinhole, then bin/rkwrite.py $BACKUP/mmcblk0p6.img mmcblk0p6)" 240 restarted
	step "U-Boot starts boot without the vendor's recovery: $(c 'uname -r' 20)"
	;;
go)
	[ -s "$WORK/slot/manifest.sig" ] && [ -s "$WORK/keep.tar" ] && [ -s "$WORK/data.img" ] || stop "nothing prepared: bin/refit.sh $1 prepare"
	maintenance || stop "the frame is not in its maintenance start: bin/refit.sh $1 dry"
	part=$(c "p=\$(grep -l '^PARTNAME=data\$' /sys/class/block/*/uevent | head -1); p=\${p%/uevent}; echo \"\${p##*/} \$(cat \$p/start) \$(cat \$p/size)\"" 20)
	[ "$part" = "mmcblk0p1 $DATA $((END - DATA))" ] || stop "the data partition is not where it is wanted: $part"
	[ "$(c 'grep -c mmcblk /proc/mounts || :' 20)" = 0 ] || stop "something of the eMMC is mounted"
	proved
	step "boot: sending and writing it (sector $BOOT)"
	"$REPO/bin/send.sh" "$REPO/build/boot.img" /tmp/refit-boot.img >/dev/null
	write_at /tmp/refit-boot.img "$BOOT" $(($(wc -c <"$REPO/build/boot.img") / 512))
	step "boot written and read back. The partition: made anew (sector $DATA to the end)"
	c "mke2fs -q -F -t ext4 -L data -O verity -m 0 -E lazy_itable_init=1,lazy_journal_init=1 /dev/mmcblk0p1 && mkdir -p /mnt && mount -t ext4 -o noatime /dev/mmcblk0p1 /mnt && df -h /mnt | tail -1" 300
	step "what the frame kept, put back"
	frame_ssh "tar xf - -C /mnt" <"$WORK/keep.tar"
	"$REPO/bin/send.sh" "$WORK/wifi.conf" /mnt/frame/wifi.conf >/dev/null
	c "chown 0:0 /mnt /mnt/frame && chmod 755 /mnt /mnt/frame && mkdir -p /mnt/frame/slots/a && chmod 700 /mnt/frame/slots" 20
	step "the slot"
	for f in "$WORK/slot"/*; do "$REPO/bin/send.sh" "$f" "/mnt/frame/slots/a/$(basename "$f")" >/dev/null; done
	c "printf 'active=a\npending=\ntries=0\nboots=1\n' >/mnt/frame/slots/state && /usr/local/bin/frame-seal check --whole /mnt/frame/slots/a >/dev/null && /usr/local/bin/frame-seal seal /mnt/frame/slots/a >/dev/null && sync && ls /mnt /mnt/frame /mnt/frame/slots/a | tr '\n' ' ' && umount /mnt && sync && echo && echo laid" 120 | tail -2
	before=$(boot_id)
	step "restarting cold, on the new boot and the new partition"
	c 'systemctl reboot' 10 || true
	wait_for "the frame after its cold start (else: the reset pinhole, then bin/rkwrite.py build/boot.img mmcblk0p5 and bin/rkwrite.py build/refit/data.img data)" 300 restarted
	c "echo \"\$(cat /etc/frame/product) \$(cat /etc/frame/version), \$(uname -r)\"; grep ' /data ' /proc/mounts | cut -d' ' -f1-3; df -h /data | tail -1; ls /data" 30
	step "refitted. The other product comes back by: just install <its directory>"
	;;
*) stop "$stage: prepare | dry | probe | go" ;;
esac
