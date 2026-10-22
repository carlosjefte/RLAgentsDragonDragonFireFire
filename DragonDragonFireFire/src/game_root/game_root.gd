
class_name GameRoot
extends Node2D

@export var load_shader_on_ready: bool = true

@onready var _scene_container_node: Node = %SceneContainer
@onready var _game_viewport: Viewport = %GameViewport

@onready var _render_rect_shader: ColorRect = %RenderRectShader
@onready var _render_rect_no_shader: ColorRect = %RenderRectNoShader

var _last_render_mode: int = -1


func _ready() -> void:
	Signals.scene_change_triggered.connect(
		_on_scene_change_triggered
	)

	Initialization.initialize()

	# Garante que o CRT tenha um modo válido
	# mesmo sem passar pelo menu.
	if load_shader_on_ready:
		if Settings.render_mode == Settings.RenderMode.CRT_SHADER_OFF:
			Settings.render_mode = Settings.RenderMode.CRT_SHADER_TYPE1
	else:
		Settings.render_mode = Settings.RenderMode.CRT_SHADER_OFF

	# Inicializa a área de renderização.
	_configure_render_layout()

	# Aplica os parâmetros CRT imediatamente.
	_update_shader_settings()

	# Reajusta caso a janela seja redimensionada.
	get_viewport().size_changed.connect(
		_configure_render_layout
	)


func _process(_delta: float) -> void:
	if _last_render_mode != int(Settings.render_mode):
		_update_shader_settings()


func _configure_render_layout() -> void:
	# Os dois ColorRects devem preencher seus pais.
	_render_rect_shader.set_anchors_and_offsets_preset(
		Control.PRESET_FULL_RECT
	)

	_render_rect_no_shader.set_anchors_and_offsets_preset(
		Control.PRESET_FULL_RECT
	)

	# Garante que o viewport continue renderizando.
	if _game_viewport is SubViewport:
		var subviewport := _game_viewport as SubViewport
		subviewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS
		)


func _update_shader_settings() -> void:
	_last_render_mode = int(Settings.render_mode)

	if Settings.render_mode == Settings.RenderMode.CRT_SHADER_OFF:
		_render_rect_shader.visible = false
		_render_rect_no_shader.visible = true
		return

	_render_rect_shader.visible = true
	_render_rect_no_shader.visible = false

	var shader_material := (
		_render_rect_shader.material as ShaderMaterial
	)

	if shader_material == null:
		push_error("Shader CRT não encontrado.")
		return

	match Settings.render_mode:
		Settings.RenderMode.CRT_SHADER_TYPE1:
			shader_material.set_shader_parameter("mask_type", 5)
			shader_material.set_shader_parameter("curve", 0.073)
			shader_material.set_shader_parameter("sharpness", 0.803)

		Settings.RenderMode.CRT_SHADER_TYPE2:
			shader_material.set_shader_parameter("mask_type", 0)
			shader_material.set_shader_parameter("curve", 0.045)
			shader_material.set_shader_parameter("sharpness", 0.814)

		Settings.RenderMode.CRT_SHADER_TYPE3:
			shader_material.set_shader_parameter("mask_type", 3)
			shader_material.set_shader_parameter("curve", 0.091)
			shader_material.set_shader_parameter("sharpness", 0.714)

		_:
			push_error("Invalid render mode: " + str(Settings.render_mode))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey or event is InputEventJoypadButton:
		_game_viewport.push_input(event)


func _on_scene_change_triggered(
	new_scene: SceneDefinitions.Scenes
) -> void:
	if not new_scene in SceneDefinitions.SCENE_DICT:
		push_error("Invalid scene requested: " + str(new_scene))
		return

	if _scene_container_node.get_child_count() != 1:
		push_error("Quantidade inesperada de cenas.")
		return

	var old_scene := _scene_container_node.get_child(0)
	_scene_container_node.remove_child(old_scene)
	old_scene.queue_free()

	var next_scene = SceneDefinitions.SCENE_DICT[new_scene].instantiate()
	_scene_container_node.add_child(next_scene)

	_configure_render_layout()
	_update_shader_settings()
