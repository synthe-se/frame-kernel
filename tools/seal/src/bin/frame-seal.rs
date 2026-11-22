//! `frame-seal check [--whole] <slot directory> [<key file>…]`: whether a slot is what its
//! manifest says, signed by one of the keys (each file a release key's public half in hex; none:
//! the signature is not asked). It says the manifest's version and ends with 0, or says why not
//! and ends with 1. The initramfs asks it of the slot it is about to start, with the keys it was
//! built with; the system, before it offers a slot.

use frame_seal::{Depth, check};
use std::path::Path;
use std::{env, fs, process};

fn main() {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if args.first().map(String::as_str) != Some("check") {
        eprintln!("usage: frame-seal check [--whole] <slot directory> [<key file>…]");
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
        eprintln!("usage: frame-seal check [--whole] <slot directory> [<key file>…]");
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
