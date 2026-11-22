#!/usr/bin/env bash
# A frame shared by two products: the one that runs is put aside whole (/data/frame/parked/
# <product>: its system, its boot picture, their sums checked), the other comes back from there
# into the free slot, on trial as any update, and the frame restarts on it. The free slot is any
# install's to overwrite: what a product must keep while the other runs is its parked copy.
# Usage: bin/switch.sh <product name>       bin/switch.sh       says what runs and what is parked
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
c() { "$REPO/bin/console.sh" "$@"; }
. "$REPO/bin/frame-state.sh"
parked=/data/frame/parked
if [ $# = 0 ]; then
	frame_slots || { echo "the frame does not say what its slots hold" >&2; exit 1; }
	echo "runs: $running (slot $mounted${pending:+, on trial})"
	echo "parked: $(c "ls $parked 2>/dev/null | tr '\n' ' '" 20)"
	exit 0
fi
target=$1
case "$target" in *[!a-z0-9-]* | "") echo "$target: a product's name" >&2; exit 2 ;; esac
# never while the frame tries a system: its free slot would be the one it runs from
frame_settled || exit 1
[ "$target" != "$running" ] || { echo "$target runs already"; exit 0; }
# asked so that a yes and a no are both answers: a frame that did not answer said neither
case "$(c "[ -s $parked/$target/manifest.sig ] && echo parked || echo none" 20)" in
parked) ;;
none) echo "no $target parked on the frame: just install <its directory>" >&2; exit 1 ;;
*) echo "the frame does not say whether $target is parked" >&2; exit 1 ;;
esac
free=$([ "$active" = a ] && echo b || echo a)
tool=$(c 'for t in /usr/local/sbin/frame-slot /usr/local/sbin/maison-slot; do [ ! -x $t ] || { echo $t; break; }; done' 20)
# on the frame, in one go: the slot that runs is copied aside and checked, the free slot filled
# from what was put aside and offered only whole
c "set -e
rm -rf $parked/$running.new
mkdir -p $parked/$running.new
cp $slots/$active/* $parked/$running.new/
/usr/local/bin/frame-seal check --whole $parked/$running.new >/dev/null
rm -rf $parked/$running
mv $parked/$running.new $parked/$running
rm -rf $slots/$free
mkdir -p $slots/$free
cp $parked/$target/* $slots/$free/
sync
$tool offer $free
echo \"$running parked, $target in slot $free\"" 180
exec "$REPO/bin/try.sh" --settle
