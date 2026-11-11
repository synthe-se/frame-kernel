# frame-kernel

Mainline Linux for the Frameo photo frame (AMABOO GBZK-Y1000: Rockchip RK3126, four Cortex-A7,
Mali-400, 1 GB, an 800×1280 panel): its kernel configuration and patches, its device tree, the
Wi-Fi driver, the Buildroot system, the initramfs, and the tools that build, send, try and flash
them.

The board's repository, apart from the products that run on it: Maison's wall screen
(`synthe-se/maison`) is one.

## Where it comes from

Split from `frame/linux` of `synthe-se/maison` on 2026-11-11, with its history. Maison keeps its
own copy until it builds from here. What the bring-up taught, each point seen on the frame, is
in Maison's `docs/frame.md`, « Mainline Linux », to come here with the rest.

## What is still Maison's in here

The split took the directory as it was. To untangle, so that each product composes its own
image on a system that names none:

- the names: `maison.config`, `maison_defconfig`, the units and programs called `maison-*`;
- Maison's interface in the image (`maison-ui.service`, its launcher, `buildroot.sh`
  cross-building `frame/ui` beside it), its update address and its boot picture;
- what the scripts expect beside them in Maison: `frame/tools` (the Wi-Fi's root service and
  its protocol, the release's public key), `frame/build`, and the vendor's files and the keys
  in `~/maison-frame`.

## Next

The frame's accelerometer (a SC7A20 at 0x19 in the vendor's device tree): no IIO in the
kernel's configuration yet, no node in the device tree. With it a product reads gravity and
knows which way the frame is laid.

## Licence

MIT, as Maison (`LICENCE`). The patches to Linux and to Buildroot follow the licences of the
projects they change.
