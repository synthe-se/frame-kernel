# Sourced by the frame's tools: what a product says of itself. `product <directory>` reads its
# product.conf (KEY=value lines, README « A product ») and checks it; the variables stay set.
product() {
	PRODUCT="$(cd "$1" 2>/dev/null && pwd)" || { echo "$1: no such product directory" >&2; exit 1; }
	[ -s "$PRODUCT/product.conf" ] || { echo "$PRODUCT: no product.conf" >&2; exit 1; }
	PRODUCT_REPO="$(git -C "$PRODUCT" rev-parse --show-toplevel)"
	NAME= TITLE= HOSTNAME= UNIT= HEARTBEAT= UPDATE_URL= UPDATE_HOST= TURN=0 GROUND= INK= MARK= MARK_HEIGHT=240 BUILDROOT_FIRST=
	# shellcheck disable=SC1091
	. "$PRODUCT/product.conf"
	local key
	for key in NAME TITLE HOSTNAME UNIT GROUND INK MARK; do
		[ -n "${!key}" ] || { echo "$PRODUCT/product.conf: no $key" >&2; exit 1; }
	done
	case "$NAME" in *[!a-z0-9-]* | "") echo "NAME=$NAME: lower case letters, digits, dashes" >&2; exit 1 ;; esac
	case "$TURN" in 0 | 90 | 180 | 270) ;; *) echo "TURN=$TURN: 0, 90, 180 or 270" >&2; exit 1 ;; esac
	case "$UPDATE_URL" in "" | https://?*) ;; *) echo "UPDATE_URL=$UPDATE_URL: an https:// address" >&2; exit 1 ;; esac
	UPDATE_URL="${FRAME_UPDATE_URL-$UPDATE_URL}"
}
# what the image's build reads of it, as a file a shell sources
product_env() {
	local key
	for key in NAME TITLE HOSTNAME UNIT HEARTBEAT UPDATE_URL; do printf "%s='%s'\n" "$key" "${!key}"; done
}
