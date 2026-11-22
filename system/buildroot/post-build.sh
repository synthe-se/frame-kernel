#!/bin/sh
# What the overlay cannot say: the product (its files, its name, its units), the frame's tools, who
# may come in, the journal kept on userdata, the names OpenSSH uses, the units enabled. $1 is the
# target's root; bin/system.sh leaves what it built in /tmp, the product's files in /staging and
# what it says of itself in /product.env, and mounts the CA's public key.
set -eu
root=$1
. /product.env
strip="$HOST_DIR/bin/arm-buildroot-linux-gnueabihf-strip"
for tool in frame-update frame-wifid frame-power-key; do
	install -D -m 0755 "/tmp/$tool" "$root/usr/local/bin/$tool"
	"$strip" "$root/usr/local/bin/$tool"
done
# Buildroot keeps its target from one build to the next, and copies the overlay over it: a file
# this repository or the product no longer has would stay in every image. What the last build laid
# there and this one does not is removed first
laid=$BASE_DIR/frame-files
{ cd /frame/system/rootfs && find . -type f -o -type l; cd /staging && find . -type f -o -type l; [ ! -d /tmp/product ] || { cd /tmp/product && find . -type f -o -type l; }; } | sort -u >"$laid.new"
[ ! -s "$laid" ] || comm -23 "$laid" "$laid.new" | while read -r gone; do rm -f "$root/$gone"; done
mv "$laid.new" "$laid"
find "$root/etc/systemd/system" -depth -type d -empty -delete
# the product's own files over the frame's: its programs, its units, what it changes
cp -a /staging/. "$root/"
[ ! -d /tmp/product ] || cp -a /tmp/product/. "$root/"
# what this system is: the product, the unit a boot is judged on, the image's number, where its
# updates live (none without an address) and the key they are signed with
mkdir -p "$root/etc/frame"
printf '%s\n' "$NAME" >"$root/etc/frame/product"
printf '%s\n' "$TITLE" >"$root/etc/frame/name"
printf '%s\n' "$UNIT" >"$root/etc/frame/unit"
[ -z "${HEARTBEAT-}" ] || printf '%s\n' "$HEARTBEAT" >"$root/etc/frame/heartbeat"
printf '%s\n' "$IMAGE_VERSION" >"$root/etc/frame/version"
if [ -n "${UPDATE_URL-}" ]; then
	printf '%s' "$UPDATE_URL" >"$root/etc/frame/update-url"
	install -m 0644 /release.pub "$root/etc/frame/release.pub"
fi
printf '%s\n' "$HOSTNAME" >"$root/etc/hostname"
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME/" "$root/etc/hosts"
# who may come in: the CA's certificates, no key on the frame (bin/ssh-cert.sh)
install -m 0644 /ssh-ca.pub "$root/etc/ssh/frame-ca.pub"
# one known board: no table of the world's hardware (the option alone leaves what systemd installed)
rm -f "$root/usr/lib/udev/hwdb.bin"
rm -rf "$root/usr/lib/udev/hwdb.d"
# the initramfs gives a root that writes (a tmpfs over the system): nothing remounts it
sed -i '\|^/dev/root|d' "$root/etc/fstab"
# every name is asked of the frame's own resolver: a program linked static asks the servers of
# /etc/resolv.conf itself, and the ones the network gave know no name.local, which resolved answers
# (mDNS: the evening's server, another frame)
ln -sf ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
# the kernel has no SysRq to set
sed -i '/kernel.sysrq/d' "$root/usr/lib/sysctl.d/50-default.conf"
# systemd already starts dbus-daemon as its user: asked again, it fails to drop groups and warns
sed -i '/<user>dbus<\/user>/d' "$root/usr/share/dbus-1/system.conf"
# the journal on userdata, kept across power cuts (frame-data makes the directory)
mkdir -p "$root/var/log"
rm -rf "$root/var/log/journal"
ln -s /android-data/frame/journal "$root/var/log/journal"
ln -sf /dev/null "$root/etc/tmpfiles.d/journal-nocow.conf"
# OpenSSH's own unit and configuration: ours in a drop-in, the host keys made on the frame
rm -rf "$root/etc/systemd/system/sshd.service.d"
mv "$root/etc/systemd/system/ssh.service.d" "$root/etc/systemd/system/sshd.service.d"
grep -q '^Include /etc/ssh/sshd_config.d/' "$root/etc/ssh/sshd_config" ||
	sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$root/etc/ssh/sshd_config"
rm -f "$root"/etc/ssh/ssh_host_*
"$HOST_DIR/bin/systemctl" --root="$root" set-default multi-user.target
"$HOST_DIR/bin/systemctl" --root="$root" mask systemd-firstboot
# nothing reads these on a frame: the kernel's debug files stay a `mount -t debugfs` away, no
# program speaks FUSE, the root is the initramfs's and never remounted, and no module asks for a
# device node made ahead of it (the two units that would make them hold udev, and the network
# behind it, a second back)
for unit in sys-kernel-debug.mount sys-kernel-tracing.mount sys-fs-fuse-connections.mount modprobe@.service \
	systemd-remount-fs.service systemd-network-generator.service systemd-pcrphase.service \
	systemd-tmpfiles-setup-dev-early.service systemd-tmpfiles-setup-dev.service; do
	ln -sf /dev/null "$root/etc/systemd/system/$unit"
done
# what runs is said as a preset: Buildroot's `preset-all` comes after this script and would undo an
# `enable` (the packaged wpa_supplicant units stay off: one wants a D-Bus name, the other waits for udev)
{
	# the product's own units, and which of the frame's it wants (the Wi-Fi's service for its
	# interface, the power key, the network's watch): its word comes first, the first word wins
	[ ! -s /product/preset ] || cat /product/preset
	cat <<PRESET
enable systemd-networkd.service
enable systemd-resolved.service
enable systemd-timesyncd.service
enable sshd.service
enable frame-wpa.service
enable frame-commit.service
enable frame-update.timer
disable wpa_supplicant.service
disable wpa_supplicant@.service
# what only a product with a use for them asks for
disable frame-wifid.service
disable frame-power-key.service
disable frame-wifi-watch.service
# no login prompt on a product, no network file systems
disable getty@.service
disable serial-getty@.service
disable remote-fs.target
PRESET
} >"$root/usr/lib/systemd/system-preset/10-frame.preset"
# the clock's floor without its file on userdata: never before this image was made
touch "$root/usr/lib/clock-epoch"
