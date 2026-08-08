extends SubViewportContainer

## Shared 3D layer that every on-screen Card mesh lives in. One Camera3D/light
## for the whole layer (not one per card) since board.gd rebuilds every Card
## node on nearly every refresh and this project targets a web export -
## per-card viewports/cameras would be far too much churn there.
##
## A Card acquires a MeshInstance3D here and repositions it every frame to
## match its own on-screen rect (see place()). That means drag, hand-squish
## spacing, and the lift-on-select offset all stay correct for free, since
## the mesh position is derived from the Card's live rect rather than
## duplicated bookkeeping.

## .glb imports as a PackedScene (a node tree), not a bare Mesh like the old
## ThickCard.obj did - the actual Mesh resource is pulled off each one's
## MeshInstance3D child once, in _ready(), and cached in _card_meshes below.
## Each color is its own separate model (not a shared mesh + tinted material)
## since the color's frame/border art is now baked into the model itself.
const CARD_MODEL_SCENES := {
	CardData.CardColor.GREEN: preload("res://assets/Green.glb"),
	CardData.CardColor.CRIMSON: preload("res://assets/crimson.glb"),
	CardData.CardColor.BLACK: preload("res://assets/Black.glb"),
	CardData.CardColor.ORANGE: preload("res://assets/Orange.glb"),
	CardData.CardColor.TEAL: preload("res://assets/teal.glb"),
	CardData.CardColor.GENERIC: preload("res://assets/genericcard.glb"),
}

## The model was modeled lying flat (face normal along +Y). This stands it up
## to face the camera.
const BASE_ROTATION_DEG := Vector3(-90, 0, 0)
## Standing it up alone came out upside-down, so flip 180 degrees in-plane
## (about the now-camera-facing axis) on top of that. If art ever needs a
## left-right mirror too, that'd show up as backwards (not upside-down) text.
const UPRIGHT_FLIP_DEG := 180.0

## World units visible across the viewport's height (orthogonal camera).
## Combined with the fixed 1920x1080 base resolution this gives a simple,
## constant pixels-per-unit conversion (see _px_to_world).
const CAM_ORTHO_SIZE := 10.8
const BASE_RESOLUTION := Vector2i(1920, 1080)

const ART_SURFACE := "Card_Art"

@onready var _viewport: SubViewport = $SubViewport
@onready var _camera: Camera3D = $SubViewport/Camera3D
@onready var _mesh_root: Node3D = $SubViewport/Cards

## CardColor -> Mesh, populated once in _ready() from CARD_MODEL_SCENES.
var _card_meshes: Dictionary = {}
## Width/height is identical across every color variant (only their
## thickness differs - see _front_z_by_color), so this is a single shared
## value rather than one per color.
var _native_size: Vector2 = Vector2.ZERO
## CardColor -> how far that color's own frontmost point (its Card_Art/
## Card_Panel face, post-_stand_basis()) sits along local +Z from the mesh's
## origin. The text-overlay quad needs to clear this or it loses the depth
## test against the mesh's own opaque surfaces and renders as fully
## invisible. Per-color because the 5 color models are noticeably thicker
## than the generic fallback model, despite sharing the same width/height.
var _front_z_by_color: Dictionary = {}
var _px_per_unit: float = 0.0

func _ready() -> void:
	add_to_group("card_3d_layer")
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Sized directly off the viewport instead of anchors: this scene gets
	# instanced under both Node2D (Board) and Control (DeckBuilderScreen)
	# parents, and anchor-based stretching only resolves correctly under a
	# Control ancestor - under Node2D it collapses to a 0x0 rect.
	position = Vector2.ZERO
	size = get_viewport_rect().size
	# stretch=true makes the container manage the child SubViewport's size
	# itself (to match this container's size) - setting it manually here
	# throws a "can't change size" warning and is a no-op.
	_viewport.transparent_bg = true
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = CAM_ORTHO_SIZE
	_camera.position = Vector3(0, 0, 10)
	_camera.rotation = Vector3.ZERO
	_camera.near = 0.05
	_camera.far = 20.0
	_px_per_unit = BASE_RESOLUTION.y / CAM_ORTHO_SIZE
	for color in CARD_MODEL_SCENES:
		var mesh := _extract_card_mesh(CARD_MODEL_SCENES[color])
		_card_meshes[color] = mesh
		var dims := _compute_mesh_dims(mesh)
		_native_size = dims["size"]
		_front_z_by_color[color] = dims["front_z"]

## Instantiates a .glb once to pull out its Mesh resource, then discards the
## instance - every card's own MeshInstance3D reuses this same cached Mesh
## via acquire_mesh()/configure_theme() rather than each keeping a live copy
## of the whole scene.
func _extract_card_mesh(scene: PackedScene) -> Mesh:
	var instance := scene.instantiate()
	var mesh_instance := _find_mesh_instance(instance)
	var mesh: Mesh = mesh_instance.mesh if mesh_instance else null
	instance.queue_free()
	return mesh

func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_mesh_instance(child)
		if found:
			return found
	return null

## Fraction of the mesh's own footprint the text-overlay quad covers - just
## shy of 1.0 so it sits inside the card's outer frame/border rather than
## drawing past the edge of it.
const TEXT_OVERLAY_INSET := 0.94
## Extra clearance the text overlay sits beyond the mesh's own frontmost
## point (_front_z_by_color), as a fraction of that depth - these models have
## real physical thickness, so the quad needs to clear it by a real margin or
## it loses the depth test against the mesh's own opaque surfaces and the
## text renders as fully invisible despite everything else being correct.
const TEXT_OVERLAY_FRONT_MARGIN := 0.25

func acquire_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _card_meshes.get(CardData.CardColor.GENERIC)
	mi.transform.basis = _stand_basis()
	_mesh_root.add_child(mi)
	_add_text_overlay(mi, CardData.CardColor.GENERIC)
	return mi

func release_mesh(mesh: MeshInstance3D) -> void:
	if is_instance_valid(mesh):
		mesh.queue_free()

## A thin quad, parented to the card mesh, that the card's baked text
## texture gets projected onto (see set_text_texture()). Being a child of
## the mesh, it inherits the mesh's own transform - including the hover/drag
## tilt applied in place() - so the text turns with the card instead of
## staying pasted flat on the screen above it.
##
## The mesh instance's own basis carries both the constant "stand the .obj
## up to face the camera" rotation (_stand_basis()) and the live hover/drag
## tilt (see place()). Giving the quad the *inverse* of just the constant
## part as its local basis cancels that part back out, leaving the quad
## facing the camera (a plain QuadMesh's default orientation) plus whatever
## live tilt the parent currently has - without the overlay needing to know
## anything about the .obj's own modeled orientation.
func _add_text_overlay(mesh: MeshInstance3D, color: CardData.CardColor) -> void:
	var overlay := MeshInstance3D.new()
	overlay.name = "TextOverlay"
	var quad := QuadMesh.new()
	quad.size = _native_size * TEXT_OVERLAY_INSET
	overlay.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Fully transparent until set_text_texture() assigns a real texture - an
	# untextured StandardMaterial3D defaults to opaque white, which would
	# otherwise blank out every card that opts out of the overlay (preview
	# instances - see Card.use_text_overlay) behind a solid white square.
	mat.albedo_color = Color(1, 1, 1, 0)
	overlay.set_surface_override_material(0, mat)
	mesh.add_child(overlay)
	_reposition_text_overlay(mesh, color)

## Re-centers the text overlay's forward offset for mesh's current color -
## called whenever the underlying mesh (and therefore its thickness) changes
## in configure_theme(), since the 5 color models are noticeably thicker than
## the generic fallback despite sharing the same width/height (see
## _front_z_by_color).
func _reposition_text_overlay(mesh: MeshInstance3D, color: CardData.CardColor) -> void:
	var overlay := mesh.get_node_or_null("TextOverlay") as MeshInstance3D
	if overlay == null:
		return
	var counter_rotation := _stand_basis().inverse()
	overlay.transform.basis = counter_rotation
	var front_z: float = _front_z_by_color.get(color, _front_z_by_color.get(CardData.CardColor.GENERIC, 0.0))
	var offset_amount := front_z * (1.0 + TEXT_OVERLAY_FRONT_MARGIN)
	overlay.position = counter_rotation * Vector3(0, 0, offset_amount)

## Projects a card's baked text (see Card._setup_text_overlay()) onto its
## mesh's text-overlay quad. No-op if the mesh has no overlay - either it's
## a stale reference or the card opted out (use_text_overlay = false).
func set_text_texture(mesh: MeshInstance3D, texture: Texture2D) -> void:
	if not is_instance_valid(mesh):
		return
	var overlay := mesh.get_node_or_null("TextOverlay") as MeshInstance3D
	if overlay == null:
		return
	var mat := overlay.get_surface_override_material(0)
	if mat is StandardMaterial3D:
		var smat := mat as StandardMaterial3D
		smat.albedo_texture = texture
		smat.albedo_color = Color(1, 1, 1, 1)

## Swaps in the color-specific model - its frame/border/panel/art surfaces
## all come pre-textured from the export, one full model per color rather
## than a shared mesh with code-tinted materials. The card's own art is no
## longer applied here: it's baked into the 2D text overlay instead (see
## Card._setup_text_overlay()) so it tilts with the card like the text does,
## and that overlay's art rect doesn't line up with this mesh's Card_Art
## surface UVs, so leaving this surface on its own baked default (instead of
## overriding it per-card) avoids a mismatched second copy showing through
## around the edges of the 2D one.
func configure_theme(mesh: MeshInstance3D, color: CardData.CardColor, art: Texture2D) -> void:
	if not is_instance_valid(mesh):
		return
	var new_mesh: Mesh = _card_meshes.get(color, _card_meshes.get(CardData.CardColor.GENERIC))
	mesh.mesh = new_mesh
	for i in new_mesh.get_surface_count():
		mesh.set_surface_override_material(i, null)
	_reposition_text_overlay(mesh, color)

## Tints the whole card (used for damage flash / transform pulses). Pass
## null to clear back to the normal per-surface materials.
func set_flash_tint(mesh: MeshInstance3D, color) -> void:
	if not is_instance_valid(mesh):
		return
	if color == null:
		mesh.material_override = null
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.6
	mesh.material_override = mat

## screen_rect: the card's current on-screen rect (global position + size,
## in the project's base 1920x1080 canvas_items coordinate space).
## tilt: (yaw, pitch) in radians, hover-driven.
## z_order: small integer stacking index so overlapping cards (hand fan,
## a dragged card) don't z-fight; higher draws closer to the camera.
func place(mesh: MeshInstance3D, screen_rect: Rect2, tilt: Vector2, z_order: int) -> void:
	if not is_instance_valid(mesh):
		return
	var center := screen_rect.get_center()
	var world_pos := Vector3(
		_px_to_world_x(center.x),
		_px_to_world_y(center.y),
		z_order * 0.01
	)
	var tilt_basis := Basis(Vector3.UP, tilt.x) * Basis(Vector3.RIGHT, tilt.y)
	mesh.transform.basis = tilt_basis * _stand_basis()
	mesh.position = world_pos
	if _native_size.x > 0.0 and _native_size.y > 0.0:
		var target_world_w: float = screen_rect.size.x / _px_per_unit
		var target_world_h: float = screen_rect.size.y / _px_per_unit
		var scale_factor: float = min(target_world_w / _native_size.x, target_world_h / _native_size.y)
		mesh.scale = Vector3.ONE * scale_factor

func _stand_basis() -> Basis:
	var stand := Basis.from_euler(BASE_ROTATION_DEG * (PI / 180.0))
	var flip := Basis(Vector3(0, 0, 1), deg_to_rad(UPRIGHT_FLIP_DEG))
	return flip * stand

func _px_to_world_x(x: float) -> float:
	return (x - BASE_RESOLUTION.x / 2.0) / _px_per_unit

func _px_to_world_y(y: float) -> float:
	return -(y - BASE_RESOLUTION.y / 2.0) / _px_per_unit

## Post-_stand_basis() bounding size of a mesh, in mesh-local world units,
## used to scale each instance to match its on-screen pixel rect - plus the
## frontmost Z extent (see _front_z_by_color's comment), keyed "size"/
## "front_z" in the returned Dictionary.
func _compute_mesh_dims(mesh: Mesh) -> Dictionary:
	var aabb := mesh.get_aabb()
	var basis := _stand_basis()
	var minv := Vector3.INF
	var maxv := -Vector3.INF
	for i in 8:
		var corner := aabb.position + Vector3(
			aabb.size.x * (i & 1),
			aabb.size.y * ((i >> 1) & 1),
			aabb.size.z * ((i >> 2) & 1)
		)
		var t := basis * corner
		minv = minv.min(t)
		maxv = maxv.max(t)
	var size := maxv - minv
	return {"size": Vector2(size.x, size.y), "front_z": maxv.z}
