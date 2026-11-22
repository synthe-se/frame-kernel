"""What a maintenance start carries beside the initramfs (bin/refit.sh): a directory packed as a
cpio under /payload, to follow the initramfs in the one file kexec loads (the kernel unpacks each
archive in turn). In it: rootfs.squashfs, the system to run from RAM, and data/, what it needs to
be reached (the Wi-Fi's network, the SSH host key).

    python3 boot/payload.py <directory> <out.cpio>
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bootimg  # noqa: E402


def pack(directory: Path) -> bytes:
    entries, ino = [], 400000

    def add(name, data=b"", mode=0o100644):
        nonlocal ino
        ino += 1
        entries.append({"name": name, "data": data, "ino": ino, "mode": mode, "uid": 0, "gid": 0, "nlink": 1, "mtime": 0})

    add("payload", mode=0o40755)
    for path in sorted(directory.rglob("*")):
        name = "payload/" + str(path.relative_to(directory))
        if path.is_symlink():
            raise SystemExit(f"{path}: a link in a payload")
        if path.is_dir():
            add(name, mode=0o40700)
        else:
            add(name, path.read_bytes(), 0o100600)
    return bootimg.write_cpio(entries)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    Path(sys.argv[2]).write_bytes(pack(Path(sys.argv[1])))
