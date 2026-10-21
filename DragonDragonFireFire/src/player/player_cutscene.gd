class_name PlayerCutscene
extends Node2D

@onready var _sprite_head : AnimatedSprite2D = $AnimatedSprite2DHead
@onready var _sprite_body : AnimatedSprite2D = $AnimatedSprite2DBody

# Cena do player real que o agente vai controlar (caso precise instanciar)
const _PLAYER_SCENE : PackedScene = preload("res://player/player.tscn")

var dissolve_shader_time : float = 0.0


func _ready() -> void:
	# Verifica se estamos em modo de treino
	if _is_training_mode():
		_skip_cutscene_and_spawn_player()


func _process(_delta : float) -> void:
	var shader_material : ShaderMaterial = get("material") as ShaderMaterial
	assert(shader_material)
	shader_material.set_shader_parameter("current_time", dissolve_shader_time)


func play_head(animation : String) -> void:
	_sprite_head.play(animation)


func play_body(animation : String) -> void:
	_sprite_body.play("idle")


func pause() -> void:
	_sprite_head.pause()
	_sprite_body.pause()


# --- MÉTODOS DE SUPORTE AO TREINAMENTO ---

func _is_training_mode() -> bool:
	# Exemplo 1: Checa se existe uma flag no GameState ou Debug
	if Engine.has_meta("is_training") or (typeof(GameState) != TYPE_NIL and GameState.get("is_training")):
		return true
		
	# Exemplo 2: Checa os argumentos de linha de comando passados pelo python (godot_rl_agents)
	for arg in OS.get_cmdline_args():
		if "--inference" in arg or "--train" in arg or "timesteps" in arg:
			return true
			
	return false


func _skip_cutscene_and_spawn_player() -> void:
	var parent = get_parent()
	if not parent:
		return

	# Tenta encontrar um Player que já exista na árvore de nós (ex: no pai ou nos irmãos)
	var existing_player = parent.get_node_or_null("Player") # Ajuste o caminho/nome do nó se necessário
	if not existing_player:
		# Tenta procurar por grupo caso o nó tenha outro nome
		var players_in_tree = get_tree().get_nodes_in_group("player") # Ou verifique pelo tipo
		if players_in_tree.size() > 0:
			existing_player = players_in_tree[0]

	if existing_player and existing_player is Node2D:
		# Se já existe um player na cena, apenas posiciona ele no lugar da cutscene e o ativa
		existing_player.global_position = global_position
		existing_player.visible = true
		if "set_process" in existing_player:
			existing_player.set_process(true)
			existing_player.set_physics_process(true)
		queue_free()
	else:
		# Se não existe nenhum player na cena, instancia o novo do arquivo
		if _PLAYER_SCENE:
			var player_instance = _PLAYER_SCENE.instantiate()
			player_instance.global_position = global_position
			parent.add_child(player_instance)
			queue_free()
