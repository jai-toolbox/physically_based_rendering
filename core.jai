SHADOW_MAP_SIZE :: 2048;

MAX_LIGHTS      :: MAX_POINT_LIGHTS;
Light           :: Point_Light;

/*
lighting mobility note for future light baking:

The important split is light mobility vs receiver mobility.

    static light  -> static receiver  : bake into lightmaps/probes; do not also evaluate that light at runtime for that receiver
    static light  -> dynamic receiver : runtime direct light or sample baked probes/volumes
    dynamic light -> static receiver  : runtime light, because the light changes
    dynamic light -> dynamic receiver : runtime light

Shadows have a similar caster/receiver split:
static caster + static receiver under static light can be baked; any dynamic caster/receiver interaction needs a runtime shadow or approximation.

When we add baked lighting, avoid making the shader decide the whole matrix. The CPU should split renderables/lights into queues and upload only the relevant realtime light lists. Static baked renderables should sample baked diffuse lighting and then add runtime dynamic/mixed contributions, while dynamic renderables use realtime lights and/or probes.
*/

Directional_Shadow_Map :: struct {
    framebuffer_gl_handle: GLuint;
    depth_texture_gl_handle: GLuint;
    shader_program_gl_handle: GLuint;
    world_to_light_clip_uniform_location: GLint = -1;
    world_to_light_clip: Matrix4 = Matrix4_Identity;
    initialized := false;
}

// the main thing
PBR_Packed_Texture_Rendering :: struct {
    renderer: Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderer;
    opaque_renderables: [..] Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable;
    transparent_renderables: [..] Transparent_PBR_Renderable;

    using #as base: Packed_Texture_Rendering_Base;

    lights: [MAX_LIGHTS] Light;
    num_active_lights: s32 = 0;
    spot_lights: [MAX_SPOT_LIGHTS] Spot_Light;
    num_active_spot_lights: s32 = 0;
    point_light_gizmos: [..] Camera_Per_Object_Transform_Color_Renderable;
    spot_light_gizmos: [..] Camera_Per_Object_Transform_Color_Renderable;
    loaded_any_scene_light := false;

    reflection_cubemap: Cubemap;
    has_reflection_cubemap := false;
    ambient_strength: float32 = 0.03;
    world_background_color := Vector3.{0.05, 0.05, 0.08};
    debug_render_normals := false;

    directional_light: Directional_Light;
    shadow_map: Directional_Shadow_Map;
}

PBR_ALPHA_MODE_OPAQUE :: 0.0;
PBR_ALPHA_MODE_MASK   :: 1.0;
PBR_ALPHA_MODE_BLEND  :: 2.0;

Transparent_PBR_Renderable :: struct {
    renderable: Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable;
    sort_position: Vector3;
}

/*
Complete CPU representation of one PBR primitive. It deliberately contains no
renderer indices, OpenGL handles, or backend state, so glTF jobs can construct
it away from the graphics thread.
*/
PBR_Packed_Texture_Primitive :: struct {
    indices: [..] u32;
    positions: [..] Vector3;
    normals: [..] Vector3;
    tangents: [..] Vector4;
    texture_coordinates_0: [..] Vector4;
    texture_coordinates_1: [..] Vector4;
    base_color_factors: [..] Vector4;
    material_parameters: [..] Vector4;
    glass_parameters: [..] Vector4;
    volume_parameters: [..] Vector4;
    alpha_parameters: [..] Vector2;
    base_color_texture_bindings: [..] [2] s32;
    normal_texture_bindings: [..] [2] s32;
    metallic_roughness_texture_bindings: [..] [2] s32;
    ambient_occlusion_texture_bindings: [..] [2] s32;

    local_to_model: Matrix4 = Matrix4_Identity;
    local_center: Vector3;
    local_bounds_min: Vector3;
    local_bounds_max: Vector3;
    has_local_bounds: bool;
    is_transparent: bool;
}

PBR_Packed_Texture_Model :: struct {
    primitives: [..] PBR_Packed_Texture_Primitive;
}

deinit :: (primitive: *PBR_Packed_Texture_Primitive) {
    array_free(primitive.indices);
    array_free(primitive.positions);
    array_free(primitive.normals);
    array_free(primitive.tangents);
    array_free(primitive.texture_coordinates_0);
    array_free(primitive.texture_coordinates_1);
    array_free(primitive.base_color_factors);
    array_free(primitive.material_parameters);
    array_free(primitive.glass_parameters);
    array_free(primitive.volume_parameters);
    array_free(primitive.alpha_parameters);
    array_free(primitive.base_color_texture_bindings);
    array_free(primitive.normal_texture_bindings);
    array_free(primitive.metallic_roughness_texture_bindings);
    array_free(primitive.ambient_occlusion_texture_bindings);
    primitive.* = .{};
}

deinit :: (model: *PBR_Packed_Texture_Model) {
    for *primitive: model.primitives deinit(primitive);
    array_free(model.primitives);
    model.* = .{};
}

PBR_Model_Renderable :: struct {
    is_transparent: bool;
    index: int;
    local_to_model: Matrix4;
    local_center: Vector3;
    local_bounds_min: Vector3;
    local_bounds_max: Vector3;
    has_local_bounds: bool;
}

PBR_Model_Instance :: struct {
    renderables: [..] PBR_Model_Renderable;
}

init :: (using ptr: *PBR_Packed_Texture_Rendering, cubemap_for_reflection: Cubemap = .{}, has_cubemap_for_reflection: bool = false) {
    init(*renderer);
    init(*base);
    init(*shadow_map);
    ptr.reflection_cubemap = cubemap_for_reflection;
    ptr.has_reflection_cubemap = has_cubemap_for_reflection;

    gl_set_active_shader_program(renderer.shader_program_gl_handle);
    set_packed_textures_uniform(*renderer, 0);
    set_packed_texture_bounding_boxes_uniform(*renderer, 1);
    set_reflection_cubemap_uniform(*renderer, 2);
    set_use_reflection_cubemap_uniform(*renderer, has_cubemap_for_reflection);
    set_reflection_strength_uniform(*renderer, 0.75);
    gl_clear_active_shader_program();
}

set_model_transform :: (using ptr: *PBR_Packed_Texture_Rendering, model: *PBR_Model_Instance, model_to_world: Matrix4) {
    for model.renderables {
        local_to_world := model_to_world * it.local_to_model;

        if it.is_transparent {
            if it.index < 0 || it.index >= transparent_renderables.count continue;
            transparent_renderables[it.index].sort_position = transform_point(local_to_world, it.local_center);
            set_local_to_world_matrix(*renderer, transparent_renderables[it.index].renderable, local_to_world);
        } else {
            if it.index < 0 || it.index >= opaque_renderables.count continue;
            set_local_to_world_matrix(*renderer, opaque_renderables[it.index], local_to_world);
        }
    }
}

add_light :: (
    using ptr: *PBR_Packed_Texture_Rendering,
    position: Vector3,
    color: Vector3,
    range: float = 0.0,
    intensity: float = 1.0
) -> light_index: s32, success: bool {
    if num_active_lights >= MAX_LIGHTS {
        log("Cannot add light: maximum of % lights reached", MAX_LIGHTS);
        return 0, false;
    }
    lights[num_active_lights] = .{
        position = position,
        color = color,
        intensity = intensity,
        range = range,
        enabled = true,
    };
    index := num_active_lights;
    num_active_lights += 1;
    loaded_any_scene_light = true;
    return index, true;
}

add_spot_light :: (
    using ptr: *PBR_Packed_Texture_Rendering,
    position: Vector3,
    direction: Vector3,
    color: Vector3,
    inner_cone_angle: float,
    outer_cone_angle: float,
    range: float,
    intensity: float = 1.0
) -> light_index: s32, success: bool {
    if num_active_spot_lights >= MAX_SPOT_LIGHTS {
        log("Cannot add spot light: maximum of % lights reached", MAX_SPOT_LIGHTS);
        return 0, false;
    }

    spot_lights[num_active_spot_lights] = .{
        position = position,
        direction = normalize(direction),
        color = color,
        intensity = intensity,
        inner_cos = cos(inner_cone_angle),
        outer_cos = cos(outer_cone_angle),
        range = range,
        enabled = true,
    };

    index := num_active_spot_lights;
    num_active_spot_lights += 1;
    loaded_any_scene_light = true;
    return index, true;
}

set_directional_light :: (using ptr: *PBR_Packed_Texture_Rendering, direction: Vector3, color: Vector3, intensity: float, casts_shadows: bool = true) {
    directional_light.direction = normalize(direction);
    directional_light.color = color;
    directional_light.intensity = intensity;
    directional_light.enabled = true;
    directional_light.casts_shadows = casts_shadows;
    loaded_any_scene_light = true;
}

ensure_fallback_directional_light :: (using ptr: *PBR_Packed_Texture_Rendering) {
    if loaded_any_scene_light return;
    set_directional_light(ptr, .{-0.4, -1.0, -0.35}, .{1.0, 0.96, 0.88}, 2.0, true);
    log("No glTF punctual lights found; using fallback directional light");
}

set_lights_uniform :: (shader_program_gl_handle: GLuint, lights: [] Light) {
    for lights {
        position_name := tprint("lights[%].position\0", it_index);
        color_name := tprint("lights[%].color\0", it_index);
        intensity_name := tprint("lights[%].intensity\0", it_index);
        range_name := tprint("lights[%].range\0", it_index);
        enabled_name := tprint("lights[%].enabled\0", it_index);

        pos_loc := gl_get_uniform_location_in_shader_program(shader_program_gl_handle, position_name.data);
        col_loc := gl_get_uniform_location_in_shader_program(shader_program_gl_handle, color_name.data);
        intensity_loc := gl_get_uniform_location_in_shader_program(shader_program_gl_handle, intensity_name.data);
        range_loc := gl_get_uniform_location_in_shader_program(shader_program_gl_handle, range_name.data);
        enabled_loc := gl_get_uniform_location_in_shader_program(shader_program_gl_handle, enabled_name.data);

        gl_set_uniform_3f_on_active_shader_program(pos_loc, it.position.x, it.position.y, it.position.z);
        gl_set_uniform_3f_on_active_shader_program(col_loc, it.color.x, it.color.y, it.color.z);
        gl_set_uniform_1f_on_active_shader_program(intensity_loc, it.intensity);
        gl_set_uniform_1f_on_active_shader_program(range_loc, it.range);
        gl_set_uniform_1i_on_active_shader_program(enabled_loc, cast(s32) ifx it.enabled then 1 else 0);
    }
}

// we need a better way of reaching arrays.
set_spot_lights_uniform :: (shader_program_gl_handle: GLuint, spot_lights: [] Spot_Light) {
    for spot_lights {
        position_name := tprint("spot_lights[%].position\0", it_index);
        direction_name := tprint("spot_lights[%].direction\0", it_index);
        color_name := tprint("spot_lights[%].color\0", it_index);
        intensity_name := tprint("spot_lights[%].intensity\0", it_index);
        inner_name := tprint("spot_lights[%].inner_cos\0", it_index);
        outer_name := tprint("spot_lights[%].outer_cos\0", it_index);
        range_name := tprint("spot_lights[%].range\0", it_index);
        enabled_name := tprint("spot_lights[%].enabled\0", it_index);

        loc := gl_get_uniform_location_in_shader_program(shader_program_gl_handle, position_name.data);
        gl_set_uniform_3f_on_active_shader_program(loc, it.position.x, it.position.y, it.position.z);
        loc = gl_get_uniform_location_in_shader_program(shader_program_gl_handle, direction_name.data);
        gl_set_uniform_3f_on_active_shader_program(loc, it.direction.x, it.direction.y, it.direction.z);
        loc = gl_get_uniform_location_in_shader_program(shader_program_gl_handle, color_name.data);
        gl_set_uniform_3f_on_active_shader_program(loc, it.color.x, it.color.y, it.color.z);
        loc = gl_get_uniform_location_in_shader_program(shader_program_gl_handle, intensity_name.data);
        gl_set_uniform_1f_on_active_shader_program(loc, it.intensity);
        loc = gl_get_uniform_location_in_shader_program(shader_program_gl_handle, inner_name.data);
        gl_set_uniform_1f_on_active_shader_program(loc, it.inner_cos);
        loc = gl_get_uniform_location_in_shader_program(shader_program_gl_handle, outer_name.data);
        gl_set_uniform_1f_on_active_shader_program(loc, it.outer_cos);
        loc = gl_get_uniform_location_in_shader_program(shader_program_gl_handle, range_name.data);
        gl_set_uniform_1f_on_active_shader_program(loc, it.range);
        loc = gl_get_uniform_location_in_shader_program(shader_program_gl_handle, enabled_name.data);
        gl_set_uniform_1i_on_active_shader_program(loc, cast(s32) ifx it.enabled then 1 else 0);
    }
}
