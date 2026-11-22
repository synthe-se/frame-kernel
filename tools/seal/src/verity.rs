//! fs-verity, as the frame uses it: SHA-256, blocks of 4096 bytes, no salt, no built-in signature
//! (the manifest's is the one that counts). A file's digest is computed here, on the build machine,
//! as the kernel will compute it (`digest`); on the frame the file is sealed (`enable`: the kernel
//! then checks every block it reads against that digest, and the file can no longer be written)
//! and asked its digest (`measure`: an answer at once, whatever the file's size).

use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::Path;

const BLOCK: usize = 4096;
const HASH: usize = 32;

/// The fs-verity digest of what `reader` gives: the SHA-256 of the file's descriptor, which
/// holds its size and the root of the Merkle tree over its blocks.
pub fn digest_of(mut reader: impl Read) -> std::io::Result<[u8; HASH]> {
    let mut level: Vec<u8> = Vec::new();
    let mut size: u64 = 0;
    let mut block = [0u8; BLOCK];
    loop {
        // a whole block, or the file's last, however the reader hands it out
        let mut filled = 0;
        while filled < BLOCK {
            let read = reader.read(&mut block[filled..])?;
            if read == 0 {
                break;
            }
            filled += read;
        }
        if filled == 0 {
            break;
        }
        size += filled as u64;
        // the last block is hashed padded with zeros
        block[filled..].fill(0);
        level.extend_from_slice(&Sha256::digest(block));
        if filled < BLOCK {
            break;
        }
    }
    // each level's hashes, packed in blocks padded with zeros, hashed into the level above,
    // until one hash is left; a file of one block has no level above it, an empty one no root
    while level.len() > HASH {
        let mut above = Vec::with_capacity(level.len() / (BLOCK / HASH) + HASH);
        for hashes in level.chunks(BLOCK) {
            let mut block = [0u8; BLOCK];
            block[..hashes.len()].copy_from_slice(hashes);
            above.extend_from_slice(&Sha256::digest(block));
        }
        level = above;
    }
    // struct fsverity_descriptor, its 256 bytes: version 1, SHA-256 (1), 2^12 bytes a block, no
    // salt, no signature, the size, the root in 64 bytes, a salt of 32 zeros, 144 reserved
    let mut descriptor = [0u8; 256];
    descriptor[0] = 1;
    descriptor[1] = 1;
    descriptor[2] = 12;
    descriptor[8..16].copy_from_slice(&size.to_le_bytes());
    descriptor[16..16 + level.len()].copy_from_slice(&level);
    Ok(Sha256::digest(descriptor).into())
}

/// The fs-verity digest the kernel would give this file, sealed.
pub fn digest(path: &Path) -> std::io::Result<[u8; HASH]> {
    digest_of(std::io::BufReader::with_capacity(
        1 << 16,
        std::fs::File::open(path)?,
    ))
}

#[cfg(target_os = "linux")]
mod kernel {
    use super::HASH;
    use std::os::fd::AsRawFd;
    use std::path::Path;

    /// `struct fsverity_enable_arg` (linux/fsverity.h), 128 bytes.
    #[repr(C)]
    struct EnableArg {
        version: u32,
        hash_algorithm: u32,
        block_size: u32,
        salt_size: u32,
        salt_ptr: u64,
        sig_size: u32,
        reserved1: u32,
        sig_ptr: u64,
        reserved2: [u64; 11],
    }
    /// `struct fsverity_digest` with room for a SHA-256.
    #[repr(C)]
    struct Measured {
        digest_algorithm: u16,
        digest_size: u16,
        digest: [u8; HASH],
    }
    // _IOW('f', 133, struct fsverity_enable_arg) and _IOWR('f', 134, struct fsverity_digest)
    const FS_IOC_ENABLE_VERITY: u32 = 0x4080_6685;
    const FS_IOC_MEASURE_VERITY: u32 = 0xc004_6686;
    const FS_VERITY_HASH_ALG_SHA256: u32 = 1;

    /// Seals the file: from here the kernel checks each block read, and no one writes it. A
    /// file sealed already is left as it is.
    pub fn enable(path: &Path) -> std::io::Result<()> {
        let file = std::fs::File::open(path)?;
        let arg = EnableArg {
            version: 1,
            hash_algorithm: FS_VERITY_HASH_ALG_SHA256,
            block_size: 4096,
            salt_size: 0,
            salt_ptr: 0,
            sig_size: 0,
            reserved1: 0,
            sig_ptr: 0,
            reserved2: [0; 11],
        };
        // SAFETY: the descriptor is open for as long as the call lasts, and `arg` is the
        // structure the kernel reads for this request, whole and initialised.
        let done = unsafe { libc::ioctl(file.as_raw_fd(), FS_IOC_ENABLE_VERITY as _, &arg) };
        if done == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EEXIST) {
            return Ok(());
        }
        Err(error)
    }

    /// The digest of a sealed file, as the kernel holds it; none for a file that is not sealed,
    /// or where files cannot be.
    pub fn measure(path: &Path) -> Option<[u8; HASH]> {
        let file = std::fs::File::open(path).ok()?;
        let mut measured = Measured {
            digest_algorithm: 0,
            digest_size: HASH as u16,
            digest: [0; HASH],
        };
        // SAFETY: the descriptor is open for as long as the call lasts, and `measured` has the
        // room its `digest_size` says for what the kernel writes.
        let done =
            unsafe { libc::ioctl(file.as_raw_fd(), FS_IOC_MEASURE_VERITY as _, &mut measured) };
        (done == 0
            && u32::from(measured.digest_algorithm) == FS_VERITY_HASH_ALG_SHA256
            && usize::from(measured.digest_size) == HASH)
            .then_some(measured.digest)
    }
}

#[cfg(not(target_os = "linux"))]
mod kernel {
    use super::HASH;
    use std::path::Path;

    pub fn enable(_: &Path) -> std::io::Result<()> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "fs-verity is Linux's",
        ))
    }

    pub fn measure(_: &Path) -> Option<[u8; HASH]> {
        None
    }
}

pub use kernel::{enable, measure};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;

    #[test]
    fn an_empty_file_has_the_digest_the_kernel_gives_it() {
        // fsverity-utils' own: `fsverity digest` of an empty file
        assert_eq!(
            hex(&digest_of(&b""[..]).unwrap()),
            "3d248ca542a24fc62d1c43b916eae5016878e2533c88238480b26128a1f1af95"
        );
    }

    #[test]
    fn a_reader_that_gives_little_at_a_time_changes_nothing() {
        struct Drip<'a>(&'a [u8]);
        impl Read for Drip<'_> {
            fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
                let n = self.0.len().min(out.len()).min(7);
                out[..n].copy_from_slice(&self.0[..n]);
                self.0 = &self.0[n..];
                Ok(n)
            }
        }
        // more than one block of hashes: three levels
        let data: Vec<u8> = (0..BLOCK * 130 + 17)
            .map(|i| (i * 31 % 251) as u8)
            .collect();
        assert_eq!(
            digest_of(&data[..]).unwrap(),
            digest_of(Drip(&data)).unwrap()
        );
        assert_ne!(
            digest_of(&data[..]).unwrap(),
            digest_of(&data[..data.len() - 1]).unwrap()
        );
    }

    #[test]
    fn a_block_s_worth_and_one_byte_more_are_two_files() {
        let one = vec![7u8; BLOCK];
        let mut more = one.clone();
        more.push(0);
        assert_ne!(digest_of(&one[..]).unwrap(), digest_of(&more[..]).unwrap());
    }
}
