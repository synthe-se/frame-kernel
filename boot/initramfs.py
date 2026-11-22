"""The frame's initramfs: its /init (mksh) draws the boot picture, says in the kernel's log what
came up (the display, the touch, the eMMC, the SDIO card), chooses a slot (an update on trial, a
rollback, its kernel by kexec) and starts its system from the data partition. It writes to the
eMMC only there: the slots' state. It names no product: the picture is
the slot's own (boot/splash.py), the frame's for want of one. With --debug (bring-up), it makes the
USB-C port a root serial console (CDC ACM: /dev/cu.usbmodem* on macOS), blinks the backlight five
times (a sign with no console at all, ~10 s) and waits 8 s before saying what came up. Tools:
boot/tools.sh's static ones; the touch firmware extracted from the vendor kernel
($FRAME_HOME/recon, never in the repo).

    python3 boot/initramfs.py [--debug] [--key <release.pub>]… [--payload <directory>] <tools dir> <touch firmware> <out.cpio | out.cpio.gz>

Each --key is a product's release key (its public half): a slot starts only if one of them signed
its manifest. Without any, a bring-up image, the manifests' signatures are not asked.
--payload makes a maintenance start (boot/payload.py): the directory goes in the same archive,
under /payload, and the system it holds is the one started, from RAM.
"""

import gzip
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bootimg  # noqa: E402
import payload as carried  # noqa: E402
import splash  # noqa: E402

FIRMWARE = "lib/firmware/silead/gsl-amaboo-gbzk-y1000.fw"  # the DT's firmware-name
# bin/kernel.sh's Wi-Fi driver: its modules, and its firmware where the patched driver reads it
AIC8800 = Path(__file__).resolve().parents[1] / "build/linux/aic8800"
AIC8800_FIRMWARE = "lib/firmware/aic8800_fw/SDIO/aic8800DC"
# the slot's check, static (tools/seal, built for the frame by `just boot`)
SEAL = Path(__file__).resolve().parents[1] / "tools/seal/target/armv7-unknown-linux-musleabihf/release/frame-seal"
# bin/kernel.sh's wireless-regdb: cfg80211 reads it as it starts, before any system
REGDB = AIC8800.parent

# --debug only: a sign without any console, the backlight blinking 5 times as soon as init runs
BLINK = """
# 0. a sign without any console: the backlight blinks 5 times as soon as init runs
for _ in 1 2 3 4 5 6 7 8 9 10; do ls /sys/class/backlight/*/brightness >/dev/null 2>&1 && break; sleep 1; done
for b in /sys/class/backlight/*/brightness; do
	for _ in 1 2 3 4 5; do echo 10 >$b; sleep 1; echo 255 >$b; sleep 1; done
done
"""
# --debug: what came up is said once everything had its time; else once the display says its
# state (bounded: a panel that never probes is said as such)
SETTLE_DEBUG = "sleep 8"
# --debug: a root shell on the USB-C port (CDC ACM). Never in a product's boot: whoever holds a cable
# would have root
CONSOLE = """# 2. a serial console on the USB-C port
g=/sys/kernel/config/usb_gadget/frame
mkdir -p $g/strings/0x409 $g/configs/c.1/strings/0x409 $g/functions/acm.usb0
echo 0x1d6b >$g/idVendor
echo 0x0104 >$g/idProduct
echo frame >$g/strings/0x409/serialnumber
echo "Frame console" >$g/strings/0x409/product
echo console >$g/configs/c.1/strings/0x409/configuration
ln -s $g/functions/acm.usb0 $g/configs/c.1/
udc=$(ls /sys/class/udc | head -1)
[ -n "$udc" ] && echo $udc >$g/UDC && say "USB console on $udc"
(while [ ! -e /tmp/stop-console ]; do [ -c /dev/ttyGS0 ] && mksh -i </dev/ttyGS0 >/dev/ttyGS0 2>&1; sleep 1; done) &
console=$!
"""
HANDOVER = """	touch /tmp/stop-console
	pkill -P $console
	pkill -f "mksh -i"
"""
# No battery: at this point the clock says 1970, so a time-based check must never be believed
E2FSCK_CONF = "[options]\nbroken_system_clock = 1\n"
SETTLE = ""

INIT = """#!/bin/mksh
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t configfs none /sys/kernel/config
mkdir -p /tmp
say() {{ echo "frame: $*" >/dev/kmsg; }}
say "init up, $(uname -r)"
# await '<test>' <times>: the test asked again every 50 ms, that many times at most; its answer
await() {{
	n=0
	until eval "$1" || [ $n -ge $2 ]; do sleep 0.05; n=$((n + 1)); done
	eval "$1"
}}
# the processor at its fastest clock until the product draws: U-Boot leaves it at 600 MHz, and the
# governor would take its time to see the boot's work (the system gives the clock back to it)
for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do echo performance >$g; done 2>/dev/null
{blink}
# 1. what is there (the vendor's U-Boot does not resume a recovery from misc: a power cycle is
#    the boot slot's, proved on the frame)
await '[ -b /dev/mmcblk0 ]' 200 && say "eMMC: $(cat /sys/block/mmcblk0/size) sectors" || say "no eMMC"

{console}
# 3. the boot picture (splash.py), as soon as the framebuffer is there and the slots can be read:
#    the product's own, which its slot carries, its ring turning until the product takes the
#    panel; the frame's own for a slot that has none, and when nothing can start
{settle}
await '[ -c /dev/fb0 ]' 100
shown=
show() {{
	[ -c /dev/fb0 ] && [ "$shown" != "$1" ] && [ -s $1/splash.raw ] && [ -s $1/splash.conf ] || return 1
	pkill frame-loader
	cat $1/splash.raw >/dev/fb0 2>/dev/null
	frame-loader $(cat $1/splash.conf) &
	shown=$1
}}
# (echo $(…) joins the lines: toybox has no tr)
say "display: $(echo $(cat /sys/class/drm/*/status 2>/dev/null))"
say "backlight: $(echo $(ls /sys/class/backlight 2>/dev/null))"
say "input: $(echo $(cat /sys/class/input/*/name 2>/dev/null))"
say "mmc: $(echo $(ls /sys/bus/mmc/devices 2>/dev/null))"
say "sdio: $(echo $(cat /sys/bus/sdio/devices/*/vendor /sys/bus/sdio/devices/*/device 2>/dev/null))"

# 4. the data partition, and which system: two slots, a and b, each a system and perhaps a kernel, all of it
#    as its manifest says, signed by a product's release key (frame-seal). An update goes to the free slot and is tried for its tries, the
#    active slot's boots counted the same way, each before it starts (a power cut or a crash spends
#    one), until frame-commit says the frame works. Tries spent, 4 boots without a proof, or a
#    slot not whole: the other one; 8 boots and neither, the failure's line stays. The files are
#    read through for a slot on trial and for one whose last boot proved nothing; a slot that
#    proved itself is only looked at: reading 28 MB through SHA-256 is 4.6 s of every boot here.
#    A slot's kernel starts by kexec, here, before anything holds the hardware; no update writes
#    `boot`, so that its kernel is what any failure comes back to
# the Wi-Fi's driver loads beside the boot and is never waited for: five uploads of firmware, a
# second in all, that end while the system starts. Its board support first, then the driver itself
# without its power save (the frame lives on the mains; the driver sets it whatever cfg80211's
# default). Its modules and firmware are kept on a tmpfs of their own, which switch_root does not
# empty with the rest: the load outlives this root
# The interface's address is made here too, the same at every boot: the AIC8800 has none of its
# own and its driver draws one at random (a new lease, a new address each boot); from the eMMC's
# serial, locally administered and unicast (02, then five bytes of its SHA-256)
# What it needs once this root is gone is kept with it: toybox, and a /sys of its own.
wifi() {{
	insmod /kept/aic8800_bsp.ko && insmod /kept/aic8800_fdrv.ko ps_on=0 || return
	n=0
	until [ -d /kept/sys/class/net/wlan0 ] || [ $n -ge 100 ]; do /kept/toybox sleep 0.05; n=$((n + 1)); done
	/kept/toybox ifconfig wlan0 hw ether $mac
}}
mac=$(printf '%s' "$(cat /sys/block/mmcblk0/device/cid)" | sha256sum | sed -E 's/^(..)(..)(..)(..)(..).*/02:\\1:\\2:\\3:\\4:\\5/')
mkdir -p /kept && mount -t tmpfs -o mode=755 tmpfs /kept && cp /lib/modules/*.ko /bin/toybox /kept/ &&
	mkdir /kept/sys && mount -t sysfs sys /kept/sys &&
	cp -r /lib/firmware/aic8800_fw /kept/ && mount --bind /kept/aic8800_fw /lib/firmware/aic8800_fw
# A maintenance start (bin/refit.sh, by kexec): the system came with this initramfs (/payload),
# with what it needs to be reached; the data partition is not even looked at, to be made anew
payload=
[ ! -s /payload/rootfs.squashfs ] || payload=1
# what it does is kept, to be said if it cannot start its system: nobody sees this console
[ -z "$payload" ] || {{ exec 2>/tmp/trace; set -x; }}
data=$([ -n "$payload" ] || grep -l "^PARTNAME=data$" /sys/class/block/*/uevent | head -1)
{slots}
# the release keys this image was built with: one of them signed the manifest of a slot that starts
keys=$(echo /keys/*.pub)
[ -e /keys/0.pub ] || keys=
mkdir -p /data /lower /rw /newroot
slot=
trial=
# the active slot as its last boot left it
sure() {{ if [ "${{boots:-0}}" -gt 0 ]; then whole "$1"; else there "$1"; fi; }}
choose() {{
	active=$(key active) pending=$(key pending) tries=$(key tries) boots=$(key boots)
	case "$active" in a | b) ;; *)
		# no usable state: what is whole
		whole a && active=a || active=b
		pending=
		boots=1
		;;
	esac
	if [ -n "$pending" ]; then
		if [ "${{tries:-0}}" -gt 0 ] && whole "$pending" && remember "$active" "$pending" $((tries - 1)) "$boots"; then
			slot=$pending
			trial=1
			say "update: trying slot $slot"
			return
		fi
		say "update: slot $pending failed, back on $active"
		echo "$pending" >$slots/failed
		remember "$active" "" 0 "$boots"
	fi
	if [ "${{boots:-0}}" -ge 4 ] && whole "$(other $active)"; then
		say "slot $active failed $boots boots: on to $(other $active)"
		active=$(other $active)
		boots=0
	fi
	if ! sure "$active"; then
		active=$(other $active)
		# neither whole: nothing is mounted, the failure's line stays
		whole "$active" || return 0
	fi
	# what cannot be counted (the partition full) still boots, and a slot failed for ever stops here
	if [ "${{boots:-0}}" -lt 8 ]; then remember "$active" "" 0 $((${{boots:-0}} + 1)); slot=$active; fi
}}
own_kernel() {{
	here=$slots/$slot
	frame-guard arm
	say "kernel of slot $slot"
	pkill frame-loader
	line=$(uboot_line)
	if kexec -l $here/zImage --dtb=$here/board.dtb --initrd=$here/initramfs.cpio.gz --command-line="$line frame.slot=$slot"; then
		umount /data
		kexec -e
		reboot -f
	fi
	# never a trial of a kernel that did not run: spent, the next boot goes back
	say "kexec of slot $slot failed"
	[ -z "$trial" ] || remember "$active" "$pending" 0 "$boots"
	reboot -f
}}
# after a kexec, the first kernel chose (whatever name its initramfs gives the word: a `boot` from
# before this repository says another)
slot=$(sed -n 's/.*[a-z]\\.slot=\\([ab]\\).*/\\1/p' /proc/cmdline)
if [ -n "$data" ]; then
	device=/dev/$(grep "^DEVNAME=" $data | cut -d= -f2)
	# clean or journal replayed, it stops at the superblock; a full check (errors found) repairs
	# without optimising
	[ -n "$slot" ] || e2fsck -p -E fixes_only $device >/dev/null 2>&1
	if mount -t ext4 -o rw,noatime,nosuid,nodev,noexec $device /data; then
		if [ -n "$slot" ]; then
			[ "$(key pending)" = "$slot" ] && trial=1
		else
			# the picture of the slot that most likely starts, while its files may be read
			show $slots/$(key active) || show /splash
			choose
			[ -z "$slot" ] || [ ! -s $slots/$slot/zImage ] || own_kernel
		fi
		# no kernel of the slot's own takes over from here: the Wi-Fi, and the system's image read
		# once into memory (20 MB, half a second of an eMMC nothing else asks yet)
		wifi &
		[ -z "$slot" ] || cat $slots/$slot/rootfs.squashfs >/dev/null &
		[ -z "$slot" ] || show $slots/$slot || [ -n "$shown" ] || show /splash
	fi
fi

# 5. the system: its squashfs, read-only, a tmpfs over it, and the data partition at /data,
#    read-write for what the system keeps (/data/frame, and the product's own beside it); else
#    the failure's line stays
img=$slots/$slot/rootfs.squashfs
if [ -n "$payload" ]; then
	# the system from RAM, kept where switch_root leaves it, and a /data of RAM too, holding what
	# came with it (the Wi-Fi's network, the SSH host key)
	say "maintenance: the system from RAM, the data partition untouched"
	show /splash
	mv /payload/rootfs.squashfs /kept/ && img=/kept/rootfs.squashfs && slot=ram
	mount -t tmpfs -o mode=755 tmpfs /data && cp -a /payload/data/. /data/
	wifi &
fi
if [ -n "$slot" ] && loop=$(losetup -f) && losetup -r $loop $img && mount -t squashfs -o ro $loop /lower &&
	mount -t tmpfs -o mode=755 tmpfs /rw &&
	mkdir -p /rw/upper /rw/work && mount -t overlay overlay -o lowerdir=/lower,upperdir=/rw/upper,workdir=/rw/work /newroot; then
	say "system: $img"
	chown 0:0 /data
	# what of the Wi-Fi's firmware the kernel asks for once the system is the root, it finds there
	mkdir -p /newroot/lib/firmware && cp -r /kept/aic8800_fw /newroot/lib/firmware/
	# the panel and the touch panel are the product's from its first instant: its user's groups
	# (video, input: the system's own numbers) on their devices now, as udev will say again once it
	# has walked them, two seconds into the system
	group() {{ sed -n "s/^$1:[^:]*:\\([0-9]*\\):.*/\\1/p" /newroot/etc/group; }}
	video=$(group video) input=$(group input)
	[ -z "$video" ] || for node in /dev/dri/card*; do chgrp $video $node && chmod 660 $node; done
	[ -z "$input" ] || for node in /dev/input/event*; do chgrp $input $node && chmod 660 $node; done
	# one identity across boots: the journal stays one directory, its limit holds; what earlier
	# systems left under random ids goes
	id=$(sha256sum /sys/block/mmcblk0/device/cid | cut -c1-32)
	echo "$id" >/newroot/etc/machine-id
	for old in /data/frame/journal/*; do [ "$old" = /data/frame/journal/$id ] || rm -rf "$old"; done
	mkdir -p /newroot/data
	mount --move /data /newroot/data
	[ -z "$trial" ] || frame-guard 240 &
{handover}	for m in dev proc sys; do mount --move /$m /newroot/$m; done
	exec switch_root /newroot /sbin/init
fi
say "no system: slot $slot"
# a maintenance start that could not start its system says why where the tools read it back
# (bin/refit.sh): in the partition's own filesystem when it has one (a frame already refitted,
# tried again), else 4096 sectors into the partition it was to make, which holds nothing kept
if [ -n "$payload" ]; then
	set +x
	{{ echo "frame-maintenance-log"; dmesg | tail -n 60; cat /tmp/trace; }} >/tmp/log 2>/dev/null
	part=$(grep -l "^PARTNAME=data$" /sys/class/block/*/uevent | head -1)
	device=/dev/$(grep "^DEVNAME=" $part | cut -d= -f2)
	umount /data 2>/dev/null
	if mount -t ext4 -o rw,noatime $device /data 2>/dev/null; then
		mkdir -p /data/frame && cp /tmp/log /data/frame/maintenance.log
		umount /data
	else
		dd if=/tmp/log of=$device bs=512 seek=4096 conv=notrunc 2>/dev/null
	fi
	sync
fi
# what cannot even start spends its count here, so that the next boot chooses again
[ -z "$slot" ] || reboot -f
pkill frame-loader
[ -c /dev/fb0 ] && cat /splash/splash.raw >/dev/fb0 && dd if=/splash/missing.raw of=/dev/fb0 bs={stride} seek={row} conv=notrunc 2>/dev/null
while :; do sleep 3600; done
"""


SLOTS = (Path(__file__).resolve().parents[1] / "system/rootfs/usr/local/lib/frame-slots").read_text()


def init(debug: bool) -> str:
    """The /init script; `debug` adds the blinks and the fixed wait of the bring-up."""
    return INIT.format(
        blink=BLINK if debug else "",
        console=CONSOLE if debug else "",
        handover=HANDOVER if debug else "",
        settle=SETTLE_DEBUG if debug else SETTLE,
        slots=SLOTS,
        stride=splash.STRIDE,
        row=splash.STRIP_ROW,
    )


def build(tools: Path, firmware: Path, debug: bool = False, keys: tuple[Path, ...] = (), payload: Path | None = None) -> bytes:
    entries, ino = [], [300000]

    def add(name, data=b"", mode=0o100644):
        ino[0] += 1
        entries.append({"name": name, "data": data, "ino": ino[0], "mode": mode, "uid": 0, "gid": 0, "nlink": 1, "mtime": 0})

    for d in ("bin", "dev", "etc", "proc", "sys", "lib", "lib/modules", "lib/firmware", "lib/firmware/silead", "splash", "keys"):
        add(d, mode=0o40755)
    parts = AIC8800_FIRMWARE.split("/")
    for i in range(2, len(parts)):
        add("/".join(parts[: i + 1]), mode=0o40755)
    add("init", init(debug).encode(), 0o100755)
    add("etc/e2fsck.conf", E2FSCK_CONF.encode())
    add("bin/mksh", (tools / "mksh").read_bytes(), 0o100755)
    add("bin/toybox", (tools / "toybox").read_bytes(), 0o100755)
    for tool in ("frame-loader", "frame-guard", "kexec", "e2fsck"):
        add(f"bin/{tool}", (tools / tool).read_bytes(), 0o100755)
    add("bin/frame-seal", SEAL.read_bytes(), 0o100755)
    for n, key in enumerate(keys):
        if len(bytes.fromhex(key.read_text().strip())) != 32:
            raise SystemExit(f"{key}: not a release key's public half")
        add(f"keys/{n}.pub", key.read_bytes())
    for applet in (tools / "applets.txt").read_text().split():
        if applet not in ("mksh", "toybox", "sh"):
            add(f"bin/{applet}", b"toybox", 0o120777)
    add("bin/sh", b"mksh", 0o120777)
    add(FIRMWARE, firmware.read_bytes())
    for name in ("regulatory.db", "regulatory.db.p7s"):
        add(f"lib/firmware/{name}", (REGDB / name).read_bytes())
    for name, data in splash.builtin().items():
        add(f"splash/{name}", data)
    for ko in ("aic8800_bsp.ko", "aic8800_fdrv.ko"):
        add(f"lib/modules/{ko}", (AIC8800 / ko).read_bytes())
    for f in sorted((AIC8800 / "firmware").iterdir()):
        add(f"{AIC8800_FIRMWARE}/{f.name}", f.read_bytes())
    if payload:
        entries += carried.entries(payload)
    return bootimg.write_cpio(entries)


def main() -> int:
    args = sys.argv[1:]
    debug = args[:1] == ["--debug"]
    args = args[1:] if debug else args
    keys, payload = [], None
    while args[:1] in (["--key"], ["--payload"]) and len(args) > 1:
        if args[0] == "--key":
            keys.append(Path(args[1]))
        else:
            payload = Path(args[1])
        args = args[2:]
    if len(args) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    out = Path(args[2])
    # in the kernel it goes as it is (the zImage's compression is the only one undone at boot); a
    # slot's own, which kexec loads, is gzip's
    cpio = build(Path(args[0]), Path(args[1]), debug, tuple(keys), payload)
    out.write_bytes(gzip.compress(cpio, compresslevel=9, mtime=0) if out.suffix == ".gz" else cpio)
    print(f"{out}: {out.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
