class_name GasVent
extends Entity
## A cloud that fills the middle of a room on a timer. It can't chase you, and the
## pause between bursts is always long enough to cross. Beat it with timing.

const RADIUS := 3.2
const ON_SECONDS := 5.0
const OFF_SECONDS := 6.0
const DAMAGE_PER_TICK := 8
const TICK_SECONDS := 1.0
const VENTING := 1

var _cloud: MeshInstance3D
var _light: OmniLight3D
var _particles: CPUParticles3D
var _cycle := 0.0
var _damage_timer := 0.0


func _build(data: Dictionary) -> void:
	_cycle = float(data.index % 5)
	var mesh := SphereMesh.new()
	mesh.radius = RADIUS
	mesh.height = RADIUS * 1.4
	mesh.radial_segments = 48
	mesh.rings = 24
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(0.45, 0.9, 0.2, 0.28)
	mesh.material = material
	_cloud = MeshInstance3D.new()
	_cloud.mesh = mesh
	_cloud.position.y = 0.9
	add_child(_cloud)
	_light = _make_light(Color(0.5, 1.0, 0.2), 1.2, 7.0, 1.0)
	_particles = CPUParticles3D.new()
	_particles.amount = 40
	_particles.lifetime = 2.0
	_particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_particles.emission_sphere_radius = 2.2
	_particles.gravity = Vector3(0, 0.4, 0)
	var dot := SphereMesh.new()
	dot.radius = 0.12
	dot.height = 0.24
	# Each vent shows dozens of these, so every triangle counts.
	dot.radial_segments = 6
	dot.rings = 3
	dot.material = material
	_particles.mesh = dot
	_particles.position.y = 0.8
	add_child(_particles)
	# The grate it comes from, so you can tell where a vent is while it's closed.
	var grate := Assets.instance(Assets.FACTORY % "conveyor-bars-sides")
	grate.scale = Vector3(2.0, 0.3, 2.0)
	add_child(grate)
	_show_state()


func _on_state_changed(_old_state: int) -> void:
	_show_state()
	if net_state == VENTING:
		Sfx.play_3d("gas", position, -4.0, 18.0)


func _show_state() -> void:
	var on := net_state == VENTING
	_cloud.visible = on
	_light.visible = on
	_particles.emitting = on


func _host_tick(delta: float) -> void:
	_cycle += delta
	var total := ON_SECONDS + OFF_SECONDS
	if _cycle >= total:
		_cycle -= total
	net_state = VENTING if _cycle < ON_SECONDS else 0
	if net_state != VENTING:
		_damage_timer = 0.0
		return
	_damage_timer -= delta
	if _damage_timer > 0.0:
		return
	_damage_timer = TICK_SECONDS
	for player in _targets():
		var offset := player.net_pos - position
		offset.y = 0.0
		if offset.length() < RADIUS:
			Session.damage_player(player.peer_id, DAMAGE_PER_TICK)
