#!/usr/bin/env bash
# A slot's seal, on the build machine: `manifest.json` from the slot's files in a directory and
# the image's version, and `manifest.sig` by the product's release key ($FRAME_HOME/keys/<name>.pk8,
# never in a repository; its public half is the product's release.pub, and a key that is not its
# pair is refused before anything is signed). No key yet: made here, once, its public half written
# into the product's directory.
# Usage: bin/sign.sh <product directory> <version> <directory of a slot's files>
set -euo pipefail
. "$(dirname "$0")/product.sh"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
product "${1:?usage: bin/sign.sh <product directory> <version> <directory>}"
version=${2:?a version}
dir=${3:?a directory}
KEY="${FRAME_HOME:-$HOME/maison-frame}/keys/$NAME.pk8"
sign() { cargo run -q --release --manifest-path "$REPO/tools/Cargo.toml" --bin frame-sign -- "$@"; }
if [ ! -s "$KEY" ]; then
	[ ! -s "$PRODUCT/release.pub" ] || { echo "no $KEY, the key of $PRODUCT/release.pub: without it nothing can be signed for its frames" >&2; exit 1; }
	sign keygen "$KEY" "$PRODUCT/release.pub"
	echo "a release key for $NAME: $KEY (keep it), its public half in $PRODUCT/release.pub (commit it)"
fi
sign describe "$version" "$dir"
sign sign "$KEY" "$PRODUCT/release.pub" "$dir/manifest.json"
