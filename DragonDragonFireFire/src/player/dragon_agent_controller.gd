class_name DragonAgentController
extends AIController2D

@export var _target_player : Player


func _ready() -> void:
	if not _target_player:
		_target_player = get_parent() as Player


func get_action_space() -> Dictionary:
	return {
		"move": {"size": 3, "action_type": "discrete"}, # 0: Parado, 1: Esquerda, 2: Direita
		"jump": {"size": 2, "action_type": "discrete"},
		"fire": {"size": 2, "action_type": "discrete"},
		"look_up": {"size": 2, "action_type": "discrete"},
		"down": {"size": 2, "action_type": "discrete"}
	}


func set_action(action) -> void:
	if not is_instance_valid(_target_player):
		return

	var move_action = action["move"]
	if move_action == 0:
		_target_player._action_move = 0.0
	elif move_action == 1:
		_target_player._action_move = -1.0
	else:
		_target_player._action_move = 1.0

	_target_player._action_jump = action["jump"] == 1
	_target_player._action_fire = action["fire"] == 1
	_target_player._action_look_up = action["look_up"] == 1
	_target_player._action_down = action["down"] == 1


func get_obs() -> Dictionary:
	if not is_instance_valid(_target_player):
		return {"obs": []}

	var obs : Array[float] = []
	
	obs.append(_target_player.global_position.x)
	obs.append(_target_player.global_position.y)
	obs.append(_target_player.velocity.x)
	obs.append(_target_player.velocity.y)
	obs.append(1.0 if _target_player._cur_dir == Types.Direction.RIGHT else -1.0)
	obs.append(1.0 if _target_player.is_on_floor() else 0.0)
	obs.append(_target_player._time_since_last_fire_spit)
	
	var time_left = 100.0
	if "time_left" in GameState:
		time_left = GameState.time_left
	obs.append(time_left)

	var enemies = get_tree().get_nodes_in_group("enemies")
	var max_enemies_observed = 3
	var counted_enemies = 0
	
	enemies.sort_custom(func(a, b):
		return _target_player.global_position.distance_to(a.global_position) < _target_player.global_position.distance_to(b.global_position)
	)

	for enemy in enemies:
		if counted_enemies >= max_enemies_observed:
			break
		if is_instance_valid(enemy):
			obs.append(enemy.global_position.x - _target_player.global_position.x)
			obs.append(enemy.global_position.y - _target_player.global_position.y)
			
			# Verificação segura sem passar valor padrão no get()
			var is_alive = 1.0
			if enemy.has("is_alive"):
				is_alive = float(enemy.get("is_alive"))
			obs.append(is_alive)
			
			var type_id = 0.0
			if enemy.has("enemy_type_id"):
				type_id = float(enemy.get("enemy_type_id"))
			obs.append(type_id)
		else:
			obs.append_array([0.0, 0.0, 0.0, 0.0])
		counted_enemies += 1

	while counted_enemies < max_enemies_observed:
		obs.append_array([0.0, 0.0, 0.0, 0.0])
		counted_enemies += 1

	return {"obs": obs}


func get_reward() -> float:
	if _target_player._cur_state == Player.State.DEAD:
		reward -= 5.0
		done = true

	var current_reward = reward
	reward = 0.0
	return current_reward
