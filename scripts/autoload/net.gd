extends Node
## Connections and the crew list. This is the only script that knows about ENet,
## so Steam networking can replace it later without touching gameplay code.

signal players_changed
signal connected
signal connection_ended(reason: String)
signal peer_left(peer: int)

const DEFAULT_PORT := 24567

var players := {} # peer id -> display name
var skins := {} # peer id -> equipped product id
var local_name := "Player"
var rejected_count := 0

var _reject_reason := ""


func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func my_id() -> int:
	return multiplayer.get_unique_id()


func is_online() -> bool:
	return not multiplayer.multiplayer_peer is OfflineMultiplayerPeer


func host(player_name: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	# One slot above the crew size, so a fifth player can be told why they can't join.
	var error := peer.create_server(port, Rules.MAX_PLAYERS)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	local_name = _clean_name(player_name)
	players = {1: local_name}
	skins = {1: _clean_skin(Store.equipped)}
	players_changed.emit()
	return OK


func join(player_name: String, address: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, port)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	local_name = _clean_name(player_name)
	_reject_reason = ""
	return OK


func leave() -> void:
	_end_connection("")


func _clean_name(raw: String) -> String:
	var cleaned := raw.strip_edges().left(16)
	return cleaned if not cleaned.is_empty() else "Player"


func _clean_skin(skin: String) -> String:
	return skin if Store.SKIN_MODELS.has(skin) else ""


func _on_connected_to_server() -> void:
	_rpc_register.rpc_id(1, local_name, Store.equipped)
	connected.emit()


func _on_connection_failed() -> void:
	_end_connection("Could not reach the host.")


func _on_server_disconnected() -> void:
	_end_connection(_reject_reason if not _reject_reason.is_empty() else "The host left the game.")


func _end_connection(reason: String) -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players = {}
	skins = {}
	players_changed.emit()
	connection_ended.emit(reason)


func _on_peer_disconnected(peer: int) -> void:
	if multiplayer.is_server() and players.erase(peer):
		skins.erase(peer)
		_rpc_players.rpc(players, skins)
		peer_left.emit(peer)
		players_changed.emit()


@rpc("any_peer", "reliable")
func _rpc_register(player_name: String, skin: String) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	var reason := ""
	if Session.phase != Session.Phase.LOBBY:
		reason = "That game has already started."
	elif players.size() >= Rules.MAX_PLAYERS:
		reason = "That game is full."
	if not reason.is_empty():
		rejected_count += 1
		_rpc_rejected.rpc_id(peer, reason)
		get_tree().create_timer(0.3).timeout.connect(_kick.bind(peer))
		return
	players[peer] = _clean_name(player_name)
	skins[peer] = _clean_skin(skin)
	_rpc_players.rpc(players, skins)
	players_changed.emit()


func _kick(peer: int) -> void:
	if is_online() and peer in multiplayer.get_peers():
		multiplayer.multiplayer_peer.disconnect_peer(peer)


@rpc("authority", "reliable")
func _rpc_rejected(reason: String) -> void:
	_reject_reason = reason


@rpc("authority", "reliable")
func _rpc_players(new_players: Dictionary, new_skins: Dictionary) -> void:
	players = new_players
	skins = new_skins
	players_changed.emit()
