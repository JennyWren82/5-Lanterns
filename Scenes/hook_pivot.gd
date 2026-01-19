extends Node2D

@export var swing_degrees: float = 6.0
@export var swing_speed: float = 1.2
@export var phase_offset: float = 0.0

var t: float = 0.0

func _process(delta: float) -> void:
	t += delta
	var angle := deg_to_rad(swing_degrees) * sin((t + phase_offset) * swing_speed)
	rotation = angle
