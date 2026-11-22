# shellcheck shell=bash
# Sourced by the frame's tools: ssh and scp with a live certificate (ssh-cert.sh), the host key
# checked as the frame's whatever name or address it answers on. The frame is FRAME_HOST when it
# is said; else the name its product gives it (<product>-frame.local, by mDNS), found once among
# the products built here and remembered by its address until it stops answering (its name
# changes with its product, its address does not: the Wi-Fi's is made from the eMMC's serial).
FRAME_KEYS="${FRAME_HOME:-$HOME/maison-frame}/keys"
frame_cert="$FRAME_KEYS/frame-cert.pub"
frame_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
frame_ready() {
	local left
	left=$(ssh-keygen -L -f "$frame_cert" 2>/dev/null | sed -n 's/.*Valid: from .* to //p')
	if [ -z "$left" ] || [ "$(date +%Y-%m-%dT%H:%M:%S)" \> "$left" ]; then
		"$frame_bin/ssh-cert.sh"
	fi
}
frame_options=(-o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=3 -o HostKeyAlias=frame -o StrictHostKeyChecking=accept-new -o "CertificateFile=$frame_cert")
frame_answers() { ssh "${frame_options[@]}" -o ConnectTimeout=3 "root@$1" true 2>/dev/null; }
# sets FRAME; fails when no frame answers
frame_find() {
	frame_ready
	if [ -n "${FRAME_HOST-}" ]; then FRAME=$FRAME_HOST; return 0; fi
	local kept="$frame_bin/../build/host" name
	if [ -s "$kept" ] && frame_answers "$(cat "$kept")"; then FRAME=$(cat "$kept"); return 0; fi
	for name in $(sed -n "s/^HOST='\(.*\)'$/\1.local/p" "$frame_bin"/../build/*/product.env 2>/dev/null) maison-frame.local; do
		if frame_answers "$name"; then
			# its IPv4 address, when the name gives one
			FRAME=$(python3 -c 'import socket, sys; print(socket.gethostbyname(sys.argv[1]))' "$name" 2>/dev/null || echo "$name")
			mkdir -p "$frame_bin/../build" && echo "$FRAME" >"$kept"
			return 0
		fi
	done
	echo "no frame answers: FRAME_HOST=<its address>" >&2
	return 1
}
frame_ssh() { frame_find && ssh "${frame_options[@]}" "root@$FRAME" "$@"; }
frame_scp() { frame_ready; scp -q "${frame_options[@]}" "$@"; }
