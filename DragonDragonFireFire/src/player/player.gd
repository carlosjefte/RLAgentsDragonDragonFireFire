
class_name Player
extends CharacterBody2D

enum State {
	UNDEFINED,
	MOVE,
	DEAD,
}

# ==================================================
# RECURSOS
# ==================================================

const _FIRE_BALL_SCENE: PackedScene = preload(
	"res://projectiles/fire_ball.tscn"
)

const _FIRE_BALL_OFFSET_LEFT: Vector2 = Vector2(-8.0, -8.0)
const _FIRE_BALL_OFFSET_RIGHT: Vector2 = Vector2(8.0, -8.0)
const _FIRE_BALL_OFFSET_UP_LEFT: Vector2 = Vector2(-3.0, -16.0)
const _FIRE_BALL_OFFSET_UP_RIGHT: Vector2 = Vector2(3.0, -16.0)

const _FIRE_BALL_CADENCE: float = 1.0 / 5.5

# ==================================================
# MOVIMENTAÇÃO
# ==================================================

const _SPEED: float = 80.0
const _JUMP_VELOCITY: float = -166.0
const _MAX_FALL_SPEED: float = 130.0

const _JUMP_BUFFER_TIME: float = 0.1
const _FIRE_BALL_BUFFER_TIME: float = 0.1
const _COYOTE_TIME: float = 0.075

# ==================================================
# INVENCIBILIDADE E ANIMAÇÕES
# ==================================================

const _INVINCIBILITY_TIME: float = 2.0
const _INVINCIBILITY_FLASH_SPEED: float = 20.0
const _FIRE_SPIT_ANIMATION_TIME: float = 0.15

# ==================================================
# RECOMPENSAS RL
# ==================================================

const REWARD_SCORE_FACTOR: float = 0.01
const REWARD_DEATH: float = -2.0
const REWARD_FINISH: float = 5.0

# ==================================================
# ESTADO DO PLAYER
# ==================================================

var _cur_state: State = State.MOVE
var _cur_dir: Types.Direction = Types.Direction.RIGHT

var _touched_by_enemy: bool = false

var _has_invincibility_frames: bool = false
var _invincibility_frames: float = 0.0

var _jump_buffer_timer: float = _JUMP_BUFFER_TIME + 0.01
var _fire_ball_buffer_timer: float = _FIRE_BALL_BUFFER_TIME + 0.01

var _time_since_last_ground_contact: float = 0.0
var _time_since_last_fire_spit: float = (
	_FIRE_SPIT_ANIMATION_TIME + 0.01
)

var _looking_up: bool = false

# ==================================================
# CONTROLE DO AGENTE
# ==================================================

var ai_controlled: bool = false
var _episode_finished: bool = false

var _action_move: float = 0.0
var _action_jump: bool = false
var _action_fire: bool = false
var _action_look_up: bool = false
var _action_down: bool = false

# ==================================================
# REFERÊNCIAS AOS NÓS
# ==================================================

@onready var _visuals: Node2D = $Visuals

@onready var _sprite_head: AnimatedSprite2D = (
	$Visuals/AnimatedSprite2DHead
)

@onready var _sprite_body: AnimatedSprite2D = (
	$Visuals/AnimatedSprite2DBody
)

@onready var _head_check_component: HeadCheckComponent = (
	$HeadCheckComponent
)

@onready var _stuck_inside_geometry_component: StuckInsideGeometryComponent = (
	$StuckInsideGeometryComponent
)

@onready var _one_way_platform_detector: ShapeCast2D = (
	%OneWayPlatformDetector
)

@onready var ai_controller: DragonAgentController = (
	get_node_or_null("AIController2D") as DragonAgentController
)

# ==================================================
# INICIALIZAÇÃO
# ==================================================

func _ready() -> void:
	_sprite_head.play("normal")
	_sprite_body.play("idle")

	if ai_controller == null:
		push_warning(
			"[RL] AIController2D não encontrado no Player."
		)
	else:
		print(
			"[RL] AIController encontrado: ",
			ai_controller.get_path()
		)


# ==================================================
# CONTROLE HUMANO / IA
# ==================================================

func set_ai_controlled(enabled: bool) -> void:
	ai_controlled = enabled
	clear_ai_actions()

	print("[RL] Controle por IA: ", ai_controlled)


func set_ai_actions(
	move: float,
	jump: bool,
	fire: bool,
	look_up: bool,
	down: bool
) -> void:
	if not ai_controlled:
		return

	if _episode_finished or _cur_state != State.MOVE:
		clear_ai_actions()
		return

	_action_move = clampf(move, -1.0, 1.0)
	_action_jump = jump
	_action_fire = fire
	_action_look_up = look_up
	_action_down = down


func clear_ai_actions() -> void:
	_action_move = 0.0
	_action_jump = false
	_action_fire = false
	_action_look_up = false
	_action_down = false


# ==================================================
# RECOMPENSAS
# ==================================================

func add_rl_reward(amount: float) -> void:
	if not ai_controlled or _episode_finished:
		return

	if is_instance_valid(ai_controller):
		ai_controller.reward += amount


func finish_rl_episode(success: bool) -> void:
	if _episode_finished:
		return

	if ai_controlled and is_instance_valid(ai_controller):
		ai_controller.reward += (
			REWARD_FINISH if success else REWARD_DEATH
		)

		ai_controller.done = true

	_episode_finished = true
	clear_ai_actions()


# ==================================================
# BUFFER DE AÇÕES
# ==================================================

func _handle_buffered_inputs(delta: float) -> void:
	_jump_buffer_timer += delta
	_fire_ball_buffer_timer += delta

	var jump_pressed: bool = false
	var fire_pressed: bool = false

	if ai_controlled:
		jump_pressed = _action_jump
		fire_pressed = _action_fire
	else:
		jump_pressed = Input.is_action_just_pressed("jump")
		fire_pressed = Input.is_action_just_pressed("fire")

	if jump_pressed:
		_jump_buffer_timer = 0.0

	if fire_pressed:
		_fire_ball_buffer_timer = 0.0


# ==================================================
# LOOP DE FÍSICA
# ==================================================

func _physics_process(delta: float) -> void:
	if GameState.is_halted():
		_update_animation()
		return

	if _cur_state == State.DEAD:
		_update_animation()
		return

	if _episode_finished:
		return

	_handle_buffered_inputs(delta)

	if _has_invincibility_frames:
		_invincibility_frames -= delta

		if _invincibility_frames <= 0.0:
			_has_invincibility_frames = false

	_time_since_last_fire_spit += delta

	_update_invincibility_visuals()

	match _cur_state:
		State.MOVE:
			_physics_process_move(delta)

		State.DEAD:
			_physics_process_dead(delta)

		_:
			pass

	if _cur_state == State.DEAD:
		_update_animation()
		return

	_update_animation()

	Teleport.handle_teleport(self)

	if _head_check_component.is_hit():
		_handle_death()
		return

	if _stuck_inside_geometry_component.has_been_stuck():
		_handle_death()
		return


# ==================================================
# MOVIMENTAÇÃO
# ==================================================

func _physics_process_move(delta: float) -> void:
	if _touched_by_enemy and not Debug.player_invincible:
		_handle_death()
		return

	if not is_on_floor():
		velocity += get_gravity() * delta

	if is_on_floor():
		_time_since_last_ground_contact = 0.0
	else:
		_time_since_last_ground_contact += delta

	var down_pressed: bool = (
		_action_down
		if ai_controlled
		else Input.is_action_pressed("down")
	)

	_one_way_platform_detector.force_shapecast_update()

	var jump_buffered: bool = (
		_jump_buffer_timer <= _JUMP_BUFFER_TIME
	)

	if (
		jump_buffered
		and _time_since_last_ground_contact <= _COYOTE_TIME
	):
		_jump_buffer_timer = _JUMP_BUFFER_TIME + 0.01

		if (
			down_pressed
			and _one_way_platform_detector.is_colliding()
		):
			SoundPool.play_sound(
				SoundPool.SOUND_PLAYER_DROP_PLATFORM
			)
			position.y += 2.0
		else:
			velocity.y = _JUMP_VELOCITY

			_time_since_last_ground_contact = (
				_COYOTE_TIME + 0.01
			)

			SoundPool.play_sound(
				SoundPool.SOUND_PLAYER_JUMP
			)

	var fire_buffered: bool = (
		_fire_ball_buffer_timer <= _FIRE_BALL_BUFFER_TIME
	)

	if (
		fire_buffered
		and _time_since_last_fire_spit >= _FIRE_BALL_CADENCE
	):
		_fire_ball_buffer_timer = (
			_FIRE_BALL_BUFFER_TIME + 0.01
		)

		_shoot_fire_ball()

	_looking_up = (
		_action_look_up
		if ai_controlled
		else Input.is_action_pressed("up")
	)

	_handle_direction_actions()

	if velocity.y > _MAX_FALL_SPEED:
		velocity.y = _MAX_FALL_SPEED

	move_and_slide()


func _physics_process_dead(_delta: float) -> void:
	pass


func _handle_direction_actions() -> void:
	var direction: float = 0.0

	if ai_controlled:
		direction = _action_move
	else:
		direction = Input.get_axis("left", "right")

	direction = clampf(direction, -1.0, 1.0)

	if absf(direction) > 0.01:
		velocity.x = direction * _SPEED

		if direction < 0.0:
			_cur_dir = Types.Direction.LEFT
		else:
			_cur_dir = Types.Direction.RIGHT
	else:
		velocity.x = move_toward(
			velocity.x,
			0.0,
			_SPEED
		)


# ==================================================
# PROJÉTEIS
# ==================================================

func _shoot_fire_ball() -> void:
	var fire_ball: FireBall = _FIRE_BALL_SCENE.instantiate()

	get_parent().add_child(fire_ball)

	if ai_controlled:
		fire_ball.add_to_group("rl_projectiles")

	if _looking_up:
		fire_ball.set_up()

		if _cur_dir == Types.Direction.LEFT:
			fire_ball.global_position = (
				global_position + _FIRE_BALL_OFFSET_UP_LEFT
			)
		else:
			fire_ball.global_position = (
				global_position + _FIRE_BALL_OFFSET_UP_RIGHT
			)
	else:
		if _cur_dir == Types.Direction.LEFT:
			fire_ball.set_left()
			fire_ball.global_position = (
				global_position + _FIRE_BALL_OFFSET_LEFT
			)
		else:
			fire_ball.set_right()
			fire_ball.global_position = (
				global_position + _FIRE_BALL_OFFSET_RIGHT
			)

	_time_since_last_fire_spit = 0.0

	SoundPool.play_sound(SoundPool.SOUND_FIRE_SHOT)


# ==================================================
# INVENCIBILIDADE
# ==================================================

func grant_invincibility() -> void:
	_has_invincibility_frames = true
	_invincibility_frames = _INVINCIBILITY_TIME


func _update_invincibility_visuals() -> void:
	if _has_invincibility_frames:
		var flash: bool = (
			int(
				_invincibility_frames
				* _INVINCIBILITY_FLASH_SPEED
			) % 2 == 0
		)

		_visuals.modulate.a = (
			1.0 if flash else 0.5
		)
	else:
		_visuals.modulate.a = 1.0


# ==================================================
# MORTE
# ==================================================

func _handle_death() -> void:
	if _cur_state == State.DEAD:
		return

	_cur_state = State.DEAD
	velocity = Vector2.ZERO

	finish_rl_episode(false)

	Signals.player_died.emit()


func _on_enemy_detection_hitbox_body_entered(
	_body: Node2D
) -> void:
	if _has_invincibility_frames:
		return

	if _cur_state == State.DEAD:
		return

	_touched_by_enemy = true


# ==================================================
# ANIMAÇÕES
# ==================================================

func _update_animation() -> void:
	if GameState.is_halted():
		_sprite_head.pause()
		_sprite_body.pause()
		return

	_visuals.scale.x = (
		1.0
		if _cur_dir == Types.Direction.RIGHT
		else -1.0
	)

	match _cur_state:
		State.UNDEFINED:
			assert(false)
			_sprite_body.play("idle")

		State.MOVE:
			if not is_on_floor():
				if velocity.y < 0.0:
					_sprite_body.play("jump_up")
				else:
					_sprite_body.play("jump_down")
			elif absf(velocity.x) > 0.1:
				_sprite_body.play("walk")
			else:
				_sprite_body.play("idle")

		State.DEAD:
			_sprite_body.play("hurt")

	if _cur_state == State.MOVE:
		if (
			_time_since_last_fire_spit
			< _FIRE_SPIT_ANIMATION_TIME
		):
			if _looking_up:
				if not is_on_floor() and velocity.y < 0.0:
					_sprite_head.play("jump_fire_up")
				else:
					_sprite_head.play("fire_up")
			else:
				if not is_on_floor() and velocity.y < 0.0:
					_sprite_head.play("jump_fire")
				else:
					_sprite_head.play("fire")
		else:
			if _looking_up:
				if not is_on_floor() and velocity.y < 0.0:
					_sprite_head.play("jump_up")
				else:
					_sprite_head.play("normal_up")
			else:
				if not is_on_floor() and velocity.y < 0.0:
					_sprite_head.play("jump")
				else:
					_sprite_head.play("normal")
	else:
		_sprite_head.play("invisible")


# ==================================================
# RESET DO TREINAMENTO
# ==================================================

func reset_for_training(spawn_position: Vector2) -> void:
	# Restaura o estado principal.
	_cur_state = State.MOVE
	_cur_dir = Types.Direction.RIGHT

	global_position = spawn_position
	velocity = Vector2.ZERO

	# Limpa colisões e dano.
	_touched_by_enemy = false

	_has_invincibility_frames = false
	_invincibility_frames = 0.0

	# Reinicia os buffers.
	_jump_buffer_timer = _JUMP_BUFFER_TIME + 0.01
	_fire_ball_buffer_timer = _FIRE_BALL_BUFFER_TIME + 0.01

	_time_since_last_ground_contact = 0.0
	_time_since_last_fire_spit = (
		_FIRE_SPIT_ANIMATION_TIME + 0.01
	)

	_looking_up = false

	# Reinicia o estado do episódio.
	_episode_finished = false

	clear_ai_actions()

	# Ativa novamente o Player.
	visible = true
	set_process(true)
	set_physics_process(true)

	set_ai_controlled(true)

	# Restaura as animações.
	_sprite_head.play("normal")
	_sprite_body.play("idle")

	_visuals.modulate.a = 1.0

	# Evita interpolação visual da posição anterior.
	reset_physics_interpolation()

	print("[RL] Player restaurado para novo episódio.")
