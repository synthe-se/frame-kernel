"""The initramfs's /init, run on this machine: the frame's commands stubbed, its paths in a
temporary directory. What a boot does to the slots is the one thing a frame cannot get wrong.

    python3 -m unittest discover -s tests
"""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "boot"))
import initramfs  # noqa: E402


def stubs(root: Path, **scripts) -> None:
    """Commands of the frame, each a /bin/sh body, first in PATH."""
    bin_dir = root / "stubs"
    bin_dir.mkdir(exist_ok=True)
    for name, body in scripts.items():
        path = bin_dir / name.replace("frame_", "frame-")
        path.write_text(f"#!/bin/sh\nROOT={root}\nLOG=$ROOT/log\n{body}\n")
        path.chmod(0o755)


def rooted(text: str, root: Path, *directories: str) -> str:
    """A script of the frame with its absolute paths under `root`."""
    names = "|".join(re.escape(d) for d in directories)
    return re.sub(rf"(?<![\w.$}}/])/({names})\b", rf"{root}/\1", text)


class Text(unittest.TestCase):
    def test_it_parses(self):
        for debug in (False, True):
            subprocess.run(["sh", "-n"], input=initramfs.init(debug).encode(), check=True)

    def test_it_names_no_product(self):
        for debug in (False, True):
            boot = initramfs.init(debug)
            # the one mention: where a frame's first product kept the slots, to bring them over
            self.assertEqual(set(re.findall(r"\S*maison\S*", boot)) - {"/android-data/maison/slots", "/android-data/maison/journal;"}, set())

    def test_no_root_console_and_no_blink_but_in_a_bring_up_image(self):
        boot, debug = initramfs.init(False), initramfs.init(True)
        for only in ("ttyGS0", "usb_gadget", "mksh -i", "echo 10 >$b", "sleep 8"):
            self.assertNotIn(only, boot)
            self.assertIn(only, debug)

    def test_nothing_waits_by_the_second(self):
        boot = initramfs.init(False)
        self.assertEqual(re.findall(r"sleep 1\b", boot), [])
        self.assertIn("sleep 0.05", boot)

    def test_the_slots_words_are_the_systems(self):
        boot = initramfs.init(False)
        self.assertIn(initramfs.SLOTS, boot)
        self.assertIn("printf 'active=%s\\npending=%s\\ntries=%s\\nboots=%s\\n'", boot)
        self.assertIn("sync && mv $state.new $state && sync", boot)

    def test_a_power_cut_finds_userdata_looked_at_and_closed_to_devices_and_programs(self):
        boot = initramfs.init(False)
        self.assertLess(boot.index("e2fsck -p"), boot.index("mount -t ext4"))
        self.assertIn("-o rw,noatime,nosuid,nodev,noexec", boot)
        self.assertEqual(initramfs.E2FSCK_CONF, "[options]\nbroken_system_clock = 1\n")

    def test_a_kernel_of_its_own_starts_armed_with_userdata_let_go(self):
        boot = initramfs.init(False)
        self.assertLess(boot.index("frame-guard arm"), boot.index("kexec -l"))
        self.assertLess(boot.index("umount /android-data"), boot.index("kexec -e"))
        self.assertLess(boot.index("kexec -l"), boot.index("wifi &"))
        self.assertLess(boot.index("frame-guard 240"), boot.index("exec switch_root"))


class Boot(unittest.TestCase):
    PATHS = ("sys", "proc", "dev", "android-data", "lower", "rw", "newroot", "tmp", "splash", "lib", "kept")
    PROVED = "active=a\npending=\ntries=0\nboots=0\n"
    UNPROVED = "active=a\npending=\ntries=0\nboots=1\n"
    TRIAL = "active=a\npending=b\ntries=2\nboots=0\n"

    def boot(self, state, kernels="", broken="", missing="", at="frame", pictures="", cmdline="root=x console=tty0 y", keys=None):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        root = self.root = Path(d.name)
        (root / "log").touch()
        for name in self.PATHS:
            (root / name).mkdir()
        slots = root / f"android-data/{at}/slots"
        for slot in "ab":
            (slots / slot).mkdir(parents=True)
            if slot not in missing:
                (slots / slot / "rootfs.squashfs").write_text("s")
            if slot in kernels:
                (slots / slot / "zImage").write_text("z")
            if slot in broken:
                (slots / slot / "bad").touch()
            if slot in pictures:
                (slots / slot / "splash.raw").write_text("p")
                (slots / slot / "splash.conf").write_text("1 2 0x0 0x1 120\n")
        if state is not None:
            (slots / "state").write_text(state)
        (root / "sys/class/block/p").mkdir(parents=True)
        (root / "sys/class/block/p/uevent").write_text("PARTNAME=userdata\nDEVNAME=p\n")
        (root / "proc/cmdline").write_text(cmdline + "\n")
        (root / "newroot/etc/systemd/system").mkdir(parents=True)
        (root / "newroot/lib").mkdir()
        if keys:
            __import__("shutil").copytree(keys, root / "keys")
        (root / "lib/modules").mkdir()
        for ko in ("aic8800_bsp.ko", "aic8800_fdrv.ko"):
            (root / "lib/modules" / ko).write_text("m")
        (root / "lib/firmware/aic8800_fw/SDIO/aic8800DC").mkdir(parents=True)
        (root / "lib/firmware/aic8800_fw/SDIO/aic8800DC/fw.bin").write_text("f")
        (root / "sys/class/net/wlan0").mkdir(parents=True)
        (root / "splash/splash.raw").write_text("p")
        (root / "splash/splash.conf").write_text("3 4 0x0 0x1 120\n")
        # the panel, as a file the test can read back
        (root / "dev/fb0").touch()
        logged = 'echo "$(basename "$0") $*" >>$LOG'
        stubs(
            root,
            mount=logged,
            umount=logged,
            e2fsck=logged,
            kexec=logged,
            insmod=logged,
            losetup=f'if [ "$1" = -f ]; then echo loop; else {logged}; fi',
            switch_root=logged,
            frame_guard=logged,
            frame_loader=logged,
            pkill=":",
            # what the Wi-Fi's load keeps for after this root: here, it logs
            toybox=logged,
            chown=":",
            sync=":",
            sleep='[ "$1" != 3600 ] || kill -9 $PPID',
            reboot=f"{logged}\nkill -9 $PPID",
            sha256sum="echo 0123456789abcdef0123456789abcdef",
            # check [--whole] <slot> <keys…>: a slot is there with its system, whole unless marked bad
            frame_seal='shift; whole=; [ "$1" != --whole ] || { whole=1; shift; }; [ -s "$1/rootfs.squashfs" ] || exit 1; [ -n "$whole" ] || exit 0; echo "sums $(basename "$1") $2" >>$LOG; [ ! -e "$1/bad" ]',
        )
        text = rooted(initramfs.init(False), root, *self.PATHS, "keys").replace("export PATH=/bin", f"export PATH={root}/stubs:$PATH")
        text = text.replace("seal=/usr/local/bin/frame-seal\n[ -x $seal ] || seal=/bin/frame-seal", "seal=frame-seal")
        text = text.replace(f" /bin/toybox {root}/kept/", f" {root}/stubs/toybox {root}/kept/")
        # a file stands for the framebuffer's device
        text = text.replace(f"[ -c {root}/dev/fb0 ]", f"[ -e {root}/dev/fb0 ]")
        init = root / "init"
        init.write_text(text)
        done = subprocess.run(["sh", str(init)], capture_output=True, timeout=30, text=True)
        self.errors = done.stderr
        # the Wi-Fi's load outlives the script, as it outlives the initramfs
        import time
        for _ in range(100):
            if "ifconfig" in (root / "log").read_text() or "wifi &" not in text or not any(l.startswith("insmod") for l in (root / "log").read_text().splitlines()):
                break
            time.sleep(0.1)
        kept = root / "android-data/frame/slots/state"
        return (root / "log").read_text().splitlines(), kept.read_text() if kept.exists() else None

    @staticmethod
    def started(log):
        return [line.split("/")[-2] for line in log if line.startswith("losetup")]

    @staticmethod
    def read(log):
        return [line.split()[1] for line in log if line.startswith("sums")]

    def test_a_slot_that_proved_itself_starts_without_its_sums_read(self):
        log, state = self.boot(self.PROVED)
        self.assertEqual((self.read(log), self.started(log)), ([], ["a"]), self.errors)
        self.assertEqual(state, "active=a\npending=\ntries=0\nboots=1\n")
        self.assertTrue(any(line.startswith("switch_root") for line in log))

    def test_a_slot_whose_last_boot_proved_nothing_has_its_sums_read(self):
        log, state = self.boot(self.UNPROVED)
        self.assertEqual((self.read(log), self.started(log)), (["a"], ["a"]))
        self.assertIn("boots=2", state)

    def test_a_slot_that_fails_its_sums_gives_way_to_the_other(self):
        log, state = self.boot(self.UNPROVED, broken="a")
        self.assertEqual((self.read(log), self.started(log)), (["a", "b"], ["b"]))
        self.assertEqual(state, "active=b\npending=\ntries=0\nboots=2\n")

    def test_a_proved_slot_whose_system_is_gone_gives_way_to_the_other(self):
        log, _ = self.boot(self.PROVED, missing="a")
        self.assertEqual(self.started(log), ["b"])

    def test_neither_slot_whole_nothing_is_mounted(self):
        log, _ = self.boot(self.UNPROVED, broken="ab")
        self.assertEqual(self.started(log), [])
        self.assertFalse(any(line.startswith("switch_root") for line in log))

    def test_a_slot_is_checked_under_the_keys_the_image_was_built_with(self):
        (keys := Path(tempfile.mkdtemp())).joinpath("0.pub").write_text("k")
        self.addCleanup(lambda: __import__("shutil").rmtree(keys))
        log, _ = self.boot(self.UNPROVED, keys=keys)
        self.assertEqual([line for line in log if line.startswith("sums")], [f"sums a {self.root}/keys/0.pub"])
        # a bring-up image has none: the signature is not asked
        log, _ = self.boot(self.UNPROVED)
        self.assertEqual([line for line in log if line.startswith("sums")], ["sums a "])

    def test_a_try_is_read_whole_and_counted_before_it_starts(self):
        log, state = self.boot(self.TRIAL)
        self.assertEqual((self.read(log), self.started(log)), (["b"], ["b"]))
        self.assertEqual(state, "active=a\npending=b\ntries=1\nboots=0\n")
        self.assertIn("frame-guard 240", log)

    def test_a_try_that_fails_its_sums_is_never_mounted(self):
        log, state = self.boot(self.TRIAL, broken="b")
        self.assertEqual(self.started(log), ["a"])
        self.assertEqual(state, "active=a\npending=\ntries=0\nboots=1\n")
        self.assertEqual((self.root / "android-data/frame/slots/failed").read_text(), "b\n")

    def test_a_try_out_of_tries_goes_back(self):
        log, state = self.boot("active=a\npending=b\ntries=0\nboots=0\n")
        self.assertEqual(self.started(log), ["a"])
        self.assertIn("pending=\n", state)

    def test_four_boots_without_a_proof_take_the_other_slot(self):
        log, state = self.boot("active=a\npending=\ntries=0\nboots=4\n")
        self.assertEqual(self.started(log), ["b"])
        self.assertEqual(state, "active=b\npending=\ntries=0\nboots=1\n")

    def test_eight_boots_and_the_slot_never_starts_again(self):
        log, _ = self.boot("active=a\npending=\ntries=0\nboots=8\n", broken="b")
        self.assertEqual(self.started(log), [])

    def test_no_state_takes_what_is_whole(self):
        log, state = self.boot(None, broken="a")
        self.assertEqual(self.started(log), ["b"])
        self.assertIn("active=b", state)

    def test_a_slot_with_its_kernel_starts_it_and_mounts_nothing(self):
        log, _ = self.boot(self.PROVED, kernels="a")
        self.assertTrue([line for line in log if line.startswith("kexec -l")])
        self.assertIn("frame.slot=a", next(line for line in log if line.startswith("kexec -l")))
        self.assertEqual(self.started(log), [])
        self.assertLess(log.index("frame-guard arm"), next(i for i, line in enumerate(log) if line.startswith("kexec -l")))

    def test_the_wifi_loads_beside_the_boot_and_its_firmware_follows_the_system(self):
        log, _ = self.boot(self.PROVED)
        self.assertEqual(len([line for line in log if line.startswith("insmod")]), 2)
        # its address, the same at every boot, from the eMMC's serial
        self.assertIn("toybox ifconfig wlan0 hw ether 02:01:23:45:67:89", log)
        self.assertTrue((self.root / "newroot/lib/firmware/aic8800_fw/SDIO/aic8800DC/fw.bin").exists())
        boot = initramfs.init(False)
        # never before a slot's own kernel could take over, never waited for
        self.assertLess(boot.index("|| own_kernel"), boot.index("wifi &"))
        self.assertNotIn("await '[ -d /sys/class/net/wlan0 ]'", boot)

    def test_after_a_kexec_the_slot_is_the_first_kernels_word_whatever_it_calls_it(self):
        for word in ("frame.slot=b", "maison.slot=b"):
            log, state = self.boot(self.PROVED, kernels="ab", cmdline=f"root=x console=tty0 y {word}")
            self.assertEqual(self.started(log), ["b"], word)
            self.assertFalse([line for line in log if line.startswith("kexec")])
            # the first kernel counted the boot: nothing is counted twice
            self.assertEqual(state, self.PROVED)

    def test_slots_kept_under_the_first_products_name_are_brought_over_once(self):
        log, state = self.boot(self.PROVED, at="maison")
        self.assertEqual(self.started(log), ["a"])
        self.assertIn("boots=1", state)
        old = self.root / "android-data/maison/slots"
        self.assertTrue(old.is_symlink())
        self.assertEqual((old / "state").read_text(), state)

    def test_the_picture_is_the_slots_own_and_the_frames_for_want_of_one(self):
        log, _ = self.boot(self.PROVED, pictures="a")
        self.assertEqual([line for line in log if line.startswith("frame-loader")], ["frame-loader 1 2 0x0 0x1 120"])
        log, _ = self.boot(self.PROVED)
        self.assertEqual([line for line in log if line.startswith("frame-loader")], ["frame-loader 3 4 0x0 0x1 120"])

    def test_a_try_shows_its_own_picture(self):
        log, _ = self.boot(self.TRIAL, pictures="b")
        self.assertEqual([line for line in log if line.startswith("frame-loader")][-1], "frame-loader 1 2 0x0 0x1 120")


if __name__ == "__main__":
    unittest.main()
