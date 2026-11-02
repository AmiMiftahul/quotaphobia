extends Node
## The in-game shop. This script never decides that something is paid for: it only
## shows what the server says. Prices and ownership all live on the server.

signal changed
signal order_changed

const SETTINGS_FILE := "user://store.cfg"
const ORDER_TIMEOUT_SECONDS := 16.0 * 60.0
# What each product unlocks. The price and name come from the database.
const SKIN_MODELS := {
	"skin_engineer": "character-male-b",
	"skin_medic": "character-female-a",
	"skin_pilot": "character-female-f",
}

var products: Array = []
var owned := {}
var equipped := ""
var order := {} # order_id, product_id, amount_idr, status, message
var qr_texture: ImageTexture
var poll_seconds := 3.0

var _poll_timer := 0.0
var _order_age := 0.0
var _fake_steam := false


func _ready() -> void:
	if OS.is_debug_build():
		_fake_steam = "fake_steam" in OS.get_cmdline_user_args()
	var file := ConfigFile.new()
	if file.load(SETTINGS_FILE) == OK:
		equipped = file.get_value("skins", "equipped", "")


## Steam requires in-game purchases to use the Steam Wallet, so builds exported with
## the "steam" feature tag can never reach the Midtrans payment code.
func is_steam_build() -> bool:
	return OS.has_feature("steam") or _fake_steam


func payments_allowed() -> bool:
	return Cloud.is_configured() and not is_steam_build()


func refresh() -> void:
	products = await Cloud.fetch_products()
	owned = {}
	for product_id: String in await Cloud.fetch_entitlements():
		owned[product_id] = true
	if not equipped.is_empty() and not owned.has(equipped):
		equip("")
	changed.emit()


func buy(product_id: String) -> void:
	if not payments_allowed() or is_waiting_for_payment():
		return
	order = {"product_id": product_id, "status": "creating", "message": "Creating your QR code..."}
	qr_texture = null
	order_changed.emit()
	var result: Dictionary = await Cloud.create_qris_order(product_id)
	if not result.ok:
		order.status = "error"
		order.message = result.error
		order_changed.emit()
		return
	order.order_id = result.data.order_id
	order.amount_idr = int(result.data.amount_idr)
	order.status = "pending"
	order.message = "Scan with any QRIS app to pay."
	_order_age = 0.0
	_poll_timer = poll_seconds
	var image_data: PackedByteArray = await Cloud.download(result.data.qr_url)
	var image := Image.new()
	if not image_data.is_empty() and image.load_png_from_buffer(image_data) == OK:
		qr_texture = ImageTexture.create_from_image(image)
	else:
		order.message = "The QR code didn't load. Please close this and try again."
	order_changed.emit()


func is_waiting_for_payment() -> bool:
	return order.get("status", "") in ["creating", "pending"]


## Stops watching this order. The server still unlocks the item if the payment
## arrives, and it appears the next time the shop opens.
func close_order() -> void:
	order = {}
	qr_texture = null
	order_changed.emit()


func equip(product_id: String) -> void:
	if not product_id.is_empty() and not owned.has(product_id):
		return
	equipped = product_id
	var file := ConfigFile.new()
	file.set_value("skins", "equipped", equipped)
	file.save(SETTINGS_FILE)
	changed.emit()


func format_price(amount: int) -> String:
	var digits := str(amount)
	var grouped := ""
	while digits.length() > 3:
		grouped = "." + digits.right(3) + grouped
		digits = digits.left(digits.length() - 3)
	return "Rp " + digits + grouped


func _process(delta: float) -> void:
	if order.get("status", "") != "pending":
		return
	_order_age += delta
	_poll_timer -= delta
	if _poll_timer > 0.0:
		return
	_poll_timer = poll_seconds
	if _order_age > ORDER_TIMEOUT_SECONDS:
		order.status = "expired"
		order.message = "This QR code has expired. You weren't charged unless you paid it."
		order_changed.emit()
		return
	var watching: String = order.order_id
	var status := await Cloud.fetch_order_status(watching)
	if order.get("order_id", "") != watching or order.status != "pending":
		return
	match status:
		"paid", "paid_duplicate":
			order.status = "paid"
			order.message = "Payment received. Thank you!"
			order_changed.emit()
			await refresh()
		"expired":
			order.status = "expired"
			order.message = "This QR code has expired."
			order_changed.emit()
		"failed", "refunded":
			order.status = "error"
			order.message = "The payment didn't go through."
			order_changed.emit()
