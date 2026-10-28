class_name PlayerAIController
extends AIController2D

@onready var player: Player = _get_player_safely()

var ai_input_direction: float = 0.0
var ai_input_jump: bool = false
var ai_input_fire: bool = false
var ai_input_up: bool = false
var ai_input_down: bool = false

# Controle de pontuação e tempo para o cálculo de recompensa
var last_score: int = 0
var level_time_elapsed: float = 0.0

const MAX_ENEMIES_OBS: int = 3
const MAX_PROJECTILES_OBS: int = 3
const MAX_ITEMS_OBS: int = 2
const MAX_PLATFORMS_OBS: int = 3

func _get_player_safely() -> Player:
	var p = get_parent()
	while p and not p is Player:
		p = p.get_parent()
	if not p:
		p = get_tree().current_scene.find_child("Player", true, false)
	return p as Player

func get_action_space() -> Dictionary:
	return {
		"move_action": { "size": 1, "action_type": "continuous" },
		"jump_action": { "size": 1, "action_type": "discrete" },
		"fire_action": { "size": 1, "action_type": "discrete" },
		"up_action": { "size": 1, "action_type": "discrete" },
		"down_action": { "size": 1, "action_type": "discrete" }
	}

func set_action(action) -> void:
	if not is_instance_valid(player):
		player = _get_player_safely()
		if not player:
			return

	var get_val = func(act_key, default = 0.0):
		if not action.has(act_key):
			return default
		var val = action[act_key]
		if typeof(val) == TYPE_ARRAY or typeof(val) == TYPE_PACKED_FLOAT32_ARRAY or typeof(val) == TYPE_PACKED_INT32_ARRAY:
			if val.size() > 0:
				return val[0]
			return default
		return val

	ai_input_direction = get_val.call("move_action", 0.0)
	ai_input_jump = get_val.call("jump_action", 0.0) > 0.5
	ai_input_fire = get_val.call("fire_action", 0.0) > 0.5
	ai_input_up = get_val.call("up_action", 0.0) > 0.5
	ai_input_down = get_val.call("down_action", 0.0) > 0.5

	player.ai_input_direction = ai_input_direction
	player.ai_input_jump = ai_input_jump
	player.ai_input_fire = ai_input_fire
	player.ai_input_up = ai_input_up
	player.ai_input_down = ai_input_down

func get_obs() -> Dictionary:
	if not is_instance_valid(player) or player.is_queued_for_deletion():
		player = _get_player_safely()
		if not is_instance_valid(player):
			return { "obs": [] }

	var obs: Array = []
	obs.append(player.velocity.x)
	obs.append(player.velocity.y)
	obs.append(1.0 if player.is_on_floor() else 0.0)

	var root_scene = player.get_tree().current_scene if player.get_tree() else null
	if not root_scene:
		while obs.size() < 31:
			obs.append(0.0)
		return { "obs": obs }

	var enemies = _find_nodes_of_class(root_scene, "Enemy")
	enemies.sort_custom(func(a, b):
		return player.global_position.distance_to(a.global_position) < player.global_position.distance_to(b.global_position)
	)
	
	for i in range(MAX_ENEMIES_OBS):
		if i < enemies.size() and is_instance_valid(enemies[i]):
			var en = enemies[i]
			var rel_pos = en.global_position - player.global_position
			obs.append(rel_pos.x)
			obs.append(rel_pos.y)
			
			var enemy_type_id = 0.0
			if en is EnemyWalker:
				enemy_type_id = 1.0
			elif en is EnemyFlyer:
				enemy_type_id = 2.0
			elif en is EnemyShooter:
				enemy_type_id = 3.0
			elif en is EnemySweeper:
				enemy_type_id = 4.0
			obs.append(enemy_type_id)
		else:
			obs.append(0.0)
			obs.append(0.0)
			obs.append(0.0)

	var projectiles = _find_nodes_in_group_or_name(root_scene, "projectiles")
	projectiles.sort_custom(func(a, b):
		return player.global_position.distance_to(a.global_position) < player.global_position.distance_to(b.global_position)
	)
	for i in range(MAX_PROJECTILES_OBS):
		if i < projectiles.size() and is_instance_valid(projectiles[i]):
			var proj = projectiles[i]
			var rel_pos = proj.global_position - player.global_position
			obs.append(rel_pos.x)
			obs.append(rel_pos.y)
		else:
			obs.append(0.0)
			obs.append(0.0)

	var items = _find_nodes_in_group_or_name(root_scene, "items")
	items.sort_custom(func(a, b):
		return player.global_position.distance_to(a.global_position) < player.global_position.distance_to(b.global_position)
	)
	for i in range(MAX_ITEMS_OBS):
		if i < items.size() and is_instance_valid(items[i]):
			var item = items[i]
			var rel_pos = item.global_position - player.global_position
			obs.append(rel_pos.x)
			obs.append(rel_pos.y)
		else:
			obs.append(0.0)
			obs.append(0.0)

	var platforms = _find_platforms(root_scene)
	platforms.sort_custom(func(a, b):
		return player.global_position.distance_to(a.global_position) < player.global_position.distance_to(b.global_position)
	)
	for i in range(MAX_PLATFORMS_OBS):
		if i < platforms.size() and is_instance_valid(platforms[i]):
			var plat = platforms[i]
			var rel_pos = plat.global_position - player.global_position
			obs.append(rel_pos.x)
			obs.append(rel_pos.y)
			var is_flammable = 1.0 if plat.is_in_group("flammable") or plat.has_meta("flammable") else 0.0
			obs.append(is_flammable)
		else:
			obs.append(0.0)
			obs.append(0.0)
			obs.append(0.0)

	while obs.size() < 31:
		obs.append(0.0)

	return { "obs": obs }

func get_obs_space() -> Dictionary:
	return {
		"obs": {
			"size": [31],
			"space": "box"
		}
	}

func get_reward() -> float:
	if not is_instance_valid(player):
		return 0.0
		
	var reward = 0.0
	
	# Acumula tempo decorrido no nível atual para aplicar punição progressiva
	level_time_elapsed += 0.016 # Aproximadamente 1 frame a 60 FPS
	reward -= level_time_elapsed * 0.001 # Punição cresce quanto mais tempo o agente demorar
	
	# Recompensa positiva quando o score aumenta (pontos ganhos)
	if GameState.score > last_score:
		var score_diff = GameState.score - last_score
		reward += float(score_diff) * 0.1 # Bonificação proporcional aos pontos recebidos
		last_score = GameState.score
		
	# Punição por morte
	if player._cur_state == player.State.DEAD:
		reward -= 1.0
	else:
		reward += 0.01 # Pequeno bônus por sobrevivência frame a frame
		
	return reward

func reset() -> void:
	player = _get_player_safely()
	level_time_elapsed = 0.0
	last_score = GameState.score

func _find_nodes_of_class(node: Node, class_name_str: String) -> Array:
	var results = []
	if node.is_class(class_name_str) or node.get_script() and node.get_script().get_global_name() == class_name_str:
		results.append(node)
	elif class_name_str == "Enemy" and node is Enemy:
		results.append(node)
		
	for child in node.get_children():
		results.append_array(_find_nodes_of_class(child, class_name_str))
	return results

func _find_nodes_in_group_or_name(node: Node, keyword: String) -> Array:
	var results = []
	if node.name.to_lower().contains(keyword) or node.is_in_group(keyword):
		results.append(node)
	for child in node.get_children():
		results.append_array(_find_nodes_in_group_or_name(child, keyword))
	return results

func _find_platforms(node: Node) -> Array:
	var results = []
	if node.name.to_lower().contains("platform") or node.name.to_lower().contains("tilemap"):
		results.append(node)
	for child in node.get_children():
		results.append_array(_find_platforms(child))
	return results
