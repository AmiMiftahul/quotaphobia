class_name Player
extends CharacterBody3D
## One crew member. The owner's machine moves it (so controls feel instant) and
## everyone else smoothly follows. Health and items are decided by the host.

const WALK_SPEED := 4.0
const SPRINT_SPEED := 6.5
const JUMP_SPEED := 4.5
const GRAVITY := 12.0
const STAMINA_DRAIN := 0.25
const STAMINA_REGEN := 0.15
const MOUSE_SENSITIVITY := 0.0025
const MAX_PITCH := 1.4
const FLASH_SECONDS := 0.15
const MODELS := ["character-male-a", "character-female-c", "character-male-d", "character-female-e"]
const MODEL_SCALE := 2.4
const STEP_DISTANCE := 2.2
const ATTACK_SHOW_SECONDS := 0.45

var peer_id := 0
var display_name := ""
var color_index := 0
var net_pos := Vector3.ZERO
var net_yaw := 0.0
var net_flashlight := true
var net_phone_up := false:
	set(up):
		net_phone_up = up
		if _phone_model != null:
			_phone_model.visible = up and not is_local_player
var net_recording := false:
	set(recording):
		net_recording = recording
		if _recording_light != null:
			_recording_light.visible = recording
var net_flashes := 0:
	set(count):
		if count != net_flashes and is_inside_tree():
			_flash_seconds = FLASH_SECONDS
			_phone_flash.visible = true
			if not is_local_player:
				Sfx.play_3d("click", position, -2.0, 18.0)
		net_flashes = count
var phone: PhoneCamera
var is_local_player := false
var stamina := 1.0
var interact_prompt := ""
var input_enabled := true
var bot_move := Vector2.ZERO # Lets the automated tests walk through the real movement code.
var current_animation := ""
var model_name := ""

var _pitch := 0.0
var _backpack_model: MeshInstance3D
var _phone_model: MeshInstance3D
var _recording_light: MeshInstance3D
var _phone_flash: OmniLight3D
var _flash_seconds := 0.0
var _camera: Camera3D
var _flashlight: SpotLight3D
var _body: Node3D
var _animator: AnimationPlayer
var _label: Label3D
var _last_position := Vector3.ZERO
var _step_progress := 0.0
var _focus_item: Scrap
var _focus_console := false
var _focus_terminal := false
var _spectate_index := 0
var _attack_show := 0.0


func setup(peer: int, player_name: String, index: int, spawn_pos: Vector3, skin: String = "") -> void:
	peer_id = peer
	model_name = Store.SKIN_MODELS.get(skin, MODELS[index % MODELS.size()])
	display_name = player_name
	color_index = index
	position = spawn_pos
	net_pos = spawn_pos
	name = "P%d" % peer
	collision_layer = 2
	collision_mask = 1
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position.y = 0.9
	add_child(collision)
	_body = Assets.instance(Assets.CHARACTERS % model_name)
	_body.scale = Vector3.ONE * MODEL_SCALE
	_body.rotation.y = PI # The models face +Z; the game treats -Z as forward.
	add_child(_body)
	_animator = Assets.find_animation_player(_body)
	Assets.set_looping(_animator, ["idle", "walk", "sprint"])
	_last_position = spawn_pos
	_label = Label3D.new()
	_label.text = player_name
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.position.y = 2.1
	_label.pixel_size = 0.006
	add_child(_label)
	_flashlight = SpotLight3D.new()
	_flashlight.spot_range = 22.0
	_flashlight.spot_angle = 40.0
	_flashlight.spot_angle_attenuation = 0.5 # Fades out softly instead of a hard circle.
	_flashlight.light_energy = 3.5
	_flashlight.position.y = 1.5
	add_child(_flashlight)
	_build_phone_model()
	var pack := BoxMesh.new()
	pack.size = Vector3(0.62, 0.72, 0.34)
	pack.material = Level._material(Color(0.42, 0.28, 0.16))
	_backpack_model = MeshInstance3D.new()
	_backpack_model.mesh = pack
	_backpack_model.position = Vector3(0.0, 0.95, 0.42)
	_backpack_model.visible = false
	add_child(_backpack_model)
	NetSync.attach(self, [^":net_pos", ^":net_yaw"], [^":net_flashlight", ^":net_phone_up", ^":net_recording", ^":net_flashes"])


## What other players see: a phone held up, a red dot while recording, and the flash.
func _build_phone_model() -> void:
	var body := BoxMesh.new()
	body.size = Vector3(0.34, 0.2, 0.03)
	body.material = Level._material(Color(0.06, 0.06, 0.08))
	_phone_model = MeshInstance3D.new()
	_phone_model.mesh = body
	_phone_model.position = Vector3(0.0, 1.35, -0.55)
	_phone_model.visible = false
	add_child(_phone_model)
	var dot := SphereMesh.new()
	dot.radius = 0.03
	dot.height = 0.06
	dot.radial_segments = 8
	dot.rings = 4
	var red := StandardMaterial3D.new()
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.albedo_color = Color.RED
	dot.material = red
	_recording_light = MeshInstance3D.new()
	_recording_light.mesh = dot
	_recording_light.position = Vector3(0.12, 0.05, -0.03)
	_recording_light.visible = false
	_phone_model.add_child(_recording_light)
	_phone_flash = OmniLight3D.new()
	_phone_flash.light_color = Color(1.0, 0.98, 0.9)
	_phone_flash.light_energy = 5.0
	_phone_flash.omni_range = 14.0
	_phone_flash.position = Vector3(0.0, 1.6, -0.7)
	_phone_flash.visible = false
	add_child(_phone_flash)


func _process(delta: float) -> void:
	# Other players can see when you've got something in your backpack.
	_backpack_model.visible = not is_local_player and Session.items_held_by(peer_id).size() >= 2
	if _flash_seconds > 0.0:
		_flash_seconds -= delta
		if _flash_seconds <= 0.0:
			_phone_flash.visible = false


func _ready() -> void:
	is_local_player = is_local()
	if not is_local():
		return
	_body.visible = false
	_label.visible = false
	_camera = Camera3D.new()
	_camera.position.y = 1.6
	_camera.far = 60.0
	add_child(_camera)
	_camera.make_current()
	_flashlight.reparent(_camera, false)
	_flashlight.position = Vector3(0.25, -0.2, 0.0)
	_apply_settings()
	Settings.changed.connect(_apply_settings)
	phone = PhoneCamera.new()
	phone.name = "Phone"
	add_child(phone)
	phone.setup(self)


func _apply_settings() -> void:
	_camera.fov = Settings.value("fov")
	_flashlight.shadow_enabled = Settings.value("shadows")


func eye_transform() -> Transform3D:
	return _camera.global_transform


func is_local() -> bool:
	return peer_id == Net.my_id()


func is_alive() -> bool:
	return Session.is_player_alive(peer_id)


func forward() -> Vector3:
	return Vector3.FORWARD.rotated(Vector3.UP, rotation.y)


## Used for round starts and by the tests. Only the owner may call this.
func teleport(pos: Vector3) -> void:
	position = pos
	net_pos = pos
	velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	if not Session.in_world():
		return
	if not is_local():
		position = position.lerp(net_pos, minf(1.0, delta * 15.0))
		rotation.y = lerp_angle(rotation.y, net_yaw, minf(1.0, delta * 15.0))
		_flashlight.visible = net_flashlight and is_alive()
		_label.visible = is_alive()
		_animate_and_step(delta)
		return
	if not is_alive():
		phone.put_away()
		_flashlight.visible = false
		interact_prompt = "You died. Press %s to watch a crewmate." % Settings.prompt_for("jump")
		_follow_teammate()
		return
	_look_with_stick(delta)
	_move(delta)
	_update_focus()
	net_pos = position
	net_yaw = rotation.y
	_animate_and_step(delta)


## Animation and footsteps follow how fast the character actually moved, so the
## same code works for your own character and for everyone else's.
func _animate_and_step(delta: float) -> void:
	var moved := position - _last_position
	moved.y = 0.0
	_last_position = position
	if not is_alive():
		_play_animation("die")
		return
	var speed := moved.length() / maxf(delta, 0.001)
	if _attack_show > 0.0:
		_attack_show -= delta
		_play_animation("attack-melee-right")
	else:
		_play_animation("sprint" if speed > 5.0 else ("walk" if speed > 0.3 else "idle"))
	_step_progress += moved.length()
	if _step_progress >= STEP_DISTANCE:
		_step_progress = 0.0
		if is_local():
			Sfx.play_2d("step", -14.0)
		else:
			Sfx.play_3d("step", position, -8.0, 20.0)


## Everyone else sees you swing when you use your gear.
func show_attack() -> void:
	_attack_show = ATTACK_SHOW_SECONDS


func _play_animation(animation_name: String) -> void:
	if current_animation != animation_name:
		current_animation = animation_name
		_animator.play(animation_name, 0.15)


func _look_with_stick(delta: float) -> void:
	if not input_enabled or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if stick == Vector2.ZERO:
		return
	var speed: float = Settings.BASE_LOOK_SPEED * Settings.value("pad_sensitivity") * delta
	var vertical: float = -stick.y if Settings.value("pad_invert_y") else stick.y
	_turn(stick.x * speed, vertical * speed)


## Both in radians: positive looks right, and positive looks down.
func _turn(right: float, down: float) -> void:
	rotate_y(-right)
	_pitch = clampf(_pitch - down, -MAX_PITCH, MAX_PITCH)
	_camera.rotation.x = _pitch


func _move(delta: float) -> void:
	var move := bot_move
	var can_act := input_enabled and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if can_act:
		move += Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var sprinting := can_act and Input.is_action_pressed("sprint") and stamina > 0.0 and move != Vector2.ZERO
	var regen: float = STAMINA_REGEN * (Session.layout.theme.stamina_regen if Session.layout != null else 1.0)
	stamina = clampf(stamina + (-STAMINA_DRAIN if sprinting else regen) * delta, 0.0, 1.0)
	var speed := (SPRINT_SPEED if sprinting else WALK_SPEED) * (1.0 - Session.carried_weight(peer_id))
	var direction := (transform.basis * Vector3(move.x, 0.0, move.y)).normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	if is_on_floor():
		velocity.y = 0.0
		if can_act and Input.is_action_just_pressed("jump"):
			velocity.y = JUMP_SPEED
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()


func _update_focus() -> void:
	_focus_item = null
	_focus_console = false
	_focus_terminal = false
	interact_prompt = ""
	var carried := Session.items_held_by(peer_id)
	var best_distance := Rules.INTERACT_RANGE
	for item: Scrap in Session.scrap_root.get_children():
		var distance := position.distance_to(item.position)
		var offset := (item.position - position).normalized()
		if item.holder_id == 0 and not item.armed and distance < best_distance and forward().dot(offset) > 0.4:
			best_distance = distance
			_focus_item = item
	var lines := PackedStringArray()
	var held := Session.item_held_by(peer_id)
	if held != null:
		if held.is_tool():
			lines.append("%s: %s" % [Settings.prompt_for("use_item"), _use_verb(held)])
		var drop_line := "%s: drop %s" % [Settings.prompt_for("drop"), held.describe()]
		if carried.size() >= 2:
			drop_line += "    %s: switch item" % Settings.prompt_for("cycle_item")
		lines.append(drop_line)
	if _focus_item != null:
		if carried.size() >= Rules.CARRY_LIMIT:
			lines.append("Your hands and backpack are full")
			_focus_item = null
		else:
			lines.append("%s: pick up %s" % [Settings.prompt_for("interact"), _focus_item.describe()])
	interact_prompt = "\n".join(lines)
	if position.distance_to(Rules.CONSOLE_POS) < Rules.INTERACT_RANGE:
		_focus_console = true
		if Session.phase == Session.Phase.ORBIT:
			interact_prompt = "%s: pull the lever and land on %s" % [Settings.prompt_for("interact"), MapThemes.get_theme(Session.next_map).name]
		else:
			interact_prompt = "%s: launch the ship and end the round" % Settings.prompt_for("interact")
	elif position.distance_to(Rules.TERMINAL_POS) < Rules.INTERACT_RANGE:
		_focus_terminal = true
		interact_prompt = "%s: use the terminal to buy gear" % Settings.prompt_for("interact")


func _use_verb(item: Scrap) -> String:
	match item.kind:
		Tools.SHOVEL: return "swing the shovel"
		Tools.STUN_GRENADE: return "throw the stun grenade"
	return "zap (%d left)" % item.charges if item.charges > 0 else "zap (empty until orbit)"


func _follow_teammate() -> void:
	var alive: Array[Player] = []
	for other: Player in Session.players_root.get_children():
		if other != self and other.is_alive():
			alive.append(other)
	if alive.is_empty():
		return
	var target := alive[_spectate_index % alive.size()]
	_camera.global_position = target.global_position + Vector3(0, 2.6, 0) - target.forward() * 3.0
	_camera.look_at(target.global_position + Vector3(0, 1.4, 0))


func _unhandled_input(event: InputEvent) -> void:
	if not is_local() or not Session.in_world():
		return
	if not is_alive():
		if event.is_action_pressed("jump"):
			_spectate_index += 1
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var sensitivity: float = MOUSE_SENSITIVITY * Settings.value("mouse_sensitivity")
		var vertical: float = -event.relative.y if Settings.value("invert_y") else event.relative.y
		_turn(event.relative.x * sensitivity, vertical * sensitivity)
	elif event.is_action_pressed("interact"):
		if _focus_console:
			Session.request_launch.rpc_id(1)
		elif _focus_terminal:
			Session.terminal_requested.emit()
		elif _focus_item != null:
			Session.request_pickup.rpc_id(1, _focus_item.item_id)
	elif event.is_action_pressed("drop"):
		Session.request_drop.rpc_id(1)
	elif event.is_action_pressed("cycle_item"):
		Session.request_cycle_item.rpc_id(1)
	elif event.is_action_pressed("phone"):
		if phone.is_up:
			phone.put_away()
		else:
			phone.raise()
	elif event.is_action_pressed("use_item"):
		# One button: a photo while the phone is up, otherwise whatever gear you hold.
		if phone.is_up:
			phone.take_photo()
		elif Session.item_held_by(peer_id) != null and Session.item_held_by(peer_id).is_tool():
			Session.request_use_item.rpc_id(1)
	elif event.is_action_pressed("phone_record") and phone.is_up:
		phone.start_recording()
	elif event.is_action_pressed("flashlight"):
		net_flashlight = not net_flashlight
		_flashlight.visible = net_flashlight
		Sfx.play_2d("switch", -12.0)
