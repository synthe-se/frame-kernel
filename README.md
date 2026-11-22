# frame-kernel

Mainline Linux for the Frameo photo frame (AMABOO GBZK-Y1000: Rockchip RK3126, four Cortex-A7,
Mali-400, 1 GB, an 800×1280 panel, a touch panel, Wi-Fi, an accelerometer): its kernel, its
device tree, its Wi-Fi driver, its initramfs, its Buildroot system, its updates, and the recipes
that build, try, install and flash them.

The board's repository, and no product's: it names none. What runs on the frame is a product,
kept in its own repository and given here by its path: Maison's wall screen
(`synthe-se/maison`) is one.

## The recipes

`just` lists them. The ones a day is made of:

```
just kernel                             the kernel, the device tree, the Wi-Fi driver
just boot                               the initramfs and the image `boot` holds
just image ../maison/frame/product     a product's system
just try                                the kernel tried from RAM, `boot` untouched
just install ../maison/frame/product   a product's system to the free slot, tried and proved
just flash                              the kernel written to `boot`
just boot-time                          what the last boot cost
just check                              the tests that need no frame
```

Builds run in Docker (an arm64 host builds without emulation); sources are pinned and checked
against their publishers' sums; nothing built is kept in the repository (`build/`). What is
private stays in `$FRAME_HOME` (`~/maison-frame` by default): the vendor's backup and what was
read from it, the SSH certificate authority, the products' release keys.

## Where things are

| | |
|---|---|
| `board/` | the kernel's configuration (`allnoconfig` + `linux.config`: a symbol not there is not built), the device tree, the patches to Linux and to the Wi-Fi driver |
| `boot/` | the initramfs (`initramfs.py` writes its `/init`), the boot pictures (`splash.py`), the loader's ring and the trial's guard, the image `boot` holds, the static tools |
| `system/` | the Buildroot configuration every product starts from, and the frame's own files: its units, its Wi-Fi, its slots |
| `tools/` | `frame-update`, `frame-wifid`, `frame-power-key` on the frame, `frame-sign` on the build machine (Rust) |
| `bin/` | what the recipes run |
| `tests/` | the boot's choice of a slot, run on this machine with the frame's commands stubbed |

## A product

A directory of the product's repository. The frame's system is built around it:

| | |
|---|---|
| `product.conf` | what it is called and how it looks before it draws (below) |
| `rootfs/` | its files, laid out as the frame's root: its unit, its launcher |
| `preset` | systemd preset lines: its unit, and which of the frame's it wants (`frame-wifid`, `frame-power-key`, `frame-wifi-watch`) |
| `defconfig` | Buildroot packages it needs beyond the frame's own |
| `build.sh <root>` | builds its programs on the build machine and lays them under `<root>` |
| `build-target.sh <root>` | the same inside the build's container, for programs that link the frame's libraries |
| `release.pub` | the key its updates are signed with (`frame-sign keygen`), when it has an update address |

`product.conf` is `KEY=value` lines:

| | |
|---|---|
| `NAME` | lower case; names its build (`build/<NAME>`) |
| `TITLE` | as a person reads it; names the frame's own Wi-Fi |
| `HOST` | the frame answers as `<HOST>.local` |
| `UNIT` | the unit a boot is judged on: 45 s running without a restart and the system is kept |
| `HEARTBEAT` | a file the product touches while it draws, if it wants to be judged on that too |
| `TURN` | how its picture lies on the panel, a quarter clockwise at a time: 0, 90, 180, 270 |
| `GROUND`, `INK` | the boot picture's ground and the loader's ring, `#rrggbb` |
| `MARK`, `MARK_HEIGHT` | the boot picture's mark, an SVG beside `product.conf`, and its height in pixels |
| `UPDATE_URL` | where its frames look for updates, `https://…`; none, no update over the air |
| `UPDATE_HOST` | where a release is published for them, as rsync names it (`host:/srv/updates/…`) |
| `BUILDROOT_FIRST` | packages `build-target.sh` links, built before it |

What a product may count on: the `kiosk` user (groups `video`, `render`, `input`), the frame's
data partition at `/data` with a directory of its own to make there, `/etc/frame/` saying what the system
is, `frame-loader` to stop when it draws its first picture, and the accelerometer under
`/sys/bus/iio`.

## How a frame starts

U-Boot (the vendor's) draws a picture and starts the kernel in `boot`, which holds its
initramfs. Its `/init` mounts the data partition, where two slots, `a` and `b`, each hold a system (a
squashfs), its boot picture, and perhaps a kernel of its own; it draws the slot's picture,
chooses the slot (an update on trial, a system that failed four boots, a slot not whole), and
starts it under a tmpfs: the system runs from RAM and never writes to itself. `frame-commit`
then proves the boot or restarts the frame, and the initramfs comes back to the slot before.
No update writes `boot`: its kernel is what any failure comes back to.

## Licence

MIT (`LICENCE`). The patches to Linux and to Buildroot follow the licences of the projects they
change.
