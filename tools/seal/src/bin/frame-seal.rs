//! `frame-seal check [--whole] <slot directory> [<key file>…]`: whether a slot is what its
//! manifest says, signed by one of the keys (each file a release key's public half in hex; none:
//! the signature is not asked). It says the manifest's version and ends with 0, or says why not
//! and ends with 1. The initramfs asks it of the slot it is about to start, with the keys it was
//! built with; the system, before it offers a slot.
//! `frame-seal seal <slot directory>`: the slot's files sealed (fs-verity), each to the digest its
//! manifest names; it says how many. A slot is sealed once its files are all there: no one
//! writes them after.

use frame_seal::{Depth, MANIFEST, check, read, seal};
use std::path::Path;
use std::{env, fs, process};

fn main() {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if let [command, dir] = args.as_slice()
        && command == "seal"
    {
        let sealed = fs::read(Path::new(dir).join(MANIFEST))
            .map_err(|e| format!("{e}"))
            .and_then(|bytes| read(&bytes).map_err(|e| format!("{e:?}")))
            .and_then(|manifest| seal(Path::new(dir), &manifest).map_err(|e| format!("{e:?}")));
        match sealed {
            Ok(files) => println!("{files}"),
            Err(why) => {
                eprintln!("{dir}: {why}");
                process::exit(1);
            }
        }
        return;
    }
    if args.first().map(String::as_str) != Some("check") {
        eprintln!(
            "usage: frame-seal check [--whole] <slot directory> [<key file>…] | seal <slot directory>"
        );
        process::exit(2);
    }
    args.remove(0);
    let depth = if args.first().map(String::as_str) == Some("--whole") {
        args.remove(0);
        Depth::Whole
    } else {
        Depth::Sizes
    };
    let Some(dir) = args.first().cloned() else {
        eprintln!(
            "usage: frame-seal check [--whole] <slot directory> [<key file>…] | seal <slot directory>"
        );
        process::exit(2);
    };
    let mut keys = Vec::new();
    for file in &args[1..] {
        match fs::read_to_string(file) {
            Ok(key) => keys.push(key),
            Err(why) => {
                eprintln!("{file}: {why}");
                process::exit(1);
            }
        }
    }
    match check(Path::new(&dir), &keys, depth) {
        Ok(manifest) => println!("{}", manifest.version),
        Err(why) => {
            eprintln!("{dir}: {why:?}");
            process::exit(1);
        }
    }
}
