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
const MAX_PLATFORMS_OBS: int = 5

const MAX_MAP_TILES_TO_SCAN: int = 2000

const PLATFORM_TYPE_STATIC: float = 0.0
const PLATFORM_TYPE_DYNAMIC: float = 1.0

# ==========================================
# DETECÇÃO DE AGENTE PRESO
# ==========================================

const STUCK_MIN_HORIZONTAL_RANGE: float = 24.0
const STUCK_GRACE_TIME: float = 2.0
const STUCK_PENALTY_PER_SECOND: float = 0.25
const STUCK_INPUT_THRESHOLD: float = 0.1

# ==========================================
# RECOMPENSA POR DIREÇÃO DOS DISPAROS
# ==========================================

const SHOT_REWARD_CORRECT: float = 0.10
const SHOT_PENALTY_WRONG: float = 0.05

const SHOT_TARGET_MAX_DISTANCE: float = 500.0
const SHOT_DIRECTION_ALIGNMENT: float = 0.70

# ==========================================
# RECOMPENSA POR APROXIMAÇÃO DOS INIMIGOS
# ==========================================

const ENEMY_APPROACH_REWARD_SCALE: float = 0.002
const ENEMY_APPROACH_MAX_REWARD: float = 0.03
const ENEMY_APPROACH_MAX_DISTANCE: float = 1200.0

# Ignora mudanças de posição muito grandes, como teletransportes.
const ENEMY_APPROACH_MAX_STEP_DISTANCE: float = 30.0
var previous_player_position: Vector2 = Vector2.ZERO
var previous_enemy_position: Vector2 = Vector2.ZERO

var previous_enemy_distance: float = -1.0
var previous_enemy_id: int = -1


var last_shots_fired: int = 0

var stuck_timer: float = 0.0
var stuck_anchor_x: float = 0.0
var is_stuck: bool = false

func _get_player_safely() -> Player:
	var root = get_tree().current_scene
	if not root:
		return null
		
	# Busca por todos os nós que são do tipo Player na árvore de cena atual
	var players = _find_all_players(root)
	if players.size() > 0:
		# Retorna o player mais recente (último da lista)
		return players[players.size() - 1] as Player
		
	# Fallback caso não encontre pela busca recursiva
	var p = get_parent()
	while p and not p is Player:
		p = p.get_parent()
	return p as Player

func _find_all_players(node: Node) -> Array:
	var results = []
	if node is Player:
		results.append(node)
	for child in node.get_children():
		results.append_array(_find_all_players(child))
	return results

func get_action_space() -> Dictionary:
	return {
		"move_action": { "size": 1, "action_type": "continuous" },
		"jump_action": { "size": 1, "action_type": "discrete" },
		"fire_action": { "size": 1, "action_type": "discrete" },
		"up_action": { "size": 1, "action_type": "discrete" },
		"down_action": { "size": 1, "action_type": "discrete" }
	}

func set_action(action) -> void:
	# Sempre atualiza para pegar o player mais recente antes de aplicar a ação
	player = _get_player_safely()
	if not is_instance_valid(player):
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
	player = _get_player_safely()

	if not is_instance_valid(player) or player.is_queued_for_deletion():
		return {"obs": []}

	var obs: Array = []

	# ==========================================
	# 1. INFORMAÇÕES DO JOGADOR
	# ==========================================

	obs.append(clampf(player.velocity.x / 500.0, -1.0, 1.0))
	obs.append(clampf(player.velocity.y / 1000.0, -1.0, 1.0))
	obs.append(1.0 if player.is_on_floor() else 0.0)

	# ==========================================
	# 2. CENÁRIO
	# ==========================================

	var root_scene = get_tree().current_scene

	if not root_scene:
		while obs.size() < 47:
			obs.append(0.0)

		return {"obs": obs}

	# ==========================================
	# 3. INIMIGOS
	# ==========================================

	var enemies = _find_nodes_of_class(root_scene, "Enemy")

	enemies = enemies.filter(func(e):
		return is_instance_valid(e) and e is Node2D
	)

	enemies.sort_custom(func(a, b):
		return player.global_position.distance_squared_to(a.global_position) \
			< player.global_position.distance_squared_to(b.global_position)
	)

	for i in range(MAX_ENEMIES_OBS):
		if i < enemies.size():
			var enemy = enemies[i]
			var rel = enemy.global_position - player.global_position

			obs.append(clampf(rel.x / 1000.0, -1.0, 1.0))
			obs.append(clampf(rel.y / 1000.0, -1.0, 1.0))

			var type_id := 0.0

			if enemy is EnemyWalker:
				type_id = 1.0
			elif enemy is EnemyFlyer:
				type_id = 2.0
			elif enemy is EnemyShooter:
				type_id = 3.0
			elif enemy is EnemySweeper:
				type_id = 4.0

			obs.append(type_id)
		else:
			obs.append_array([0.0, 0.0, 0.0])

	# ==========================================
	# 4. PROJÉTEIS
	# ==========================================

	var projectiles = _find_nodes_in_group_or_name(
		root_scene,
		"projectiles"
	)

	projectiles = projectiles.filter(func(p):
		return is_instance_valid(p) and p is Node2D
	)

	projectiles.sort_custom(func(a, b):
		return player.global_position.distance_squared_to(a.global_position) \
			< player.global_position.distance_squared_to(b.global_position)
	)
	
	var wall_normal := Vector2.ZERO

	if player.is_on_wall():
		wall_normal = player.get_wall_normal()

	obs.append(wall_normal.x)
	obs.append(wall_normal.y)

	for i in range(MAX_PROJECTILES_OBS):
		if i < projectiles.size():
			var proj = projectiles[i]
			var rel = proj.global_position - player.global_position

			obs.append(clampf(rel.x / 1000.0, -1.0, 1.0))
			obs.append(clampf(rel.y / 1000.0, -1.0, 1.0))
		else:
			obs.append_array([0.0, 0.0])

	# ==========================================
	# 5. ITENS
	# ==========================================

	var items = _find_nodes_in_group_or_name(root_scene, "items")

	items = items.filter(func(item):
		return is_instance_valid(item) and item is Node2D
	)

	items.sort_custom(func(a, b):
		return player.global_position.distance_squared_to(a.global_position) \
			< player.global_position.distance_squared_to(b.global_position)
	)

	for i in range(MAX_ITEMS_OBS):
		if i < items.size():
			var item = items[i]
			var rel = item.global_position - player.global_position

			obs.append(clampf(rel.x / 1000.0, -1.0, 1.0))
			obs.append(clampf(rel.y / 1000.0, -1.0, 1.0))
		else:
			obs.append_array([0.0, 0.0])

	# ==========================================
	# 6. PLATAFORMAS
	# ==========================================

	var platforms = _find_platforms(root_scene)

	# Ordena pelas superfícies mais próximas.
	platforms.sort_custom(func(a, b):
		var pos_a := Vector2(
			a.center_x,
			a.top_y
		)

		var pos_b := Vector2(
			b.center_x,
			b.top_y
		)

		return player.global_position.distance_squared_to(pos_a) \
			< player.global_position.distance_squared_to(pos_b)
	)

	for i in range(MAX_PLATFORMS_OBS):
		if i < platforms.size():
			var plat = platforms[i]

			var rel_x = plat.center_x - player.global_position.x
			var rel_y = plat.top_y - player.global_position.y

			obs.append(clampf(rel_x / 1000.0, -1.0, 1.0))
			obs.append(clampf(rel_y / 1000.0, -1.0, 1.0))
			obs.append(clampf(plat.width / 500.0, 0.0, 1.0))
			obs.append(plat.flammable)
			obs.append(plat.dynamic)
		else:
			obs.append_array([
				0.0, 0.0, 0.0, 0.0, 0.0
			])

	# ==========================================
	# 7. GARANTIR TAMANHO FIXO
	# ==========================================

	while obs.size() < 47:
		obs.append(0.0)

	return {"obs": obs}

func get_obs_space() -> Dictionary:
	return {
		"obs": {
			"size": [49],
			"space": "box"
		}
	}
	
func _get_tile_set(node: Node) -> TileSet:
	if node is TileMapLayer:
		return node.tile_set

	if node is TileMap:
		return node.tile_set

	return null


func _get_nearest_enemy() -> Node2D:
	if not is_instance_valid(player):
		return null

	var root_scene := get_tree().current_scene

	if not is_instance_valid(root_scene):
		return null

	var enemies := _find_nodes_of_class(root_scene, "Enemy")

	var nearest_enemy: Node2D = null
	var nearest_distance: float = INF

	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue

		if enemy.is_queued_for_deletion():
			continue

		if not enemy is Node2D:
			continue

		var distance: float = player.global_position.distance_to(
			enemy.global_position
		)

		if distance < nearest_distance:
			nearest_distance = distance
			nearest_enemy = enemy

	return nearest_enemy
	

func _update_enemy_approach_reward() -> float:
	if not is_instance_valid(player):
		return 0.0

	if player._cur_state == player.State.DEAD:
		previous_enemy_distance = -1.0
		previous_enemy_id = -1
		return 0.0

	var enemy := _get_nearest_enemy()

	if not is_instance_valid(enemy):
		previous_enemy_distance = -1.0
		previous_enemy_id = -1
		return 0.0

	var current_enemy_id: int = enemy.get_instance_id()

	var player_position: Vector2 = player.global_position
	var enemy_position: Vector2 = enemy.global_position

	var difference: Vector2 = enemy_position - player_position
	var current_distance: float = difference.length()

	if current_distance > ENEMY_APPROACH_MAX_DISTANCE:
		previous_enemy_distance = -1.0
		previous_enemy_id = -1
		return 0.0

	# Inicializa as referências quando encontra um novo alvo.
	if previous_enemy_id != current_enemy_id:
		previous_enemy_id = current_enemy_id
		previous_enemy_distance = current_distance
		previous_player_position = player_position
		previous_enemy_position = enemy_position
		return 0.0

	# Movimento real do jogador.
	var player_displacement: Vector2 = (
		player_position - previous_player_position
	)

	# Atualiza as posições de referência.
	previous_player_position = player_position
	previous_enemy_position = enemy_position
	previous_enemy_distance = current_distance

	# Ignora teletransportes e deslocamentos anormais.
	if player_displacement.length() > ENEMY_APPROACH_MAX_STEP_DISTANCE:
		return 0.0

	if current_distance <= 0.001:
		return 0.0

	# Direção XY do jogador até o inimigo.
	var direction_to_enemy: Vector2 = difference.normalized()

	# Projeta o movimento do jogador na direção do inimigo.
	var approach_distance: float = player_displacement.dot(
		direction_to_enemy
	)

	# Só recompensa aproximação.
	if approach_distance <= 0.0:
		return 0.0

	var reward: float = (
		approach_distance * ENEMY_APPROACH_REWARD_SCALE
	)

	return minf(reward, ENEMY_APPROACH_MAX_REWARD)

func _is_burnable_target(node: Node) -> bool:
	if not node is Node2D:
		return false

	return node.get_node_or_null("BurnComponent") != null


func _collect_burnable_targets(node: Node, targets: Array) -> void:
	if _is_burnable_target(node):
		targets.append(node)

	for child in node.get_children():
		_collect_burnable_targets(child, targets)


func _get_shot_direction_reward() -> float:
	if not is_instance_valid(player):
		return 0.0

	var root_scene := get_tree().current_scene

	if not is_instance_valid(root_scene):
		return 0.0

	# Direção registrada no momento em que o tiro aconteceu.
	var shot_direction: Vector2 = player.ai_last_shot_direction.normalized()

	if shot_direction == Vector2.ZERO:
		return 0.0

	# ==========================================
	# 1. LOCALIZAR ALVOS
	# ==========================================

	var targets: Array = []

	var enemies := _find_nodes_of_class(root_scene, "Enemy")

	for enemy in enemies:
		if is_instance_valid(enemy) and enemy is Node2D:
			targets.append(enemy)

	_collect_burnable_targets(root_scene, targets)

	# ==========================================
	# 2. AVALIAR DIREÇÃO DOS ALVOS
	# ==========================================

	var best_alignment: float = 0.0
	var found_target: bool = false

	for target in targets:
		if not is_instance_valid(target):
			continue

		if not target is Node2D:
			continue

		var target_position: Vector2 = target.global_position
		var difference: Vector2 = target_position - player.global_position

		var distance: float = difference.length()

		# Ignora alvos muito distantes.
		if distance <= 0.001 or distance > SHOT_TARGET_MAX_DISTANCE:
			continue

		var target_direction: Vector2 = difference / distance

		# Produto escalar:
		# +1 = mesma direção do tiro.
		#  0 = perpendicular.
		# -1 = direção oposta.
		var alignment: float = shot_direction.dot(target_direction)

		if not found_target or absf(alignment) > absf(best_alignment):
			best_alignment = alignment
			found_target = true

	if not found_target:
		return 0.0

	# ==========================================
	# 3. RECOMPENSA OU PENALIDADE
	# ==========================================

	if best_alignment >= SHOT_DIRECTION_ALIGNMENT:
		return SHOT_REWARD_CORRECT

	if best_alignment <= -SHOT_DIRECTION_ALIGNMENT:
		return -SHOT_PENALTY_WRONG

	return 0.0



func _update_shot_reward() -> float:
	if not is_instance_valid(player):
		return 0.0

	var current_shots: int = player.ai_shots_fired_total

	# Protege contra reinicialização do contador.
	if current_shots < last_shots_fired:
		last_shots_fired = current_shots
		return 0.0

	var new_shots: int = current_shots - last_shots_fired

	if new_shots <= 0:
		return 0.0

	last_shots_fired = current_shots

	var reward: float = 0.0

	for i in range(new_shots):
		reward += _get_shot_direction_reward()

	return reward


func get_reward() -> float:
	player = _get_player_safely()

	if not is_instance_valid(player):
		return 0.0

	var reward: float = 0.0

	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)

	# ==========================================
	# 1. PENALIDADE TEMPORAL
	# ==========================================

	level_time_elapsed += delta
	reward -= 0.001 * delta

	# ==========================================
	# 2. RECOMPENSA POR PONTUAÇÃO
	# ==========================================

	if GameState.score > last_score:
		var score_diff: int = GameState.score - last_score
		reward += float(score_diff) * 0.1
		last_score = GameState.score

	# ==========================================
	# 3. PENALIDADE POR FICAR PRESO
	# ==========================================

	reward += _update_stuck_detection(delta)

	# ==========================================
	# 4. RECOMPENSA POR DIREÇÃO DOS DISPAROS
	# ==========================================

	reward += _update_shot_reward()
	reward += _update_enemy_approach_reward()

	# ==========================================
	# 5. PENALIDADE POR MORTE
	# ==========================================

	if player._cur_state == player.State.DEAD:
		reward -= 1.0
	else:
		reward += 0.01

	return reward


func reset() -> void:
	player = _get_player_safely()

	level_time_elapsed = 0.0
	last_score = GameState.score

	stuck_timer = 0.0
	is_stuck = false

	previous_enemy_distance = -1.0
	previous_enemy_id = -1

	previous_player_position = Vector2.ZERO
	previous_enemy_position = Vector2.ZERO

	if is_instance_valid(player):
		stuck_anchor_x = player.global_position.x
		last_shots_fired = player.ai_shots_fired_total
	else:
		stuck_anchor_x = 0.0
		last_shots_fired = 0
		

func _update_stuck_detection(delta: float) -> float:
	if not is_instance_valid(player):
		return 0.0

	# Ignora jogadores mortos.
	if player._cur_state == player.State.DEAD:
		stuck_timer = 0.0
		is_stuck = false
		stuck_anchor_x = player.global_position.x
		return 0.0

	# Verifica se o agente está tentando se movimentar.
	var attempting: bool = (
		absf(player.ai_input_direction) >= STUCK_INPUT_THRESHOLD
	)

	# Se não estiver tentando andar, reinicia a detecção.
	if not attempting:
		stuck_timer = 0.0
		is_stuck = false
		stuck_anchor_x = player.global_position.x
		return 0.0

	# Calcula o deslocamento horizontal.
	var distance: float = absf(
		player.global_position.x - stuck_anchor_x
	)

	# Se percorreu a distância mínima, considera que houve progresso.
	if distance >= STUCK_MIN_HORIZONTAL_RANGE:
		stuck_anchor_x = player.global_position.x
		stuck_timer = 0.0
		is_stuck = false
		return 0.0

	# Acumula o tempo sem progresso.
	stuck_timer += delta

	# Tempo de tolerância.
	if stuck_timer < STUCK_GRACE_TIME:
		return 0.0

	# Agente identificado como preso.
	is_stuck = true

	# Debug a cada aproximadamente 1 segundo.
	if Engine.get_process_frames() % 60 == 0:
		print(
			"[AI] PRESO! Tempo: ",
			snappedf(stuck_timer, 0.1),
			" | Distância: ",
			snappedf(distance, 0.1)
		)

	# Aplica penalidade.
	return -STUCK_PENALTY_PER_SECOND * delta

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

func _find_platforms(root: Node) -> Array:
	var segments: Array = []

	_collect_platform_segments(root, segments)

	return segments
	
func _collect_platform_segments(node: Node, segments: Array) -> void:
	if node is TileMapLayer or node is TileMap:
		var tilemap = node as Node2D

		var is_dynamic := (
			node.name.to_lower().contains("dynamic")
			or node.name.to_lower().contains("dinam")
			or node.is_in_group("dynamic_platforms")
		)

		var layer_count := 1

		if node is TileMap:
			layer_count = node.get_layers_count()

		for layer_index in range(layer_count):
			var current_tile_set := _get_tile_set(node)

			if current_tile_set == null:
				continue
			var cells: Array[Vector2i] = []

			if node is TileMapLayer:
				cells = node.get_used_cells()
			else:
				cells = node.get_used_cells(layer_index)

			if cells.size() > MAX_MAP_TILES_TO_SCAN:
				cells.resize(MAX_MAP_TILES_TO_SCAN)

			var rows: Dictionary = {}
			var burnable_cells := _collect_burnable_cells(
				get_tree().current_scene,
				tilemap
			)

			for cell in cells:
				var tile_data: TileData = null

				if node is TileMapLayer:
					tile_data = node.get_cell_tile_data(cell)
				else:
					tile_data = node.get_cell_tile_data(layer_index, cell)

				if tile_data == null:
					continue

				if not _tile_has_collision(tile_data, current_tile_set):
					continue

				if not rows.has(cell.y):
					rows[cell.y] = []

				rows[cell.y].append({
					"x": cell.x,
					"flammable": burnable_cells.has(cell)
				})

			# Agrupa Tiles adjacentes horizontalmente.
			for row_y in rows.keys():
				var row: Array = rows[row_y]

				row.sort_custom(func(a, b):
					return a.x < b.x
				)

				var run: Array = []

				for cell_info in row:
					if run.is_empty():
						run.append(cell_info)
						continue

					var previous_x: int = run[-1].x

					if cell_info.x == previous_x + 1:
						run.append(cell_info)
					else:
						_create_platform_segment(
							tilemap,
							Vector2i(run[0].x, row_y),
							Vector2i(run[-1].x, row_y),
							run,
							is_dynamic,
							segments
						)

						run.clear()
						run.append(cell_info)

				if not run.is_empty():
					_create_platform_segment(
						tilemap,
						Vector2i(run[0].x, row_y),
						Vector2i(run[-1].x, row_y),
						run,
						is_dynamic,
						segments
					)

	for child in node.get_children():
		_collect_platform_segments(child, segments)

func _is_flammable_node(node: Node) -> bool:
	if not node is Node2D:
		return false

	# Seu BurnableBlock8P possui BurnComponent como filho direto.
	return node.get_node_or_null("BurnComponent") != null
	

func _collect_burnable_cells(
	root: Node,
	tilemap: Node2D
) -> Dictionary:

	var burnable_cells: Dictionary = {}

	var tile_size := Vector2.ZERO

	if tilemap is TileMapLayer:
		if tilemap.tile_set == null:
			return burnable_cells
		tile_size = tilemap.tile_set.tile_size

	elif tilemap is TileMap:
		if tilemap.tile_set == null:
			return burnable_cells
		tile_size = tilemap.tile_set.tile_size

	if tile_size == Vector2.ZERO:
		return burnable_cells

	_collect_burnable_nodes(root, tilemap, burnable_cells)

	return burnable_cells


func _collect_burnable_nodes(
	node: Node,
	tilemap: Node2D,
	output: Dictionary
) -> void:

	if _is_flammable_node(node):
		var burnable := node as Node2D

		# Converte a posição global do bloco para a
		# coordenada local do TileMap.
		var local_position = tilemap.to_local(
			burnable.global_position
		)

		var cell: Vector2i

		if tilemap is TileMapLayer:
			cell = tilemap.local_to_map(local_position)
		elif tilemap is TileMap:
			cell = tilemap.local_to_map(local_position)
		else:
			return

		output[cell] = true

	for child in node.get_children():
		_collect_burnable_nodes(child, tilemap, output)
	
func _create_platform_segment(
	tilemap: Node2D,
	first_cell: Vector2i,
	last_cell: Vector2i,
	cells: Array,
	is_dynamic: bool,
	output: Array
) -> void:

	var tile_set := _get_tile_set(tilemap)

	if tile_set == null:
		return

	var tile_size: Vector2 = tile_set.tile_size

	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF

	var flammable := false

	for x in range(first_cell.x, last_cell.x + 1):
		var cell := Vector2i(x, first_cell.y)

		var center: Vector2 = tilemap.map_to_local(cell)
		var half_size := tile_size * 0.5

		var local_corners := [
			center + Vector2(-half_size.x, -half_size.y),
			center + Vector2(half_size.x, -half_size.y),
			center + Vector2(-half_size.x, half_size.y),
			center + Vector2(half_size.x, half_size.y)
		]

		for corner in local_corners:
			var world_point: Vector2 = tilemap.to_global(corner)

			min_x = minf(min_x, world_point.x)
			min_y = minf(min_y, world_point.y)
			max_x = maxf(max_x, world_point.x)
			max_y = maxf(max_y, world_point.y)

	for cell_info in cells:
		if cell_info.flammable:
			flammable = true
			break

	output.append({
		"center_x": (min_x + max_x) * 0.5,
		"top_y": min_y,
		"width": max_x - min_x,
		"flammable": 1.0 if flammable else 0.0,
		"dynamic": 1.0 if is_dynamic else 0.0
	})

func _tile_has_collision(tile_data: TileData, tile_set: TileSet) -> bool:
	if tile_set == null:
		return false

	var physics_layers := tile_set.get_physics_layers_count()

	for layer_index in range(physics_layers):
		if tile_data.get_collision_polygons_count(layer_index) > 0:
			return true

	return false

func get_info() -> Dictionary:
	return {
		"level": GameState.current_stage
	}
