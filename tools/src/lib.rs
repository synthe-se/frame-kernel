//! What the frame's tools share: its Wi-Fi (`wifi`, `wpa`), and for its updates what a release is
//! and whether one is wanted. A release is a slot's manifest (`frame-seal`: `manifest.json`, its
//! detached Ed25519 signature `manifest.sig`) and the files it names, under `<version>/`. The
//! private key never leaves the build machine.

pub use frame_seal::{
    File, MANIFEST, Manifest, Refused, SIGNATURE, SLOT_FILES, hex, sha256_of, unhex, verified,
};

pub mod wifi;
pub mod wpa;

/// The product's release key, as the system holds it (`frame-sign keygen` made it; the product's
/// repository keeps the public half): the frame's updater trusts nothing else.
pub const RELEASE_KEY: &str = "/etc/frame/release.pub";

/// Whether a release may replace what runs: strictly newer, and not one that already failed here.
pub fn wanted(version: u64, running: u64, refused: &[u64]) -> bool {
    version > running && !refused.contains(&version)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_release_must_be_newer_and_not_one_that_failed() {
        assert!(wanted(8, 7, &[]));
        assert!(!wanted(7, 7, &[]));
        assert!(!wanted(6, 7, &[]));
        assert!(!wanted(8, 7, &[8]));
    }
}
