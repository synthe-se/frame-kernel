"""What a maintenance start carries with its initramfs (bin/refit.sh): a directory, as entries
under /payload of the same archive. In it: rootfs.squashfs, the system to run from RAM, and
data/, what it needs to be reached (the Wi-Fi's network, the SSH host key).

One archive, never two end to end: after a compressed archive the kernel does not always find
the start of the one that follows (« invalid magic at start of compressed archive », seen on the
frame with some builds of the initramfs and not others), and the payload is then not there.
"""

from pathlib import Path


def entries(directory: Path, ino: int = 400000) -> list[dict]:
    out = []

    def add(name, data=b"", mode=0o100644):
        nonlocal ino
        ino += 1
        out.append({"name": name, "data": data, "ino": ino, "mode": mode, "uid": 0, "gid": 0, "nlink": 1, "mtime": 0})

    add("payload", mode=0o40755)
    for path in sorted(directory.rglob("*")):
        name = "payload/" + str(path.relative_to(directory))
        if path.is_symlink():
            raise SystemExit(f"{path}: a link in a payload")
        if path.is_dir():
            add(name, mode=0o40700)
        else:
            add(name, path.read_bytes(), 0o100600)
    return out
