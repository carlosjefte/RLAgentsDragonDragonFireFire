
class_name GameScene
extends Node2D

enum State {
	INTRO,
	PLAYING,
	TRANSITION_ENTERING,
	TRANSITIONING,
	PLAYER_DEAD,
}

const _PLAYER_SCENE: PackedScene = preload(
	"res://player/player.tscn"
)

const _TRANSITION_ENTERING_TIME: float = 2.75

# Configurações de treinamento
@export var training_reset_delay: float = 0.05
@export var training_restart_on_stage_clear: bool = false
@export_file("res://game_root/game_root.tscn") var training_game_root_path: String = ""

var _training_render_initialized: bool = false


var _is_training: bool = false
var _reset_pending: bool = false
var _transition_entering_time_elapsed: float = 0.0

var _cur_state: State = State.INTRO
var _next_stage: Stage = null

var _current_stage_starting_pos: Vector2 = Vector2.ZERO

@onready var _player_cutscene: PlayerCutscene = $PlayerCutscene
@onready var _transition_rect: TextureRect = $TransitionRect
@onready var _game_over_label: Label = $GameOverLabel
@onready var _time_controller: TimeController = $TimeController
@onready var _enemy_controller: EnemyController = $EnemyController
@onready var _current_stage: Stage = $Stage1


func _init() -> void:
	GameState.next_color = GeometryColorDefinitions.Colors.BLUE



func _ready() -> void:
	_is_training = _detect_training_mode()

	# Configura a renderização CRT antes de iniciar a fase.
	if _is_training:
		_initialize_training_render()

	GameState.reset_game_state()

	Signals.player_died.connect(_on_player_died)
	Signals.time_over.connect(_on_time_over)

	_game_over_label.visible = false
	_game_over_label.visible_ratio = 0.0

	assert(_transition_rect.material)

	_player_cutscene.z_index = 1

	if _is_training:
		_start_training()
	else:
		GameState.cutscene = true
		_transition_rect.material.set_shader_parameter(
			"clear_progress", 0.0
		)
		_play_intro_sequence()
		

func _ensure_player_exists() -> Player:
	# Primeiro tenta recuperar o Player registrado no Stage.
	var player: Player = _current_stage.get_player()

	if is_instance_valid(player):
		return player

	# Se não existe, instancia um novo.
	print("[RL] Player não encontrado. Instanciando...")

	player = _PLAYER_SCENE.instantiate() as Player

	if player == null:
		push_error("[RL] Falha ao instanciar Player.")
		return null

	_current_stage.add_child(player)
	_current_stage.set_player(player)

	# Usa a posição inicial definida para a fase.
	var spawn := _current_stage.get_node_or_null(
		"PlayerSpawn"
	) as Marker2D

	if spawn != null:
		player.global_position = spawn.global_position
	else:
		push_warning("[RL] PlayerSpawn não encontrado.")
		player.global_position = _current_stage_starting_pos

	print("[RL] Player criado: ", player.get_path())

	return player


func _initialize_training_render() -> void:
	if _training_render_initialized:
		return

	# Ativa o mesmo modo CRT usado pelo menu.
	if Settings.render_mode == Settings.RenderMode.CRT_SHADER_OFF:
		Settings.render_mode = Settings.RenderMode.CRT_SHADER_TYPE1

	# Procura o GameRoot existente.
	var game_root := _find_game_root(get_tree().root)

	if game_root != null:
		_training_render_initialized = true
		print("[RL] GameRoot existente. CRT ativo.")
		return

	# A GameScene foi iniciada diretamente.
	# Neste caso, apenas mudar Settings não cria
	# os ColorRects e o SubViewport necessários.
	push_warning(
		"[RL] GameRoot não encontrado. "
		+ "Execute a fase dentro do GameRoot "
		+ "para utilizar o shader CRT."
	)


func _find_game_root(node: Node) -> GameRoot:
	if node is GameRoot:
		return node as GameRoot

	for child in node.get_children():
		var result := _find_game_root(child)
		if result != null:
			return result

	return null

# --- DETECÇÃO DO SYNC ---

func _find_sync(node: Node) -> Node:
	if node.name == "Sync":
		return node

	for child in node.get_children():
		var found := _find_sync(child)
		if found != null:
			return found

	return null
	

func _debug_rl_setup() -> void:
	var sync := _find_sync(get_tree().root)

	print("========== RL DEBUG ==========")

	print("Sync encontrado: ", sync != null)

	if sync != null:
		print("Sync path: ", sync.get_path())
		print("Sync processando: ", sync.is_processing())
		print("Sync física: ", sync.is_physics_processing())

	var player: Player = _current_stage.get_player()

	print("Player encontrado: ", player != null)

	if player != null:
		print("Player path: ", player.get_path())
		print("Player AI ativo: ", player.ai_controlled)

		var controller := player.get_node_or_null(
			"AIController2D"
		)

		print("AIController encontrado: ", controller != null)

		if controller != null:
			print("AIController path: ", controller.get_path())
			print(
				"AIController ativo: ",
				controller.is_physics_processing()
			)

	print("==============================")


func _detect_training_mode() -> bool:
	var sync := _find_sync(get_tree().root)

	if sync == null:
		push_warning("Sync não encontrado. Modo normal.")
		return false

	var mode = sync.get("control_mode")

	if mode == null:
		push_warning("Sync sem control_mode.")
		return false

	var script = sync.get_script()

	if script != null:
		var constants: Dictionary = (
			script.get_script_constant_map()
		)

		for enum_name in ["ControlModes", "ControlMode"]:
			if constants.has(enum_name):
				var modes = constants[enum_name]

				if modes is Dictionary:
					for key in modes:
						if modes[key] == mode:
							var name := str(key).to_upper()
							return name == "TRAINING"

	if mode is String:
		return mode.to_upper() == "TRAINING"

	push_warning(
		"Modo do Sync não identificado: %s" % str(mode)
	)
	return false


# --- INÍCIO DO TREINAMENTO ---



func _start_training() -> void:
	print("[RL] Iniciando treinamento independente.")

	_cur_state = State.PLAYING
	GameState.cutscene = false
	GameState.paused = false

	# Oculta a cutscene sem depender dela.
	if is_instance_valid(_player_cutscene):
		_player_cutscene.visible = false
		_player_cutscene.set_process(false)

	# Remove a transição visual imediatamente.
	if _transition_rect.material is ShaderMaterial:
		var shader := _transition_rect.material as ShaderMaterial
		shader.set_shader_parameter(
			"clear_progress",
			1.0
		)

	_game_over_label.visible = false

	# Utiliza o Player real dentro do Stage.
	var player: Player = _current_stage.get_player()

	if not is_instance_valid(player):
		push_error(
			"[RL] Player não encontrado dentro do Stage1."
		)
		return

	# Guarda a posição inicial.
	_current_stage_starting_pos = player.global_position

	# Ativa o personagem real.
	player.visible = true
	player.set_process(true)
	player.set_physics_process(true)

	# Entrega o controle à IA.
	player.set_ai_controlled(true)

	# Inicializa a fase.
	_current_stage.do_setup()
	_time_controller.set_running(true)

	print("[RL] Player independente ativado.")
	print("[RL] Player: ", player.get_path())

# --- LOOP PRINCIPAL ---

func _process(delta: float) -> void:
	match _cur_state:
		State.INTRO:
			pass

		State.PLAYING:
			if not _is_training:
				if Input.is_action_just_pressed("menu"):
					if not GameState.is_in_cutscene():
						GameState.paused = not GameState.paused

			if _enemy_controller.get_enemy_count() == 0:
				if _is_training and training_restart_on_stage_clear:
					_complete_training_episode()
					return

				Signals.transition_to_next_stage_started.emit()

				_transition_entering_time_elapsed = 0.0
				_cur_state = State.TRANSITION_ENTERING

		State.TRANSITION_ENTERING:
			_time_controller.set_running(false)

			_transition_entering_time_elapsed += delta

			var transition_time := (
				0.0 if _is_training
				else _TRANSITION_ENTERING_TIME
			)

			if _transition_entering_time_elapsed >= transition_time:
				_current_stage.grant_completion_bonus()
				_cur_state = State.TRANSITIONING

				if _is_training:
					_transition_stages_training()
				else:
					_transition_stages()

		State.TRANSITIONING:
			pass

		State.PLAYER_DEAD:
			pass


# --- CUTSCENE ORIGINAL ---

func _play_intro_sequence() -> void:
	var player: Player = _current_stage.get_player()

	_current_stage_starting_pos = player.global_position
	player.visible = false

	_time_controller.set_running(false)
	_jumpstart_stage_music()

	var intro_tween: Tween = get_tree().create_tween()

	intro_tween.tween_callback(
		_player_cutscene.play_body.bind("walk")
	)
	intro_tween.tween_callback(
		_player_cutscene.play_head.bind("normal")
	)
	intro_tween.tween_property(
		_player_cutscene,
		"global_position",
		player.global_position,
		0.7
	)
	intro_tween.tween_callback(
		_player_cutscene.play_body.bind("idle")
	)
	intro_tween.tween_callback(
		_player_cutscene.play_head.bind("normal")
	)
	intro_tween.tween_interval(0.1)
	intro_tween.tween_callback(
		_player_cutscene.play_body.bind("cheer")
	)
	intro_tween.tween_callback(
		_player_cutscene.play_head.bind("invisible")
	)
	intro_tween.tween_property(
		_transition_rect,
		"material:shader_parameter/clear_progress",
		1.0,
		0.75
	)
	intro_tween.tween_callback(
		_player_cutscene.play_body.bind("idle")
	)
	intro_tween.tween_callback(
		_player_cutscene.play_head.bind("normal")
	)
	intro_tween.tween_interval(0.3)
	intro_tween.tween_callback(
		_callback_intro_finished
	)


func _callback_intro_finished() -> void:
	var player: Player = _current_stage.get_player()
	player.visible = true

	_player_cutscene.visible = false
	_player_cutscene.z_index = 0

	_cur_state = State.PLAYING
	GameState.cutscene = false

	_time_controller.set_running(true)
	_current_stage.do_setup()


func _jumpstart_stage_music() -> void:
	await get_tree().create_timer(0.28).timeout
	MusicPlayer.play_track(MusicPlayer.TRACK_STAGE)


# --- TRANSIÇÃO NORMAL ENTRE FASES ---

func _transition_stages() -> void:
	_cur_state = State.TRANSITIONING
	GameState.cutscene = true

	_prepare_next_stage()

	var player: Player = _current_stage.get_player()

	_player_cutscene.global_position = player.global_position
	_player_cutscene.play_body("spin")
	_player_cutscene.play_head("invisible")
	_player_cutscene.visible = true

	player.visible = false

	var next_stage_player: Player = _next_stage.get_player()
	next_stage_player.visible = false

	var player_target_pos: Vector2 = (
		next_stage_player.global_position
		+ Vector2(0, Constants.ARENA_HEIGHT)
	)

	GameState.bonus_seconds += (
		Constants.BONUS_SECONDS_PER_COMPLETED_STAGE
	)

	SoundPool.play_sound(SoundPool.SOUND_STAGE_COMPLETED)

	var tween: Tween = get_tree().create_tween()

	tween.set_process_mode(
		Tween.TweenProcessMode.TWEEN_PROCESS_PHYSICS
	)

	tween.set_parallel(true)

	tween.tween_property(
		_next_stage,
		"global_position",
		Vector2.ZERO,
		2.0
	)
	tween.tween_property(
		_current_stage,
		"global_position",
		Vector2(0, Constants.ARENA_HEIGHT),
		2.0
	)
	tween.tween_property(
		_player_cutscene,
		"global_position",
		player_target_pos,
		2.0
	)

	tween.set_parallel(false)
	tween.tween_callback(_callback_transition_finished)


func _prepare_next_stage() -> void:
	GameState.current_stage += 1

	var num_colors: int = (
		GeometryColorDefinitions.Colors.size()
	)

	GameState.next_color = (
		(int(GameState.next_color) + 1) % num_colors
	) as GeometryColorDefinitions.Colors

	var num_stages: int = StageDefinitions.STAGES_DICT.size()

	var next_stage_number: int = (
		(GameState.current_stage - 1) % num_stages + 1
	)

	_next_stage = (
		StageDefinitions.STAGES_DICT[next_stage_number]
		.instantiate()
	)

	add_child(_next_stage)
	move_child(_next_stage, 0)

	_next_stage.global_position = Vector2(
		0,
		-Constants.ARENA_HEIGHT
	)


func _callback_transition_finished() -> void:
	_current_stage.queue_free()

	_current_stage = _next_stage
	_next_stage = null

	var player: Player = _current_stage.get_player()

	_current_stage_starting_pos = player.global_position

	player.visible = true
	_player_cutscene.visible = false

	_cur_state = State.PLAYING
	GameState.cutscene = false

	_time_controller.set_running(true)
	_current_stage.do_setup()


# --- TRANSIÇÃO RÁPIDA PARA TREINAMENTO ---

func _transition_stages_training() -> void:
	_prepare_next_stage()

	_current_stage.queue_free()

	_current_stage = _next_stage
	_next_stage = null

	_current_stage.global_position = Vector2.ZERO

	var player: Player = _current_stage.get_player()

	_current_stage_starting_pos = player.global_position

	player.visible = true
	player.set_ai_controlled(true)

	GameState.bonus_seconds += (
		Constants.BONUS_SECONDS_PER_COMPLETED_STAGE
	)

	_player_cutscene.visible = false

	_cur_state = State.PLAYING
	GameState.cutscene = false

	_current_stage.do_setup()
	_time_controller.set_running(true)


# --- MORTE DO PLAYER ---

func _on_player_died() -> void:
	if _cur_state == State.PLAYER_DEAD:
		return

	if _is_training:
		_request_training_reset()
		return

	_cur_state = State.PLAYER_DEAD

	SoundPool.play_sound(SoundPool.SOUND_PLAYER_HURT)

	GameState.cutscene = true
	_time_controller.set_running(false)

	var player: Player = _current_stage.get_player()

	_player_cutscene.global_position = player.global_position
	_player_cutscene.play_body("hurt")
	_player_cutscene.play_head("invisible")
	_player_cutscene.visible = true

	player.visible = false

	GameState.lives -= 1

	if GameState.lives <= 0:
		_game_over_label.visible = true
		_game_over_label.text = "GAME OVER!"
		_do_game_over_transition()
	else:
		_do_death_transition()


# --- TEMPO ESGOTADO ---

func _on_time_over() -> void:
	if _cur_state == State.PLAYER_DEAD:
		return

	if _is_training:
		var player: Player = _current_stage.get_player()
		player.finish_rl_episode(false)
		_request_training_reset()
		return

	_cur_state = State.PLAYER_DEAD

	SoundPool.play_sound(SoundPool.SOUND_PLAYER_HURT)

	GameState.cutscene = true
	_time_controller.set_running(false)

	var player: Player = _current_stage.get_player()

	_player_cutscene.global_position = player.global_position
	_player_cutscene.play_body("hurt")
	_player_cutscene.play_head("invisible")
	_player_cutscene.visible = true

	player.visible = false

	_game_over_label.visible = true
	_game_over_label.text = "TIME OVER!"

	_do_game_over_transition()


# --- RESET DO TREINAMENTO ---

func _request_training_reset() -> void:
	if _reset_pending:
		return

	_reset_pending = true
	_cur_state = State.PLAYER_DEAD

	_time_controller.set_running(false)

	_reset_training_after_delay()


func _reset_training_after_delay() -> void:
	await get_tree().create_timer(
		training_reset_delay,
		true,
		true
	).timeout

	if not is_inside_tree():
		return

	_reset_training_player()



func _reset_training_player() -> void:
	var player: Player = _current_stage.get_player()

	if not is_instance_valid(player):
		push_error("[RL] Player perdido durante o reset.")
		return

	# Preserva o mesmo Player e AIController2D.
	player.reset_for_training(
		_current_stage_starting_pos
	)

	GameState.cutscene = false
	GameState.paused = false

	_game_over_label.visible = false

	_cur_state = State.PLAYING
	_reset_pending = false

	_time_controller.set_running(true)

	print("[RL] Player reiniciado sem recriar agente.")


func _complete_training_episode() -> void:
	var player: Player = _current_stage.get_player()

	player.finish_rl_episode(true)
	_request_training_reset()


# --- TRANSIÇÃO DE MORTE NORMAL ---

func _do_death_transition() -> void:
	var tween: Tween = get_tree().create_tween()

	tween.tween_interval(0.75)
	tween.tween_callback(
		SoundPool.play_sound.bind(
			SoundPool.SOUND_LIFE_LOST
		)
	)
	tween.tween_callback(
		_player_cutscene.play_body.bind("spin_hurt")
	)
	tween.tween_callback(
		_player_cutscene.play_head.bind("invisible")
	)
	tween.tween_property(
		_player_cutscene,
		"global_position",
		_current_stage_starting_pos,
		1.5
	)
	tween.tween_callback(
		_player_cutscene.play_body.bind("idle")
	)
	tween.tween_callback(
		_player_cutscene.play_head.bind("normal")
	)
	tween.tween_interval(0.5)
	tween.tween_callback(
		_callback_death_transition_finished
	)


func _callback_death_transition_finished() -> void:
	var player: Player = _current_stage.get_player()
	player.queue_free()

	var new_player: Player = _PLAYER_SCENE.instantiate()

	_current_stage.add_child(new_player)
	_current_stage.set_player(new_player)

	new_player.grant_invincibility()

	new_player.global_position = _current_stage_starting_pos
	new_player.visible = true

	_player_cutscene.visible = false

	_cur_state = State.PLAYING
	GameState.cutscene = false

	_time_controller.set_running(true)


# --- GAME OVER NORMAL ---

func _do_game_over_transition() -> void:
	MusicPlayer.stop_track(0.4)

	var tween: Tween = get_tree().create_tween()

	tween.set_parallel(true)

	tween.tween_property(
		_game_over_label,
		"visible_ratio",
		1.0,
		0.2
	)
	tween.tween_interval(0.9)

	tween.set_parallel(false)

	tween.tween_callback(
		SoundPool.play_sound.bind(
			SoundPool.SOUND_GAME_OVER_JINGLE
		)
	)
	tween.tween_interval(0.1)
	tween.tween_callback(
		_player_cutscene.play_body.bind("spin_hurt")
	)
	tween.tween_callback(
		_player_cutscene.play_head.bind("invisible")
	)
	tween.tween_interval(0.8)
	tween.tween_callback(_player_cutscene.pause)

	tween.tween_property(
		_player_cutscene,
		"dissolve_shader_time",
		0.6,
		0.6
	)
	tween.tween_property(
		_player_cutscene,
		"dissolve_shader_time",
		0.0,
		0.001
	)
	tween.tween_callback(
		_player_cutscene.play_body.bind("explode")
	)
	tween.tween_callback(
		_player_cutscene.play_head.bind("invisible")
	)
	tween.tween_interval(0.8)
	tween.tween_property(
		_transition_rect,
		"material:shader_parameter/clear_progress",
		0.0,
		0.75
	)
	tween.tween_callback(
		_callback_game_over_transition_finished
	)


func _callback_game_over_transition_finished() -> void:
	Signals.scene_change_triggered.emit(
		SceneDefinitions.Scenes.END_SCREEN
	)
