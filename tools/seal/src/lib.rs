//! A slot's manifest: what it holds, each file by its name, its size and its SHA-256, and a
//! version that only goes up; `manifest.json`, with its detached Ed25519 signature `manifest.sig`
//! by the product's release key. The initramfs starts nothing whose manifest no key it trusts
//! signed; the private key never leaves the build machine.

use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::Path;

/// What a slot may hold, and nothing else: a name comes from the network and becomes a path. The
/// system; perhaps a kernel of its own; the product's boot picture, which the initramfs draws.
pub const SLOT_FILES: [&str; 6] = [
    "rootfs.squashfs",
    "zImage",
    "board.dtb",
    "initramfs.cpio.gz",
    "splash.raw",
    "splash.conf",
];
pub const MANIFEST: &str = "manifest.json";
pub const SIGNATURE: &str = "manifest.sig";
/// No manifest is larger: read whole before it is trusted.
pub const MANIFEST_MAX: u64 = 1 << 16;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub version: u64,
    pub files: Vec<File>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct File {
    pub name: String,
    pub sha256: String,
    pub size: u64,
}

#[derive(Debug, PartialEq)]
pub enum Refused {
    BadKey,
    BadSignature,
    BadManifest(String),
    /// A file of the slot is not what the manifest says: its name, and why.
    BadFile(String, String),
}

pub fn unhex(text: &str) -> Option<Vec<u8>> {
    let text = text.trim();
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| {
            text.get(i..i + 2)
                .and_then(|b| u8::from_str_radix(b, 16).ok())
        })
        .collect()
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Whether `key_hex` (a release key's public half, 32 bytes in hex) signed exactly these bytes.
pub fn signed(bytes: &[u8], signature: &[u8], key_hex: &str) -> Result<(), Refused> {
    let key: [u8; 32] = unhex(key_hex)
        .and_then(|k| k.try_into().ok())
        .ok_or(Refused::BadKey)?;
    let key = VerifyingKey::from_bytes(&key).map_err(|_| Refused::BadKey)?;
    let signature = Signature::from_slice(signature).map_err(|_| Refused::BadSignature)?;
    key.verify_strict(bytes, &signature)
        .map_err(|_| Refused::BadSignature)
}

/// The manifest these bytes say, only when it can be trusted to become paths on the frame.
pub fn read(bytes: &[u8]) -> Result<Manifest, Refused> {
    let manifest: Manifest =
        serde_json::from_slice(bytes).map_err(|e| Refused::BadManifest(e.to_string()))?;
    if !manifest.files.iter().any(|f| f.name == "rootfs.squashfs") {
        return Err(Refused::BadManifest("no system".into()));
    }
    for f in &manifest.files {
        if !SLOT_FILES.contains(&f.name.as_str()) {
            return Err(Refused::BadManifest(format!(
                "{}: not a slot's file",
                f.name
            )));
        }
        if unhex(&f.sha256).is_none_or(|h| h.len() != 32) {
            return Err(Refused::BadManifest(format!("{}: not a SHA-256", f.name)));
        }
    }
    Ok(manifest)
}

/// The manifest, only when `key_hex` signed exactly these bytes and what it says can be trusted.
pub fn verified(bytes: &[u8], signature: &[u8], key_hex: &str) -> Result<Manifest, Refused> {
    signed(bytes, signature, key_hex)?;
    read(bytes)
}

pub fn sha256_of(path: &Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 1 << 16];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            return Ok(hex(&hasher.finalize()));
        }
        hasher.update(&buffer[..read]);
    }
}

/// How far a slot's files are looked at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Depth {
    /// Each file there, of the size the manifest says: a slot that proved itself at its last boot.
    Sizes,
    /// Each file read through SHA-256: an update on trial, a slot whose last boot proved nothing.
    Whole,
}

/// The slot in `dir` holds what `manifest` says, as far as `depth` looks, and nothing else of a
/// slot's.
pub fn holds(dir: &Path, manifest: &Manifest, depth: Depth) -> Result<(), Refused> {
    for name in SLOT_FILES {
        let said = manifest.files.iter().find(|f| f.name == name);
        let path = dir.join(name);
        let there = std::fs::symlink_metadata(&path).ok();
        let (Some(said), Some(there)) = (said, &there) else {
            if said.is_some() {
                return Err(Refused::BadFile(name.into(), "missing".into()));
            }
            if there.is_some() {
                return Err(Refused::BadFile(name.into(), "not in the manifest".into()));
            }
            continue;
        };
        if !there.is_file() {
            return Err(Refused::BadFile(name.into(), "not a file".into()));
        }
        if there.len() != said.size {
            return Err(Refused::BadFile(
                name.into(),
                format!("{} bytes for {}", there.len(), said.size),
            ));
        }
        if depth == Depth::Whole {
            let sum = sha256_of(&path).map_err(|e| Refused::BadFile(name.into(), e.to_string()))?;
            if sum != said.sha256 {
                return Err(Refused::BadFile(name.into(), "another SHA-256".into()));
            }
        }
    }
    Ok(())
}

fn limited(path: &Path) -> Result<Vec<u8>, Refused> {
    let size = std::fs::metadata(path)
        .map_err(|e| Refused::BadManifest(format!("{}: {e}", path.display())))?
        .len();
    if size > MANIFEST_MAX {
        return Err(Refused::BadManifest(format!(
            "{}: too large",
            path.display()
        )));
    }
    std::fs::read(path).map_err(|e| Refused::BadManifest(format!("{}: {e}", path.display())))
}

/// The slot in `dir`, checked: its manifest signed by one of `keys` (none: its signature is not
/// asked, the files only are compared to what it says), its files as far as `depth` looks.
pub fn check(dir: &Path, keys: &[String], depth: Depth) -> Result<Manifest, Refused> {
    let bytes = limited(&dir.join(MANIFEST))?;
    if !keys.is_empty() {
        let signature = limited(&dir.join(SIGNATURE))?;
        let mut last = Refused::BadKey;
        let mut any = false;
        for key in keys {
            match signed(&bytes, &signature, key) {
                Ok(()) => {
                    any = true;
                    break;
                }
                Err(why) => last = why,
            }
        }
        if !any {
            return Err(last);
        }
    }
    let manifest = read(&bytes)?;
    holds(dir, &manifest, depth)?;
    Ok(manifest)
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 8032, section 7.1, test 1: the empty message.
    const KEY: &str = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
    const EMPTY_SIGNED: &str = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";

    #[test]
    fn a_signature_is_its_keys_over_these_bytes_and_no_other() {
        let signature = unhex(EMPTY_SIGNED).unwrap();
        assert_eq!(signed(b"", &signature, KEY), Ok(()));
        assert_eq!(signed(b"x", &signature, KEY), Err(Refused::BadSignature));
        assert_eq!(
            signed(b"", &signature[..63], KEY),
            Err(Refused::BadSignature)
        );
        assert_eq!(signed(b"", &signature, "abcd"), Err(Refused::BadKey));
    }

    fn manifest(name: &str, sha: &str) -> Vec<u8> {
        serde_json::to_vec(&Manifest {
            version: 7,
            files: vec![File {
                name: name.into(),
                sha256: sha.into(),
                size: 1,
            }],
        })
        .unwrap()
    }

    #[test]
    fn a_name_from_the_network_never_becomes_any_path() {
        assert_eq!(
            read(&manifest("rootfs.squashfs", &"ab".repeat(32)))
                .unwrap()
                .version,
            7
        );
        for name in [
            "../../etc/passwd",
            "sums",
            "/etc/shadow",
            "rootfs.squashfs/x",
        ] {
            assert!(
                matches!(
                    read(&manifest(name, &"ab".repeat(32))),
                    Err(Refused::BadManifest(_))
                ),
                "{name}"
            );
        }
        assert!(matches!(
            read(&manifest("rootfs.squashfs", "short")),
            Err(Refused::BadManifest(_))
        ));
    }

    fn slot(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("frame-seal-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn described(dir: &Path) -> Manifest {
        let files = SLOT_FILES
            .iter()
            .filter(|name| dir.join(name).exists())
            .map(|name| File {
                name: (*name).into(),
                sha256: sha256_of(&dir.join(name)).unwrap(),
                size: std::fs::metadata(dir.join(name)).unwrap().len(),
            })
            .collect();
        Manifest { version: 1, files }
    }

    #[test]
    fn a_slot_holds_what_its_manifest_says_and_nothing_else_of_a_slots() {
        let dir = slot("holds");
        std::fs::write(dir.join("rootfs.squashfs"), b"system").unwrap();
        std::fs::write(dir.join("splash.conf"), b"1 2 0x0 0x1 120\n").unwrap();
        let manifest = described(&dir);
        assert_eq!(holds(&dir, &manifest, Depth::Whole), Ok(()));
        // a kernel nobody signed would be started by kexec
        std::fs::write(dir.join("zImage"), b"z").unwrap();
        assert!(
            matches!(holds(&dir, &manifest, Depth::Sizes), Err(Refused::BadFile(n, _)) if n == "zImage")
        );
        std::fs::remove_file(dir.join("zImage")).unwrap();
        // the same size, other bytes: seen only when read whole
        std::fs::write(dir.join("rootfs.squashfs"), b"sYstem").unwrap();
        assert_eq!(holds(&dir, &manifest, Depth::Sizes), Ok(()));
        assert!(
            matches!(holds(&dir, &manifest, Depth::Whole), Err(Refused::BadFile(n, _)) if n == "rootfs.squashfs")
        );
        std::fs::write(dir.join("rootfs.squashfs"), b"sys").unwrap();
        assert!(matches!(
            holds(&dir, &manifest, Depth::Sizes),
            Err(Refused::BadFile(..))
        ));
        std::fs::write(dir.join("rootfs.squashfs"), b"system").unwrap();
        std::fs::remove_file(dir.join("splash.conf")).unwrap();
        assert!(
            matches!(holds(&dir, &manifest, Depth::Sizes), Err(Refused::BadFile(n, _)) if n == "splash.conf")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_slot_without_a_signature_of_a_trusted_key_is_refused() {
        let dir = slot("check");
        std::fs::write(dir.join("rootfs.squashfs"), b"system").unwrap();
        std::fs::write(
            dir.join(MANIFEST),
            serde_json::to_vec(&described(&dir)).unwrap(),
        )
        .unwrap();
        // no key asked: the files only
        assert!(check(&dir, &[], Depth::Whole).is_ok());
        assert!(matches!(
            check(&dir, &[KEY.into()], Depth::Sizes),
            Err(Refused::BadManifest(_))
        ));
        std::fs::write(dir.join(SIGNATURE), unhex(EMPTY_SIGNED).unwrap()).unwrap();
        assert_eq!(
            check(&dir, &[KEY.into()], Depth::Sizes),
            Err(Refused::BadSignature)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
