# The frame's recipes: one board, any product. A product is a directory of its own repository
# (README « A product »), given by its path: `just image ../maison/frame/product`.

# What can be done.
default:
    @just --list --unsorted

# The kernel, the device tree and the Wi-Fi driver: build/linux.
kernel:
    bin/kernel.sh

# The initramfs's static tools (once): build/tools.
tools:
    boot/tools.sh build/tools

# The initramfs, and the image `boot` holds, the kernel with it inside: build/boot.img. The products
# given are the ones this frame may start: a slot whose manifest none of their release keys signed
# is refused. None given: a bring-up image, which asks no signature.
boot *products:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -x build/tools/toybox ] || just tools
    [ -s build/linux/zImage ] || just kernel
    (cd tools/seal && cargo build -q --release --locked --target armv7-unknown-linux-musleabihf)
    keys=()
    for product in {{products}}; do
        [ -s "$product/release.pub" ] || { echo "$product: no release.pub (bin/sign.sh makes its key)" >&2; exit 1; }
        keys+=(--key "$product/release.pub")
    done
    firmware="${FRAME_HOME:-$HOME/maison-frame}/recon/gslX680.fw"
    python3 -I boot/initramfs.py "${keys[@]}" build/tools "$firmware" build/initramfs.cpio
    python3 -I boot/initramfs.py "${keys[@]}" build/tools "$firmware" build/initramfs.cpio.gz
    bin/kernel.sh --initramfs build/initramfs.cpio
    python3 -I boot/image.py build/linux/zImage.boot build/linux/rk3126-amaboo-gbzk-y1000.dtb build/boot.img

# A product's system: build/<product>/rootfs.squashfs.
image product:
    bin/system.sh "{{product}}"

# A product's system to the frame's free slot, then the frame restarted and the system proved.
install product:
    bin/try.sh --install "{{product}}"

# A product's signed release for its frames over the air: build/<product>/release (--kernel, --publish).
release product *options:
    bin/release.sh "{{product}}" {{options}}

# On a frame two products share: the other product back from where it was put aside (no name: what runs, what is parked).
switch *product:
    bin/switch.sh {{product}}

# The kernel and the initramfs tried from RAM: `boot` untouched, a power cut undoes it.
try:
    bin/try.sh --ram

# The kernel written to `boot`, read back, and the frame restarted on it.
flash:
    bin/try.sh --flash

# A frame laid out for Android becomes the frame's own (docs/frame.md « A frame refitted »): prepare, dry, probe, go.
refit product stage:
    bin/refit.sh "{{product}}" {{stage}}

# A command on the frame, as root.
on +command:
    bin/console.sh "{{command}}"

# What a boot cost, from the frame that just made it.
boot-time:
    bin/console.sh 'systemd-analyze; dmesg | grep -E "frame:|Run /init|systemd\[1\]: systemd 2"; systemd-analyze blame | head -15' 40

# The tests that need no frame, and what the scripts' checkers say.
check:
    python3 -m unittest discover -s tests
    cd tools && cargo test --locked -q
    cd tools/seal && cargo test --locked -q
    shellcheck -x -P bin bin/*.sh boot/tools.sh system/buildroot/post-build.sh system/rootfs/usr/local/sbin/* system/rootfs/usr/local/lib/frame-slots
