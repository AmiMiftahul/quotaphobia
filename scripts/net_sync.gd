class_name NetSync
extends RefCounted
## Small helper that attaches a MultiplayerSynchronizer for the listed properties.


static func attach(owner_node: Node, always: Array[NodePath], on_change: Array[NodePath]) -> MultiplayerSynchronizer:
	var config := SceneReplicationConfig.new()
	for property in always:
		config.add_property(property)
		config.property_set_spawn(property, false)
		config.property_set_replication_mode(property, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	for property in on_change:
		config.add_property(property)
		config.property_set_spawn(property, false)
		config.property_set_replication_mode(property, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Sync"
	sync.replication_interval = 0.05
	sync.delta_interval = 0.05
	sync.replication_config = config
	owner_node.add_child(sync)
	sync.root_path = sync.get_path_to(owner_node) if sync.is_inside_tree() else NodePath("..")
	return sync
