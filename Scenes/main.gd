extends Node2D

const JOURNALS_DIR: String = "user://journals/"
var journal_filename: String = "journal.txt"
var journal_path: String = JOURNALS_DIR + "journal.txt"
const PROMPTS_DIR: String = "res://data/prompts/"
const WINDOW_LANTERNS: int = 5
const UNLIT_ALPHA: float = 0.0
const LIT_ALPHA: float = 0.80
const JOURNAL_PATH: String = "user://journal.txt"

# --- Node paths (match your current tree) ---
const PATH_BUTTONS_BOX := "UI/Panel/VBox/Buttons"
const PATH_PROMPT_TEXT := "UI/Panel/VBox/PromptScroll/PromptVBox/PromptText"
const PATH_RESPONSE_EDIT := "UI/Panel/VBox/ResponseEdit"
const PATH_SAVE_BUTTON := "UI/Panel/VBox/ResponseButtons/SaveButton"
const PATH_SKIP_BUTTON := "UI/Panel/VBox/ResponseButtons/SkipButton"
const PATH_WINDOW_FRAME := "WindowFrame"
const PATH_CANVAS_MODULATE := "CanvasModulate"

# --- Node refs (wired in _ready) ---
var buttons_box: HBoxContainer
var prompt_text: RichTextLabel
var response_edit: TextEdit
var save_button: Button
var skip_button: Button
var window_frame: Node
var canvas_modulate: CanvasModulate
@onready var open_folder_button: Button = $UI/Panel/VBox/ResponseButtons/OpenJournalFolderButton

# Brightness (backing field to avoid setter recursion)
var _global_brightness: float = 1.12
@export var global_brightness: float = 1.12:
	set(value):
		_global_brightness = value
		if is_inside_tree():
			_apply_global_brightness()
	get:
		return _global_brightness

# --- Runtime state ---
var fragments: Array[Polygon2D] = []
var categories: Array[Dictionary] = []         # { key, label, flame_hex, prompts:Array[String] }
var used_indices: Dictionary = {}              # key:String -> Array[int]
var lantern_count: int = 0
var category_buttons: Array[Button] = []

var current_prompt: String = ""
var current_category_label: String = ""
var current_category_key: String = ""

var window_complete_pending: bool = false
var completion_tween: Tween = null


func _ready() -> void:
	randomize()

	if not _wire_nodes():
		return

	_apply_global_brightness()

	_collect_fragments()
	_set_all_fragments_unlit()

	_load_all_categories()
	_build_category_buttons()
	_setup_ui()
	_ensure_journals_dir()

# -------------------------
# Node wiring (robust)
# -------------------------
func _wire_nodes() -> bool:
	buttons_box = get_node_or_null(PATH_BUTTONS_BOX) as HBoxContainer
	prompt_text = get_node_or_null(PATH_PROMPT_TEXT) as RichTextLabel
	response_edit = get_node_or_null(PATH_RESPONSE_EDIT) as TextEdit
	save_button = get_node_or_null(PATH_SAVE_BUTTON) as Button
	skip_button = get_node_or_null(PATH_SKIP_BUTTON) as Button
	window_frame = get_node_or_null(PATH_WINDOW_FRAME)
	canvas_modulate = get_node_or_null(PATH_CANVAS_MODULATE) as CanvasModulate

	# Fallback: find by name if paths changed
	if buttons_box == null:
		buttons_box = _find_first_by_name("Buttons") as HBoxContainer
	if prompt_text == null:
		prompt_text = _find_first_by_name("PromptText") as RichTextLabel
	if response_edit == null:
		response_edit = _find_first_by_name("ResponseEdit") as TextEdit
	if save_button == null:
		save_button = _find_first_by_name("SaveButton") as Button
	if skip_button == null:
		skip_button = _find_first_by_name("SkipButton") as Button
	if window_frame == null:
		window_frame = _find_first_by_name("WindowFrame")
	if canvas_modulate == null:
		canvas_modulate = _find_first_by_name("CanvasModulate") as CanvasModulate

	var ok := true
	ok = ok and _require_node(buttons_box, "Buttons (HBoxContainer)", PATH_BUTTONS_BOX)
	ok = ok and _require_node(prompt_text, "PromptText (RichTextLabel)", PATH_PROMPT_TEXT)
	ok = ok and _require_node(response_edit, "ResponseEdit (TextEdit)", PATH_RESPONSE_EDIT)
	ok = ok and _require_node(save_button, "SaveButton (Button)", PATH_SAVE_BUTTON)
	ok = ok and _require_node(skip_button, "SkipButton (Button)", PATH_SKIP_BUTTON)
	ok = ok and _require_node(window_frame, "WindowFrame (Node)", PATH_WINDOW_FRAME)
	ok = ok and _require_node(canvas_modulate, "CanvasModulate (CanvasModulate)", PATH_CANVAS_MODULATE)

	return ok


func _require_node(n: Node, label: String, expected_path: String) -> bool:
	if n != null:
		return true
	push_error("Missing node: %s. Expected path: %s (or node exists but wrong type)." % [label, expected_path])
	return false


func _find_first_by_name(target_name: String) -> Node:
	return _dfs_find(self, target_name)


func _dfs_find(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for c in root.get_children():
		var found := _dfs_find(c, target_name)
		if found != null:
			return found
	return null


# -------------------------
# Brightness
# -------------------------
func _apply_global_brightness() -> void:
	if canvas_modulate == null:
		return
	var b := _global_brightness
	canvas_modulate.color = Color(b, b, b, 1.0)


# -------------------------
# UI setup
# -------------------------
func _setup_ui() -> void:
	prompt_text.add_theme_color_override("default_color", Color(0.95, 0.95, 0.95))
	prompt_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.65))
	prompt_text.add_theme_constant_override("outline_size", 2)

	prompt_text.text = "Choose a Lantern"

	response_edit.text = ""
	response_edit.placeholder_text = "Optional: write what you noticed..."
	response_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	response_edit.editable = true
	response_edit.focus_mode = Control.FOCUS_ALL
	response_edit.mouse_filter = Control.MOUSE_FILTER_STOP

	# Safe connect
	if not save_button.pressed.is_connected(_on_save_pressed):
		save_button.pressed.connect(_on_save_pressed)
	if not skip_button.pressed.is_connected(_on_skip_pressed):
		skip_button.pressed.connect(_on_skip_pressed)

	_set_response_controls_enabled(false)
	skip_button.text = "Skip"
	
	# Open Journal Folder
	if open_folder_button != null and not open_folder_button.pressed.is_connected(open_journal_folder):
		open_folder_button.pressed.connect(open_journal_folder)



# -------------------------
# Completion glow (fixed)
# -------------------------
# bind() appends args, so signature must be (a, frag)
func _set_fragment_alpha(a: float, frag: Polygon2D) -> void:
	var cc: Color = frag.color
	cc.a = a
	frag.color = cc


func _start_completion_glow() -> void:
	_stop_completion_glow()

	if fragments.is_empty():
		return

	completion_tween = create_tween()

	# Build tween first, then loop (avoids "infinite loop detected" on empty tweens)
	for frag: Polygon2D in fragments:
		var a0: float = frag.color.a
		var a1: float = clamp(a0 + 0.15, 0.0, 1.0)

		var t := completion_tween.parallel()
		t.tween_method(Callable(self, "_set_fragment_alpha").bind(frag), a0, a1, 0.8)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		t.tween_method(Callable(self, "_set_fragment_alpha").bind(frag), a1, a0, 0.8)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	completion_tween.set_loops(0) # 0 = infinite in Godot 4


func _stop_completion_glow() -> void:
	# STOP means stop. Do not recreate tween here.
	if completion_tween != null:
		completion_tween.kill()
		completion_tween = null


# -------------------------
# Fragments / window
# -------------------------
func _collect_fragments() -> void:
	fragments.clear()

	for i: int in range(1, WINDOW_LANTERNS + 1):
		var node_path: String = "Fragment_%d" % i
		if window_frame.has_node(node_path):
			var n: Node = window_frame.get_node(node_path)
			if n is Polygon2D:
				fragments.append(n as Polygon2D)
		else:
			push_error("Missing node: %s/%s" % [window_frame.get_path(), node_path])

	if fragments.size() != WINDOW_LANTERNS:
		push_error("Expected %d fragments. Found: %d" % [WINDOW_LANTERNS, fragments.size()])


func _set_all_fragments_unlit() -> void:
	_stop_completion_glow()
	for frag: Polygon2D in fragments:
		var c: Color = frag.color
		c.a = UNLIT_ALPHA
		frag.color = c


func _get_fragment_alpha_for_category(category_key: String) -> float:
	match category_key:
		"Avoidance":
			return 1.0
		_:
			return LIT_ALPHA


func _light_next_fragment(flame: Color, category_key: String) -> void:
	if lantern_count >= fragments.size():
		return

	var f: Polygon2D = fragments[lantern_count]
	var c: Color = flame
	c.a = _get_fragment_alpha_for_category(category_key)

	f.color = c
	lantern_count += 1


# -------------------------
# Load prompt categories
# -------------------------
func _load_all_categories() -> void:
	var files: Array[String] = [
		"IntrusiveThoughts.json",
		"Avoidance.json",
		"CognitionAndMood.json",
		"Compulsions.json",
		"SoothingAndSubstances.json"
	]

	categories.clear()
	used_indices.clear()

	for filename: String in files:
		var path: String = PROMPTS_DIR + filename
		var data: Dictionary = _load_json(path)
		if data.is_empty():
			push_error("Failed to load JSON: " + path)
			continue

		var label_text: String = str(data.get("label", filename.get_basename()))
		var flame_hex: String = str(data.get("flame_color", "#FFFFFF"))
		var prompts_arr: Array[String] = _extract_prompt_strings(data)

		if prompts_arr.is_empty():
			push_error("No prompts found in: " + filename)
			continue

		var key: String = filename.get_basename()

		categories.append({
			"key": key,
			"label": label_text,
			"flame_hex": flame_hex,
			"prompts": prompts_arr
		})

		used_indices[key] = []


func _load_json(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text: String = file.get_as_text()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary


func _extract_prompt_strings(data: Variant) -> Array[String]:
	var out: Array[String] = []

	if typeof(data) == TYPE_DICTIONARY:
		var d: Dictionary = data as Dictionary

		if d.has("prompts") and typeof(d["prompts"]) == TYPE_ARRAY:
			for item: Variant in d["prompts"]:
				if typeof(item) == TYPE_STRING:
					out.append((item as String).strip_edges())
				elif typeof(item) == TYPE_DICTIONARY and (item as Dictionary).has("text"):
					out.append(str((item as Dictionary)["text"]).strip_edges())
			return out.filter(func(s: String) -> bool: return s != "")

		for k: Variant in d.keys():
			var v: Variant = d[k]
			if typeof(v) == TYPE_ARRAY:
				for item2: Variant in v:
					if typeof(item2) == TYPE_STRING:
						out.append((item2 as String).strip_edges())
					elif typeof(item2) == TYPE_DICTIONARY and (item2 as Dictionary).has("text"):
						out.append(str((item2 as Dictionary)["text"]).strip_edges())

		return out.filter(func(s2: String) -> bool: return s2 != "")

	if typeof(data) == TYPE_ARRAY:
		for item3: Variant in data as Array:
			if typeof(item3) == TYPE_STRING:
				out.append((item3 as String).strip_edges())
			elif typeof(item3) == TYPE_DICTIONARY and (item3 as Dictionary).has("text"):
				out.append(str((item3 as Dictionary)["text"]).strip_edges())

	return out.filter(func(s3: String) -> bool: return s3 != "")


# -------------------------
# Buttons UI
# -------------------------
func _build_category_buttons() -> void:
	for child: Node in buttons_box.get_children():
		child.queue_free()

	category_buttons.clear()

	for cat: Dictionary in categories:
		var btn := Button.new()
		btn.text = str(cat["label"])
		btn.custom_minimum_size = Vector2(180, 44)

		var tint: Color = Color(str(cat["flame_hex"]))
		btn.modulate = Color(tint.r, tint.g, tint.b, 1.0)

		var key: String = str(cat["key"])
		btn.pressed.connect(func() -> void: _on_category_pressed(key))

		buttons_box.add_child(btn)
		category_buttons.append(btn)

	var random_btn := Button.new()
	random_btn.text = "Random"
	random_btn.custom_minimum_size = Vector2(120, 44)
	random_btn.pressed.connect(_on_random_pressed)

	buttons_box.add_child(random_btn)
	category_buttons.append(random_btn)

	_set_lantern_buttons_enabled(not window_complete_pending)


func _set_lantern_buttons_enabled(enabled: bool) -> void:
	for b: Button in category_buttons:
		b.disabled = not enabled


func _on_category_pressed(key: String) -> void:
	_process_lantern(key)


func _on_random_pressed() -> void:
	if categories.is_empty():
		return
	var cat: Dictionary = categories.pick_random()
	_process_lantern(str(cat["key"]))


# -------------------------
# Core lantern flow
# -------------------------
func _process_lantern(key: String) -> void:
	if window_complete_pending:
		prompt_text.text = "Window filled. Press “Complete Window” when you're ready."
		skip_button.grab_focus()
		return

	if lantern_count >= WINDOW_LANTERNS:
		return

	var cat: Dictionary = _get_category(key)
	if cat.is_empty():
		prompt_text.text = "That lantern isn't available right now."
		return

	var prompt_str: String = _pick_prompt(cat)
	if prompt_str == "":
		prompt_text.text = "This lantern rests for now."
		return

	prompt_text.text = prompt_str

	current_prompt = prompt_str
	current_category_label = str(cat["label"])
	current_category_key = str(cat["key"])

	response_edit.text = ""
	_set_response_controls_enabled(true)
	response_edit.grab_focus()

	var flame: Color = Color(str(cat["flame_hex"]))
	_light_next_fragment(flame, current_category_key)

	if lantern_count >= WINDOW_LANTERNS:
		_enter_completion_state()


func _enter_completion_state() -> void:
	window_complete_pending = true
	skip_button.text = "Complete Window"
	_set_lantern_buttons_enabled(false)
	_start_completion_glow()

	prompt_text.append_text("\n\n[color=#cfcfcf][i]When you're ready, press “Complete Window”.[/i][/color]")
	skip_button.grab_focus()


func _get_category(key: String) -> Dictionary:
	for cat: Dictionary in categories:
		if str(cat["key"]) == key:
			return cat
	return {}


func _pick_prompt(cat: Dictionary) -> String:
	var prompts: Array = cat["prompts"]
	if prompts.is_empty():
		return ""

	var key: String = str(cat["key"])
	var used: Array = used_indices.get(key, [])

	if used.size() >= prompts.size():
		used.clear()

	var idx: int = randi() % prompts.size()
	var safety: int = 0
	while used.has(idx) and safety < 500:
		idx = randi() % prompts.size()
		safety += 1

	used.append(idx)
	used_indices[key] = used

	return str(prompts[idx])


func _reset_window() -> void:
	# Clear immediately (no second delayed clear)
	_stop_completion_glow()
	lantern_count = 0
	_set_all_fragments_unlit()

	window_complete_pending = false
	skip_button.text = "Skip"
	_set_lantern_buttons_enabled(true)

	_set_response_controls_enabled(false)
	response_edit.text = ""
	current_prompt = ""
	current_category_label = ""
	current_category_key = ""

	prompt_text.text = "Choose a Lantern"


# -------------------------
# Response controls
# -------------------------
func _set_response_controls_enabled(enabled: bool) -> void:
	response_edit.editable = enabled
	save_button.disabled = not enabled

	# Skip is part of response controls, but becomes Complete Window when pending.
	if window_complete_pending:
		skip_button.disabled = false
	else:
		skip_button.disabled = not enabled


func _after_response_action(did_save: bool) -> void:
	# Clean up response UI
	response_edit.text = ""
	_set_response_controls_enabled(false)

	# Clear current tracking
	current_prompt = ""
	current_category_label = ""
	current_category_key = ""

	# If completion pending, keep focus there (don't overwrite prompt text)
	if window_complete_pending:
		skip_button.text = "Complete Window"
		skip_button.grab_focus()
		return

	# Otherwise gentle ack
	if did_save:
		prompt_text.text = "Saved."
	else:
		prompt_text.text = "Choose a Lantern"


func _on_save_pressed() -> void:
	if current_prompt == "":
		return

	_append_to_journal(current_category_label, current_prompt, response_edit.text)
	_after_response_action(true)


func _on_skip_pressed() -> void:
	if window_complete_pending:
		_reset_window()
		return

	_after_response_action(false)


# -------------------------
# Journal
# -------------------------
func _ensure_journals_dir() -> void:
	# Creates user://journals/ if missing
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(JOURNALS_DIR))

func open_journal_folder() -> void:
	_ensure_journals_dir()
	var abs_path: String = ProjectSettings.globalize_path(JOURNALS_DIR)
	OS.shell_open(abs_path)

func set_journal_filename(name: String) -> void:
	# Optional: if later you want “Profile A / Profile B” etc.
	name = name.strip_edges()
	if name == "":
		name = "journal.txt"
	if not name.ends_with(".txt"):
		name += ".txt"
	journal_filename = name
	journal_path = JOURNALS_DIR + journal_filename

func _append_to_journal(category_line: String, prompt_line: String, response_line: String) -> void:
	var file: FileAccess = FileAccess.open(journal_path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(journal_path, FileAccess.WRITE)
		if file == null:
			push_error("Could not write journal file: " + journal_path)
			return

	file.seek_end()

	var timestamp: String = Time.get_datetime_string_from_system()
	file.store_line("[" + timestamp + "] " + category_line)
	file.store_line(prompt_line)

	var cleaned: String = response_line.strip_edges()
	if cleaned != "":
		file.store_line("Notes: " + cleaned)
	else:
		file.store_line("Notes: (skipped)")

	file.store_line("")
	file.close()
