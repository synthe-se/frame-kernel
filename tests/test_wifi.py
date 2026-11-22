"""The frame's Wi-Fi scripts (frame-wifi, frame-wifi-watch, frame-hotspot), run on this machine
over a timeline of 15 s steps: the frame's commands stubbed, its paths in a temporary directory.

    python3 -m unittest discover -s tests
"""

import os
import re
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROOTFS = REPO / "system/rootfs"
SBIN = ROOTFS / "usr/local/sbin"


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


class Wifi(unittest.TestCase):
    PATHS = ("run", "sys", "android-data", "etc/wpa_supplicant", "etc/frame")
    OPEN = ["systemctl restart frame-wpa", "systemctl --no-block start frame-setup", "networkctl reload", "systemctl restart product.service"]
    BACK = ["systemctl stop frame-setup", "systemctl restart frame-wpa", "networkctl reload", "systemctl restart product.service"]
    OPERSTATE = "echo %s >$ROOT/sys/class/net/wlan0/operstate"
    # the power key held
    HELD = "frame-hotspot open"
    # a request on the product's page: it touches the file
    REQUEST = "touch -t 203001010000 $ROOT/run/frame-setup"
    HEAD = "ctrl_interface=/run/wpa_supplicant\ncountry=FR\np2p_disabled=1\n"

    def run_watch(self, until, events=None, state="active=a\npending=\ntries=0\nboots=0\n", wifi="network={\n\tssid=\"home\"\n}\n", known=None, wide=False):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        root = self.root = Path(d.name)
        frame = root / "android-data/frame"
        (frame / "slots").mkdir(parents=True)
        (frame / "slots/state").write_text(state)
        if wifi:
            (frame / "wifi.conf").write_text(wifi)
        if known:
            (frame / "wifi.known").write_text(known)
        (root / "run").mkdir()
        if wide:
            (root / "run/frame-wifi-wide").touch()
        (root / "etc/frame").mkdir(parents=True)
        (root / "etc/frame/unit").write_text("product.service\n")
        (root / "etc/frame/name").write_text("Product\n")
        (root / "sys/class/net/wlan0").mkdir(parents=True)
        (root / "sys/class/net/wlan0/operstate").write_text("dormant\n")
        (root / "sys/block/mmcblk0/device").mkdir(parents=True)
        (root / "sys/block/mmcblk0/device/cid").write_text("cid\n")
        (root / "log").touch()
        (root / "clock").write_text("0")
        (root / "at").mkdir()
        for at, command in (events or {}).items():
            (root / f"at/{at}").write_text(command)
        slots = (ROOTFS / "usr/local/lib/frame-slots").read_text()
        (root / "frame-slots").write_text(rooted(slots, root, *self.PATHS))
        for name in ("frame-wifi", "frame-wifi-watch", "frame-hotspot"):
            script = rooted((SBIN / name).read_text(), root, *self.PATHS)
            (root / name).write_text(script.replace("/usr/local/lib/frame-slots", f"{root}/frame-slots"))
        stubs(
            root,
            sha256sum="echo 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            sleep=f"""t=$(($(cat $ROOT/clock) + $1))
echo $t >$ROOT/clock
[ "$t" -le {until} ] || exit 1
[ ! -e $ROOT/at/$t ] || . $ROOT/at/$t""",
            networkctl='echo "$(cat $ROOT/clock) networkctl $*" >>$LOG',
            frame_hotspot='sh $ROOT/frame-hotspot "$@"',
            # frame-wpa requires frame-wifi
            systemctl="""echo "$(cat $ROOT/clock) systemctl $*" >>$LOG
[ "$*" != "restart frame-wpa" ] || sh $ROOT/frame-wifi""",
        )
        env = {**os.environ, "PATH": f"{root}/stubs:{os.environ['PATH']}"}
        subprocess.run(["sh", str(root / "frame-wifi")], env=env, check=True, capture_output=True)
        (root / "log").write_text("")
        self.done = subprocess.run(["sh", str(root / "frame-wifi-watch")], env=env, capture_output=True, timeout=30)
        return (root / "log").read_text().splitlines()

    @staticmethod
    def at(when, lines):
        return [f"{when} {line}" for line in lines]

    def conf(self):
        return (self.root / "etc/wpa_supplicant/wpa_supplicant-wlan0.conf").read_text().replace(str(self.root), "")

    def lost(self):
        return (self.root / "run/frame-lost").exists()

    def guess(self):
        path = self.root / "run/systemd/network/40-wlan0-known.network"
        return path.read_text() if path.exists() else None

    @staticmethod
    def known(until, ssid="Home 5", freq="2412", address="192.168.1.5/24"):
        return f"ssid={ssid}\nfreq={freq}\naddress={address}\nrouter=192.168.1.254\ndns=1.1.1.1 192.168.1.254\nuntil={until}\n"

    def test_ten_minutes_without_a_network_tell_the_product_and_open_nothing(self):
        self.assertEqual(self.run_watch(585), [])
        self.assertFalse(self.lost())
        self.assertEqual(self.run_watch(4000), [], "no access point, however long")
        self.assertTrue(self.lost())
        self.assertNotIn("mode=2", self.conf())
        self.assertFalse((self.root / "run/frame-setup").exists())

    def test_an_association_says_the_network_is_back(self):
        self.run_watch(800, {705: self.OPERSTATE % "up"})
        self.assertFalse(self.lost())

    def test_a_lost_link_counts_from_its_loss(self):
        events = {300: self.OPERSTATE % "up", 1500: self.OPERSTATE % "dormant"}
        self.run_watch(1500 + 570, events)
        self.assertFalse(self.lost())
        self.run_watch(1500 + 600, events)
        self.assertTrue(self.lost())

    def test_never_while_an_update_is_on_trial(self):
        self.assertEqual(self.run_watch(1000, state="active=a\npending=b\ntries=1\nboots=0\n"), [])
        self.assertFalse(self.lost())
        self.assertEqual(self.done.returncode, 1, "stopped by the timeline, not by itself")

    def test_a_frame_with_no_network_scans_with_no_access_point(self):
        self.assertEqual(self.run_watch(100, wifi=None), [])
        self.assertEqual(self.conf(), self.HEAD + "\n")
        self.assertEqual(self.done.returncode, 1, "it keeps watching")

    def test_the_power_key_held_opens_the_frames_own_wifi_under_the_products_name(self):
        self.assertEqual(self.run_watch(1100, {990: self.HELD}), self.at(990, self.OPEN))
        self.assertIn("mode=2", self.conf())
        setup = (self.root / "run/frame-setup").read_text()
        self.assertIn("FRAME_SETUP_SSID=Product-0123\n", setup)
        self.assertIn("FRAME_SETUP_PASSWORD=456789abcdef\n", setup)
        self.assertIn("FRAME_SETUP_URL=http://192.168.4.1\n", setup)
        network = self.root / "run/systemd/network"
        self.assertEqual(stat.S_IMODE(network.stat().st_mode), 0o755, "networkd's user reads it")
        self.assertEqual(stat.S_IMODE((network / "40-frame-setup.network").stat().st_mode), 0o644)

    def test_held_twice_it_opens_once(self):
        self.assertEqual(self.run_watch(1100, {990: self.HELD, 1050: self.HELD}), self.at(990, self.OPEN))

    def test_thirty_minutes_later_it_returns_to_its_network(self):
        back = 990 + 1800
        self.assertEqual(self.run_watch(back + 60, {990: self.HELD}), self.at(990, self.OPEN) + self.at(back, self.BACK))
        self.assertNotIn("mode=2", self.conf())
        for gone in ("run/frame-setup", "run/frame-hotspot", "run/systemd/network/40-frame-setup.network"):
            self.assertFalse((self.root / gone).exists(), gone)

    def test_someone_at_the_page_holds_the_way_back(self):
        self.assertEqual(self.run_watch(4300, {990: self.HELD, 2400: self.REQUEST}), self.at(990, self.OPEN) + self.at(2400 + 1800, self.BACK))

    def test_the_hotspot_says_how_it_is_used(self):
        self.assertEqual(subprocess.run(["sh", str(SBIN / "frame-hotspot")], capture_output=True).returncode, 2)

    def test_only_the_power_key_opens_the_access_point(self):
        for name in ("frame-wifi-watch", "frame-commit", "frame-wifi"):
            self.assertNotIn("hotspot open", (SBIN / name).read_text())
        self.assertNotRegex((SBIN / "frame-wifi-watch").read_text(), r": >\"\$hotspot\"")
        watch, commit = (SBIN / "frame-wifi-watch").read_text(), (SBIN / "frame-commit").read_text()
        # its ten minutes come after frame-commit is done
        self.assertIn("patience=600\n", watch)
        self.assertIn('[ "$waited" -lt 150 ]', commit)

    def test_the_last_boots_channel_is_the_only_one_scanned_and_its_lease_the_frames_while_it_lasts(self):
        self.run_watch(15, known=self.known(int(time.time()) + 3600))
        self.assertEqual(self.conf(), self.HEAD + 'network={\n\tscan_freq=2412\n\tssid="home"\n}\n')
        self.assertEqual(
            self.guess(),
            "[Match]\nName=wlan0\nSSID=Home 5\n\n[Network]\nDHCP=yes\nMulticastDNS=yes\nAddress=192.168.1.5/24\nGateway=192.168.1.254\nDNS=1.1.1.1\nDNS=192.168.1.254\n",
        )
        self.assertEqual(stat.S_IMODE((self.root / "run/systemd/network/40-wlan0-known.network").stat().st_mode), 0o644)

    def test_a_lease_that_ended_is_nobodys_but_the_channel_is_still_tried(self):
        self.run_watch(15, known=self.known(int(time.time()) - 1))
        self.assertIn("scan_freq=2412", self.conf())
        self.assertIsNone(self.guess())

    def test_nothing_on_that_channel_and_the_scan_is_every_channels_again(self):
        self.run_watch(15, known=self.known(int(time.time()) + 3600), wide=True)
        self.assertNotIn("scan_freq", self.conf())
        self.assertIsNone(self.guess())

    def test_what_was_learnt_is_taken_only_in_the_shape_expected(self):
        soon = int(time.time()) + 3600
        for odd in (self.known(soon, ssid="x]y"), self.known(soon, ssid="a=b"), self.known(soon, address="1.2.3.4/24 x"), self.known("soon"), self.known(soon, ssid="")):
            self.run_watch(15, known=odd)
            self.assertIsNone(self.guess(), odd)
        self.run_watch(15, known=self.known(soon, freq="2412; reboot"))
        self.assertNotIn("scan_freq", self.conf())
        self.assertIsNone(self.guess())

    def test_the_frames_own_wifi_takes_nothing_for_granted(self):
        self.run_watch(1100, {990: self.HELD}, known=self.known(int(time.time()) + 3600))
        self.assertNotIn("scan_freq", self.conf())
        self.assertIsNone(self.guess())

    def test_a_product_gets_the_wifis_service_and_the_power_key_only_if_it_asks(self):
        post = (REPO / "system/buildroot/post-build.sh").read_text()
        for unit in ("frame-wifid", "frame-power-key", "frame-wifi-watch"):
            self.assertIn(f"disable {unit}.service\n", post)
        # the product's word comes first: the first word of a preset wins
        self.assertLess(post.index("cat /product/preset"), post.index("disable frame-wifid.service"))
        self.assertIn("BR2_PACKAGE_WPA_SUPPLICANT_AP_SUPPORT=y\n", (REPO / "system/buildroot/base_defconfig").read_text())
        units = ROOTFS / "etc/systemd/system"
        self.assertNotIn("RemainAfterExit=", (units / "frame-wifi.service").read_text())
        for script in ("frame-wifi-watch", "frame-hotspot", "frame-wifi", "frame-commit", "frame-slot", "frame-data"):
            self.assertTrue(os.access(SBIN / script, os.X_OK), script)

    def test_a_product_reaches_the_wifis_service_by_its_group_alone(self):
        unit = (ROOTFS / "etc/systemd/system/frame-wifid.service").read_text()
        self.assertIn("Group=kiosk\n", unit)
        self.assertIn("RuntimeDirectoryMode=0750\n", unit)
        self.assertIn('pub const SOCKET: &str = "/run/frame-wifi/socket";', (REPO / "tools/src/wifi.rs").read_text())


if __name__ == "__main__":
    unittest.main()
