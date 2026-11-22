# The frame, as it runs

What the README does not say: what the bring-up taught, how the pieces hold together, and what
was measured. Each point was seen on the frame.

## The board

- The panel stays black under a continuous DSI clock: the JD9365 is reset while the host's HS
  clock runs and never locks on the video. `MIPI_DSI_CLOCK_NON_CONTINUOUS` (`board/panel.py`
  generates the panel's sequence from the vendor's device tree).
- Switching PD_VIO off faults (a PMU register this chip lacks): no power domain on the VOP, the
  DSI and its PHY.
- The AIC8800DC answers only without the SoC's pulls on the SDIO lines (the board has its own),
  and with the vendor's power-on wait. No RTC on the board, despite the vendor's tree.
- No partition table mainline reads: userdata alone is declared (`blkdevparts=` in the kernel's
  command line, which has 1024 bytes, 700 of them U-Boot's).
- The touch chip's axes are swapped, 1024 down by 640 across; `touchscreen-size-*` are the
  chip's axes, before the swap.
- simpledrm left beside Rockchip's card is a second card, where a client would draw unseen.
- U-Boot draws its logo only with the vendor's device tree, kept in the boot image's resource,
  and takes the picture from the `resource` partition (`bin/try.sh --logo`), not from the image.
  The kernel ignores that device tree: ours follows the zImage (`ARM_APPENDED_DTB`). U-Boot moves
  an image's initramfs and says so only in its own device tree, so the kernel of `boot` holds its
  initramfs (`bin/kernel.sh --initramfs`); none of U-Boot's command line reaches it either.
- Powered up with the USB-C on a computer, U-Boot still boots `boot`; `misc` is ignored (a power
  cycle is the boot slot's): the loader comes from the reset pinhole.
- Nothing drives the CPU's rail: the vendor's tree names a regulator on PWM1, its kernel never
  got it, and PWM1's registers read zero. Its voltage is unknown, so it is never written:
  `cpu-supply` stays out, and the OPPs change the clock alone. There is no temperature sensor
  either. A frequency enters the device tree only after holding under load on the frame, each
  result checked against a reference: 1008 MHz, the vendor's own top, held 8 minutes on all four
  cores. Above it is unproven.
- The accelerometer is a Silan SC7A20 beside the touch chip (i2c2, 0x19; it answers 0x11 to
  WHO_AM_I), polled, no interrupt wired: mainline's `st_accel` reads it as `iio:device0`. Its
  axes are the chip's own; what they mean for the person is each product's to read.

The kernel is `allnoconfig` + `board/linux.config`: every symbol is said there, a dropped one and
any warning of the build fail `bin/kernel.sh`. `VMSPLIT_2G`: all of the 1 GB directly mapped, no
highmem.

## How it starts, and how long it takes

Measured on a cold start, from the kernel's first line, with a product that draws straight on the panel
(a slot that proved itself at its last boot):

| | |
|---|---|
| the initramfs's `/init` runs | 1.7 s |
| the slot is chosen, its picture drawn, its system mounted | 2.2 s |
| the Wi-Fi's driver is loaded (beside the boot) | 3.0 s |
| the product's program starts | 4.6 s |
| the Wi-Fi is associated | 6.9 s |
| the frame has its address | 7.0 s |

U-Boot's own time, before the kernel, is not in these: the kernel's log does not see it.

What it took, each a wait found and removed (the same frame took 15.5 s to start its product
before them, 16 s to an address):

- A slot's files were read through SHA-256 at every boot: 4.6 s for 28 MB on this processor. A
  slot that proved itself at its last boot is only looked at (each file there, of its size, under
  a manifest its product's key signed); it is read whole when it is on trial or when the last
  boot proved nothing.
- The initramfs waited by the second (`sleep 1`) for the eMMC, the framebuffer, the display and
  the Wi-Fi's interface: it asks every 50 ms.
- It waited for the Wi-Fi's driver before it started the system. The driver loads beside the
  boot, kept with its firmware on a tmpfs `switch_root` does not empty, and gives the interface
  its address itself.
- U-Boot leaves the processor at 600 MHz: the initramfs asks for its fastest clock at once, and
  `frame-commit` gives the clock back to the governor once the boot is proved.
- The initramfs was compressed inside a compressed kernel: it goes in as it is.
- A unit with systemd's default dependencies waits for `sysinit.target`, which waits for udev's
  walk of every device, the journal's flush and the temporary files: three seconds. The product's
  unit, the Wi-Fi's and the frame's own data have none; the panel and the touch panel are given
  to the product's groups by the initramfs, before udev says the same.
- udev walked 267 devices (67 virtual consoles, 41 platform devices…) in two seconds of all four
  processors: it walks the ones something asks about.
- wpa_supplicant's packaged unit waits for udev to name the interface; the frame's own
  (`frame-wpa.service`) does not. No Wi-Fi Direct (0.4 s at each start).
- The network is taken for granted while it may be (`frame-wifi`, `frame-commit`): the channel
  the access point was on at the last boot is the only one scanned, and the address the frame
  was lent is its own from the moment it joins, while that lease lasts and for that network
  alone, DHCP asking again beside it. Four seconds without an association and the scan is every
  channel's again; a lease the network no longer gives is forgotten.
- Reading the compressed system is not what costs: systemd's own libraries read cold in 90 ms.
  Another compression would change nothing.

What is left: systemd itself, 1.6 s from the root's switch to its first unit; and whatever a
product does before its first picture.

## Slots, and what a frame trusts

Userdata holds two slots, `/android-data/frame/slots/{a,b}`, root's: a system, its boot picture,
and perhaps a kernel, its device tree and its initramfs. `boot` is written by none of them, only
by `bin/try.sh --flash`: its kernel is what any failure comes back to. `state` says `active`,
`pending`, `tries` and `boots`.

A slot is sealed (`tools/seal`, `frame-seal`): `manifest.json` names each file, its size and its
SHA-256, and `manifest.sig` is its Ed25519 signature by the product's release key. The initramfs
holds the public halves of the keys it was built with (`just boot <products>`) and starts nothing
no key signed: seen on the frame, a slot whose signature was altered is refused and the other
one starts. The private key never leaves the build machine (`$FRAME_HOME/keys/<product>.pk8`);
`bin/sign.sh` refuses a key that is not the pair of the product's `release.pub`.

The initramfs counts a try before it starts one (2 at first: a power cut spends one), starts a
slot's kernel by kexec, and watches from outside (`boot/guard.c`: 240 s, then a restart, whatever
became of PID 1; for a kernel, the SoC's watchdog left running, 30 s to reach systemd).
`frame-commit` keeps an update once the product's unit has run 45 s without a restart, drawing if
it says so (its heartbeat), with the Wi-Fi and SSH; else it restarts within 150 s. A system
already proved only has to run, so that a router out of order is no failure. Tries spent, the
slot goes to `slots/failed` and the frame stays on the one before. Each boot of the active slot
is counted the same way: 4 without a proof and the frame moves to the other, 8 and it stops on
the failure's line. e2fsck takes `broken_system_clock`: no RTC, a clock at 1970 must force no
full check. A slot's kernel adds a kexec to each boot until it is flashed to `boot`.

A system counts on the initramfs that starts it: the one in `boot`, which no update over the air
writes. A system that needs a newer one carries it in its slot (`--kernel`).

Failures provoked on the frame, each back on the good slot by itself: an image that fails its
check, an unreadable image that passes it, a kernel that panics, a kernel that hangs (a real
watchdog reset), a system whose Wi-Fi never comes up on trial.

Two products on one frame (`bin/switch.sh`): the one that runs is copied aside whole
(`/android-data/frame/parked/<product>`), checked, and the other comes back from there into the
free slot, on trial as any update. The free slot is any install's to overwrite. No install and
no switch starts while a system is on trial: the tools read the frame's state whole or not at
all (`bin/frame-state.sh`), an answer that did not come is never an empty answer.

## Over the air

A release is a slot's manifest, its signature and its files under `<version>/`, static files
over HTTPS, made by `bin/release.sh <product> [--kernel] [--publish]`. A product's
`UPDATE_URL` names where its frames look, `UPDATE_HOST` where a release is put. Each night
(`frame-update.timer`, 3 to 4 am) the frame reads the manifest, refuses what its product's key
did not sign, what is not newer, what failed here once, downloads to the free slot, resumed if
cut, and restarts to try it.

## The system

Buildroot (`system/buildroot/base_defconfig`, then the product's `defconfig`; a pinned release,
`0001-*.patch` for what it ships behind), every program tuned for the Cortex-A7. One tree per set
of packages, in a Docker volume named by it. What its build taught:

- Buildroot's `preset-all` runs after the post-build, on the image's copy: an `enable` there is
  undone. What runs is said in the preset the post-build writes, the product's word first.
- Buildroot keeps its target from one build to the next and copies the overlay over it: a file
  no longer in this repository stayed in every image, and a unit removed here kept running on
  the frame. The post-build removes what the last build laid and this one does not.
- Its timesyncd has no servers: they are named in `timesyncd.conf.d/frame.conf`. The clock comes
  back from the file on userdata before any network; `clock-epoch` is the floor if that file is
  lost. No battery and a system in RAM: the clock once came back six months behind.
- A system shares userdata with the one before it: `kiosk` stays uid 988, and `frame-data` gives
  the clock file to this system's user.
- Its fstab mounts `/` read-only, which turns the overlay read-only: the line is removed.
- A program linked static asks the servers of `/etc/resolv.conf` itself: it points at the
  frame's own resolver, which answers a `name.local` (mDNS) the network's servers do not know.
- The journal is kept on userdata (`/var/log/journal`): a boot that went wrong reads at the next
  one. The initramfs derives the machine id from the eMMC's serial, so that it stays one
  directory, within its 64 MB.

There is no console on a product's boot: no getty, no shell on the USB-C, root's password
locked. `boot/initramfs.py --debug` builds an image with a root shell on the USB-C, for bring-up
only. SSH is the way in: root by a certificate of the frames' CA only (`bin/ssh-cert.sh`,
8 hours, the CA in `$FRAME_HOME/keys`), no key on any frame, reachable from private networks
only, the host key made once on the frame and kept on userdata. The frame answers as
`<product's HOST>.local`; its Wi-Fi address comes from the eMMC's serial (the AIC8800's driver
would draw one per boot: a new lease, a new address), so the tools remember it by that address.

A file goes over the Wi-Fi by `bin/send.sh`, from Linux: scp, then the frame checks the SHA-256
before it renames the file. A new system and a new boot image go that way; `boot` is then
written by Linux on `/dev/mmcblk0` once the layout's addressing is proved (U-Boot's head where
`layout.txt` says, boot's `ANDROID!` header), read back and compared. The loader stays the way
back.

A frozen frame restarts alone: systemd feeds the SoC's watchdog (`RuntimeWatchdogSec`), an oops
panics, a panic reboots after 5 s.

## The Wi-Fi

`frame-wifi` writes what wpa_supplicant reads: the network the frame joined
(`/android-data/frame/wifi.conf`), else the ones Android knew. A product whose interface lets a
person join a network asks for `frame-wifid` in its preset: root, it answers the product over
`/run/frame-wifi/socket` (the directory 0750 root:kiosk), one JSON line each way: scan, list,
connect, status, nothing else (`tools/src/wifi.rs`). It is the boundary: a name goes in hex, a
password only as its 802.11i key (also what `wifi.conf` holds: never the password), a request is
at most 1 KiB, unknown fields are refused. A network is joined live and written to `wifi.conf`
only once associated: a wrong password loses nothing.

`frame-wifi-watch`: 10 minutes without associating, after boot or a lost link, and
`/run/frame-lost` says so for the product to show. `frame-power-key`: the power key held 10 s
opens the frame's own Wi-Fi (`frame-hotspot`), named after the product and locked from the
eMMC's serial, the last resort of a dead touch panel; the product's own page answers there
(`frame-setup.service`, if it ships one), and 30 minutes after its last request the frame
returns to its network without a restart.
