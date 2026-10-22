
class_name DragonAgentController
extends AIController2D

@export var _target_player: Player

# Normalização das observações.
const POSITION_SCALE: float = 320.0
const VELOCITY_X_SCALE: float = 80.0
const VELOCITY_Y_SCALE: float = 166.0
const FIRE_TIME_SCALE: float = 1.0
const TIME_SCALE: float = 100.0

const MAX_ENEMIES_OBSERVED: int = 3
const OBSERVATION_SIZE: int = 20


func _ready() -> void:
	_find_player()

	if not is_instance_valid(_target_player):
		push_error(
			"[RL] DragonAgentController: Player não encontrado."
		)
		return

	print("[RL] DragonAgentController inicializado.")
	print("[RL] Player: ", _target_player.get_path())


# --- REFERÊNCIA AO PLAYER ---

func _find_player() -> void:
	if is_instance_valid(_target_player):
		return

	var parent := get_parent()

	if parent is Player:
		_target_player = parent as Player


# --- ESPAÇO DE AÇÕES ---

func get_action_space() -> Dictionary:
	return {
		"move": {
			"size": 3,
			"action_type": "discrete"
		},
		"jump": {
			"size": 2,
			"action_type": "discrete"
		},
		"fire": {
			"size": 2,
			"action_type": "discrete"
		},
		"look_up": {
			"size": 2,
			"action_type": "discrete"
		},
		"down": {
			"size": 2,
			"action_type": "discrete"
		}
	}


# --- AÇÕES RECEBIDAS DO PYTHON ---

func set_action(action) -> void:
	if not is_instance_valid(_target_player):
		_find_player()
		if not is_instance_valid(_target_player):
			return

	# Não executa ações após encerrar o episódio.
	if done:
		_target_player.clear_ai_actions()
		return

	if not _target_player.ai_controlled:
		_target_player.clear_ai_actions()
		return

	var move_index: int = int(action["move"])

	var move_direction: float = 0.0

	match move_index:
		0:
			move_direction = 0.0
		1:
			move_direction = -1.0
		2:
			move_direction = 1.0
		_:
			move_direction = 0.0

	_target_player.set_ai_actions(
		move_direction,
		int(action["jump"]) == 1,
		int(action["fire"]) == 1,
		int(action["look_up"]) == 1,
		int(action["down"]) == 1
	)


# --- OBSERVAÇÕES ---

func get_obs() -> Dictionary:
	if not is_instance_valid(_target_player):
		_find_player()

	if not is_instance_valid(_target_player):
		return {
			"obs": _empty_observations()
		}

	var obs: Array[float] = []

	# Posição normalizada.
	obs.append(
		_target_player.global_position.x / POSITION_SCALE
	)
	obs.append(
		_target_player.global_position.y / POSITION_SCALE
	)

	# Velocidade normalizada.
	obs.append(
		_target_player.velocity.x / VELOCITY_X_SCALE
	)
	obs.append(
		_target_player.velocity.y / VELOCITY_Y_SCALE
	)

	# Direção do personagem.
	obs.append(
		1.0 if _target_player._cur_dir == Types.Direction.RIGHT
		else -1.0
	)

	# Contato com o chão.
	obs.append(
		1.0 if _target_player.is_on_floor()
		else 0.0
	)

	# Tempo desde o último disparo.
	obs.append(
		clampf(
			_target_player._time_since_last_fire_spit
			/ FIRE_TIME_SCALE,
			0.0,
			1.0
		)
	)

	# Tempo restante.
	var time_left: float = TIME_SCALE

	var game_time = GameState.get("time_left")

	if game_time != null:
		time_left = float(game_time)

	obs.append(
		clampf(time_left / TIME_SCALE, 0.0, 1.0)
	)

	# Observações dos inimigos.
	_append_enemy_observations(obs)

	return {"obs": obs}


func _empty_observations() -> Array[float]:
	var obs: Array[float] = []

	obs.resize(OBSERVATION_SIZE)
	obs.fill(0.0)

	return obs


# --- OBSERVAÇÕES DOS INIMIGOS ---

func _append_enemy_observations(obs: Array[float]) -> void:
	var enemies: Array[Node] = []

	for node in get_tree().get_nodes_in_group("enemies"):
		if node is Node2D and is_instance_valid(node):
			enemies.append(node)

	# Ordena por proximidade.
	enemies.sort_custom(
		func(a: Node, b: Node) -> bool:
			var enemy_a := a as Node2D
			var enemy_b := b as Node2D

			var distance_a := (
				_target_player.global_position
				.distance_squared_to(enemy_a.global_position)
			)

			var distance_b := (
				_target_player.global_position
				.distance_squared_to(enemy_b.global_position)
			)

			return distance_a < distance_b
	)

	var counted: int = 0

	for node in enemies:
		if counted >= MAX_ENEMIES_OBSERVED:
			break

		var enemy := node as Node2D

		var relative_position: Vector2 = (
			enemy.global_position
			- _target_player.global_position
		)

		obs.append(
			relative_position.x / POSITION_SCALE
		)
		obs.append(
			relative_position.y / POSITION_SCALE
		)

		var is_alive: float = 1.0
		var enemy_type: float = 0.0

		var alive_value = _get_optional_property(
			enemy, "is_alive"
		)

		if alive_value != null:
			is_alive = (
				1.0 if bool(alive_value) else 0.0
			)

		var type_value = _get_optional_property(
			enemy, "enemy_type_id"
		)

		if type_value is int or type_value is float:
			enemy_type = float(type_value)

		obs.append(is_alive)
		obs.append(enemy_type)

		counted += 1

	# Preenche os inimigos ausentes com zeros.
	while counted < MAX_ENEMIES_OBSERVED:
		obs.append_array([
			0.0,
			0.0,
			0.0,
			0.0
		])
		counted += 1


func _get_optional_property(
	object: Object,
	property_name: String
) -> Variant:
	for property in object.get_property_list():
		if str(property["name"]) == property_name:
			return object.get(property_name)

	return null


# --- RECOMPENSAS ---

func get_reward() -> float:
	var current_reward: float = reward

	reward = 0.0

	return current_reward


# --- RESET DO AGENTE ---

func reset_agent() -> void:
	reward = 0.0
	done = false

	if is_instance_valid(_target_player):
		_target_player.clear_ai_actions()
