# shellcheck shell=bash
# shellcheck disable=SC2034  # what it sets is read by the tools that source it
# Sourced by the tools that change a frame's slots (install.sh, switch.sh, try.sh): what the frame
# says of them, read whole or not at all. An answer that did not come is never an empty answer:
# a trial that still runs must not pass for one that ended.
# `frame_slots` sets, from one answer of the frame: slots (their directory), active, pending,
# mounted (the slot the system that runs was started from) and running (its product).
frame_slots() {
	local said
	slots='' active='' pending='' mounted='' running=''
	said=$("$(dirname "${BASH_SOURCE[0]}")/console.sh" 'for lib in /usr/local/lib/frame-slots /usr/local/lib/maison-slots; do [ ! -e $lib ] || { . $lib; break; }; done
echo "slots=$slots"
echo "active=$(key active)"
echo "pending=$(key pending)"
echo "mounted=$(sed -n "s|^/dev/loop[0-9]* /lower .*||p; s|.*slots/\\([ab]\\)/rootfs.squashfs.*|\\1|p" /sys/block/loop*/loop/backing_file 2>/dev/null | head -1)"
echo "running=$(cat /etc/frame/product 2>/dev/null || echo maison)"
echo "end=said"' 30) || return 1
	[ "$(printf '%s\n' "$said" | tail -1)" = "end=said" ] || return 1
	slots=$(printf '%s\n' "$said" | sed -n 's/^slots=//p')
	active=$(printf '%s\n' "$said" | sed -n 's/^active=//p')
	pending=$(printf '%s\n' "$said" | sed -n 's/^pending=//p')
	mounted=$(printf '%s\n' "$said" | sed -n 's/^mounted=//p')
	running=$(printf '%s\n' "$said" | sed -n 's/^running=//p')
	case "$active$mounted" in aa | ab | ba | bb) ;; *) return 1 ;; esac
}
# the frame runs the slot it keeps as its own, nothing on trial: only then may a slot be given away
frame_settled() {
	frame_slots || { echo "the frame does not say what its slots hold" >&2; return 1; }
	[ -z "$pending" ] && [ "$mounted" = "$active" ] ||
		{ echo "the frame is trying slot ${pending:-$mounted} (it keeps $active): once it has proved itself or gone back" >&2; return 1; }
}
