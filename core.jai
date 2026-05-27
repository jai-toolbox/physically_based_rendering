MAX_LIGHTS :: 16;
MAX_SPOT_LIGHTS :: 16;
SHADOW_MAP_SIZE :: 2048;
BLENDER_GLTF_WATTS_TO_LUMENS :: 683.0;

Light :: struct {
    position: Vector3;
    color: Vector3;
}

Spot_Light :: struct {
    position: Vector3;
    direction: Vector3;
    color: Vector3;
    inner_cos: float;
    outer_cos: float;
    range: float;
}

/*
Lighting mobility note for future light baking:

The important split is light mobility vs receiver mobility.

    static light  -> static receiver  : bake into lightmaps/probes; do not also evaluate that light at runtime for that receiver
    static light  -> dynamic receiver : runtime direct light or sample baked probes/volumes
    dynamic light -> static receiver  : runtime light, because the light changes
    dynamic light -> dynamic receiver : runtime light

Shadows have a similar caster/receiver split:
static caster + static receiver under static light can be baked; any dynamic caster/receiver interaction needs a runtime shadow or approximation.

When we add baked lighting, avoid making the shader decide the whole matrix. The CPU should split renderables/lights into queues and upload only the relevant realtime light lists. Static baked renderables should sample baked diffuse lighting and then add runtime dynamic/mixed contributions, while dynamic renderables use realtime lights and/or probes.
*/

Directional_Light :: struct {
    direction: Vector3 = .{-0.4, -1.0, -0.35};
    color: Vector3 = .{1.0, 0.96, 0.88};
    intensity: float = 2.0;
    enabled := false;
    casts_shadows := true;
}

Directional_Shadow_Map :: struct {
    framebuffer_gl_handle: GLuint;
    depth_texture_gl_handle: GLuint;
    shader_program_gl_handle: GLuint;
    world_to_light_clip_uniform_location: GLint = -1;
    world_to_light_clip: Matrix4 = Matrix4_Identity;
    initialized := false;
}

// the main thing.
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

init :: (using ptr: *PBR_Packed_Texture_Rendering, cubemap_for_reflection: Cubemap = .{}, has_cubemap_for_reflection: bool = false) {
    init(*renderer);
    init(*base);
    init(*shadow_map);
    ptr.reflection_cubemap = cubemap_for_reflection;
    ptr.has_reflection_cubemap = has_cubemap_for_reflection;

    glUseProgram(renderer.shader_program_gl_handle);
    set_packed_textures_uniform(*renderer, 0);
    set_packed_texture_bounding_boxes_uniform(*renderer, 1);
    set_reflection_cubemap_uniform(*renderer, 2);
    set_use_reflection_cubemap_uniform(*renderer, has_cubemap_for_reflection);
    set_reflection_strength_uniform(*renderer, 0.75);
    glUseProgram(0);
}

add_light :: (using ptr: *PBR_Packed_Texture_Rendering, position: Vector3, color: Vector3) -> light_index: s32, success: bool {
    if num_active_lights >= MAX_LIGHTS {
        log("Cannot add light: maximum of % lights reached", MAX_LIGHTS);
        return 0, false;
    }
    lights[num_active_lights] = .{position = position, color = color};
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
    range: float
) -> light_index: s32, success: bool {
    if num_active_spot_lights >= MAX_SPOT_LIGHTS {
        log("Cannot add spot light: maximum of % lights reached", MAX_SPOT_LIGHTS);
        return 0, false;
    }

    spot_lights[num_active_spot_lights] = .{
        position = position,
        direction = normalize(direction),
        color = color,
        inner_cos = cos(inner_cone_angle),
        outer_cos = cos(outer_cone_angle),
        range = range,
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

        pos_loc := glGetUniformLocation(shader_program_gl_handle, position_name.data);
        col_loc := glGetUniformLocation(shader_program_gl_handle, color_name.data);

        glUniform3f(pos_loc, it.position.x, it.position.y, it.position.z);
        glUniform3f(col_loc, it.color.x, it.color.y, it.color.z);
    }
}

set_spot_lights_uniform :: (shader_program_gl_handle: GLuint, spot_lights: [] Spot_Light) {
    for spot_lights {
        position_name := tprint("spot_lights[%].position\0", it_index);
        direction_name := tprint("spot_lights[%].direction\0", it_index);
        color_name := tprint("spot_lights[%].color\0", it_index);
        inner_name := tprint("spot_lights[%].inner_cos\0", it_index);
        outer_name := tprint("spot_lights[%].outer_cos\0", it_index);
        range_name := tprint("spot_lights[%].range\0", it_index);

        loc := glGetUniformLocation(shader_program_gl_handle, position_name.data);
        glUniform3f(loc, it.position.x, it.position.y, it.position.z);
        loc = glGetUniformLocation(shader_program_gl_handle, direction_name.data);
        glUniform3f(loc, it.direction.x, it.direction.y, it.direction.z);
        loc = glGetUniformLocation(shader_program_gl_handle, color_name.data);
        glUniform3f(loc, it.color.x, it.color.y, it.color.z);
        loc = glGetUniformLocation(shader_program_gl_handle, inner_name.data);
        glUniform1f(loc, it.inner_cos);
        loc = glGetUniformLocation(shader_program_gl_handle, outer_name.data);
        glUniform1f(loc, it.outer_cos);
        loc = glGetUniformLocation(shader_program_gl_handle, range_name.data);
        glUniform1f(loc, it.range);
    }
}

