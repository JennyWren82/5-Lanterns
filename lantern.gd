extends Node2D

@export var flame_color: Color = Color(1, 1, 1, 1)
@export var sway_degrees: float = 2.0
@export var sway_speed: float = 1.2
@export var sway_offset: float = 0.0
@export var bob_pixels: float = 1.5
@export var bob_speed: float = 1.0

@onready var flame: Sprite2D = $Flame
@onready var glow: Sprite2D = get_node_or_null("Glow")

var _t: float = 0.0
var _base_pos: Vector2
var _base_rot: float

func _ready() -> void:
	_base_pos = position
	_base_rot = rotation
	_apply_flame_color()

func _process(delta: float) -> void:
	_t += delta

	var sway := deg_to_rad(sway_degrees) * sin((_t * sway_speed) + sway_offset)
	rotation = _base_rot + sway

	var bob := bob_pixels * sin((_t * bob_speed) + sway_offset)
	position = _base_pos + Vector2(0, bob)

func _apply_flame_color() -> void:
	flame.modulate = flame_color
	if glow:
		glow.modulate = Color(flame_color.r, flame_color.g, flame_color.b, glow.modulate.a)
	
