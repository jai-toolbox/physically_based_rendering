make_directional_light_view_matrix :: (direction: Vector3, center: Vector3, distance_from_center: float) -> Matrix4 {
    forward := normalize(direction);
    up_reference := Vector3.{0, 1, 0};
    if abs(dot(forward, up_reference)) > 0.95 up_reference = .{0, 0, 1};

    right := normalize(cross(forward, up_reference));
    up := cross(right, forward);
    eye := center - forward * distance_from_center;

    result := Matrix4_Identity;
    result.coef[0][0] = right.x;
    result.coef[0][1] = right.y;
    result.coef[0][2] = right.z;
    result.coef[0][3] = -dot(right, eye);

    result.coef[1][0] = up.x;
    result.coef[1][1] = up.y;
    result.coef[1][2] = up.z;
    result.coef[1][3] = -dot(up, eye);

    result.coef[2][0] = -forward.x;
    result.coef[2][1] = -forward.y;
    result.coef[2][2] = -forward.z;
    result.coef[2][3] = dot(forward, eye);

    return result;
}

make_directional_light_clip_matrix :: (direction: Vector3, center: Vector3, half_extent: float, depth_extent: float) -> Matrix4 {
    world_to_light := make_directional_light_view_matrix(direction, center, depth_extent * 0.5);
    light_to_clip := orthographic_projection_matrix(
        left = -half_extent,
        right = half_extent,
        bottom = -half_extent,
        top = half_extent,
        near = -depth_extent,
        far = depth_extent,
        depth_range_01 = false
    );
    return light_to_clip * world_to_light;
}

init :: (using shadow_map: *Directional_Shadow_Map) {
    /*
    keep this consistent with the primary PBR renderer: shader sources are
    embedded at compile time, so a packaged viewer does not depend on the
    repository's source-shader directory being present at runtime.
    */
    vertex_shader_source := #run read_entire_file(
        tprint("%../opengl/shaders/out/directional_shadow_depth.vert", #filepath)
    );
    fragment_shader_source := #run read_entire_file(
        tprint("%../opengl/shaders/out/directional_shadow_depth.frag", #filepath)
    );

    shadow_shader_program, shader_ok := create_shader_program(vertex_shader_source, fragment_shader_source);
    if !shader_ok {
        log_error("Failed to create directional shadow shader; directional shadows are disabled");
        return;
    }
    shader_program_gl_handle = shadow_shader_program;
    world_to_light_clip_uniform_location = gl_get_uniform_location_in_shader_program(
        shader_program_gl_handle,
        "world_to_light_clip",
    );

    framebuffer_gl_handle = gl_create_framebuffer();

    depth_texture_gl_handle = gl_create_texture();
    gl_bind_texture_to_binding_target_of_active_texture_unit(GL_TEXTURE_2D, depth_texture_gl_handle);
    gl_define_texture_2d_image_for_active_texture_unit(
        GL_TEXTURE_2D,
        0,
        GL_DEPTH_COMPONENT,
        SHADOW_MAP_SIZE,
        SHADOW_MAP_SIZE,
        0,
        GL_DEPTH_COMPONENT,
        GL_FLOAT,
        null,
    );
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
    gl_set_integer_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);

    border_color := float32.[1.0, 1.0, 1.0, 1.0];
    gl_set_float_vector_parameter_for_texture_bound_to_binding_target_of_active_texture_unit(
        GL_TEXTURE_2D,
        GL_TEXTURE_BORDER_COLOR,
        border_color.data,
    );

    previous_framebuffer_state := gl_capture_framebuffer_state();
    gl_bind_framebuffer_to_binding_target(GL_FRAMEBUFFER, framebuffer_gl_handle);
    gl_attach_2d_texture_image_to_framebuffer_bound_to_binding_target(
        GL_FRAMEBUFFER,
        GL_DEPTH_ATTACHMENT,
        GL_TEXTURE_2D,
        depth_texture_gl_handle,
        0,
    );
    gl_set_draw_buffer_for_bound_draw_framebuffer(GL_NONE);
    gl_set_read_buffer_for_bound_read_framebuffer(GL_NONE);

    initialized = gl_get_status_of_framebuffer_bound_to_binding_target(GL_FRAMEBUFFER)
        == GL_FRAMEBUFFER_COMPLETE;
    if !initialized {
        log_error("Directional shadow framebuffer is incomplete");
    }

    gl_restore_framebuffer_state(previous_framebuffer_state);
    gl_bind_texture_to_binding_target_of_active_texture_unit(GL_TEXTURE_2D, 0);
}

deinit :: (using shadow_map: *Directional_Shadow_Map) {
    if shader_program_gl_handle != 0 gl_delete_shader_program(shader_program_gl_handle);
    if depth_texture_gl_handle != 0 gl_delete_texture(depth_texture_gl_handle);
    if framebuffer_gl_handle != 0 gl_delete_framebuffer(framebuffer_gl_handle);
    shadow_map.* = .{};
}

render_directional_shadow_map :: (
    using shadow_map: *Directional_Shadow_Map,
    renderer: *Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderer,
    renderables: [] Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable,
    world_to_light_clip_matrix: Matrix4
) {
    if !initialized return;

    world_to_light_clip = world_to_light_clip_matrix;

    previous_framebuffer_state := gl_capture_framebuffer_state();
    defer gl_restore_framebuffer_state(previous_framebuffer_state);

    gl_set_viewport_rectangle(0, 0, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE);
    gl_bind_framebuffer_to_binding_target(GL_FRAMEBUFFER, framebuffer_gl_handle);
    gl_clear_depth_buffer();

    gl_set_active_shader_program(shader_program_gl_handle);
    gl_set_uniform_matrix_4fv_on_active_shader_program(world_to_light_clip_uniform_location, 1, GL_TRUE, *world_to_light_clip.coef[0][0]);

    upload_to_gpu(*renderer.ltw_pool);

    shadow_vertex_array := gl_create_vertex_array();
    gl_bind_vertex_array(shadow_vertex_array);
    bind_directional_shadow_attributes(shader_program_gl_handle, renderer);

    geom_indices_to_render: [..] u32;
    defer array_free(geom_indices_to_render);

    for renderables {
        success, geom_indices := table_find(*renderer.buffered_object_index_to_global_indices, it.object_index);
        if !success {
            log("shadow pass: couldn't find the global indices of object with id: %", it.object_index);
            continue;
        }
        for geom_indices array_add(*geom_indices_to_render, it);
    }

    gl_bind_buffer_to_binding_target(GL_ELEMENT_ARRAY_BUFFER, renderer.index_buffer_gl_handle);
    gl_update_subdata_in_buffer_bound_to_binding_target(
        GL_ELEMENT_ARRAY_BUFFER,
        0,
        geom_indices_to_render.count * size_of(u32),
        geom_indices_to_render.data,
    );
    gl_draw_indexed_vertices_from_bound_vertex_array(
        GL_TRIANGLES,
        xx geom_indices_to_render.count,
        GL_UNSIGNED_INT,
        cast(*void) 0,
    );

    gl_bind_vertex_array(0);
    gl_delete_vertex_array(shadow_vertex_array);
    gl_clear_active_shader_program();
}

bind_directional_shadow_attributes :: (
    shader: GLuint,
    renderer: *Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderer
) {
    local_to_world_location := gl_get_vertex_attribute_location_in_shader_program(
        shader,
        "local_to_world_index",
    );
    if local_to_world_location >= 0 {
        gl_bind_buffer_to_binding_target(GL_ARRAY_BUFFER, renderer.local_to_world_index_buffer_gl_handle);
        gl_enable_vertex_attribute_array(xx local_to_world_location);
        gl_define_integer_vertex_attribute_pointer(
            xx local_to_world_location,
            1,
            GL_UNSIGNED_INT,
            0,
            null,
        );
    }

    position_location := gl_get_vertex_attribute_location_in_shader_program(shader, "position");
    if position_location >= 0 {
        gl_bind_buffer_to_binding_target(GL_ARRAY_BUFFER, renderer.positions_buffer_gl_handle);
        gl_enable_vertex_attribute_array(xx position_location);
        gl_define_vertex_attribute_pointer(
            xx position_location,
            3,
            GL_FLOAT,
            GL_FALSE,
            0,
            null,
        );
    }
}

set_directional_light_uniforms :: (
    shader: GLuint,
    light: Directional_Light,
    shadow_map: *Directional_Shadow_Map
) {
    direction := normalize(light.direction);

    loc := gl_get_uniform_location_in_shader_program(shader, "directional_light.direction");
    gl_set_uniform_3f_on_active_shader_program(loc, direction.x, direction.y, direction.z);

    loc = gl_get_uniform_location_in_shader_program(shader, "directional_light.color");
    gl_set_uniform_3f_on_active_shader_program(loc, light.color.x, light.color.y, light.color.z);

    loc = gl_get_uniform_location_in_shader_program(shader, "directional_light.intensity");
    gl_set_uniform_1f_on_active_shader_program(loc, light.intensity);

    loc = gl_get_uniform_location_in_shader_program(shader, "directional_light.enabled");
    gl_set_uniform_1i_on_active_shader_program(loc, xx light.enabled);

    loc = gl_get_uniform_location_in_shader_program(shader, "directional_shadow_map");
    gl_set_uniform_1i_on_active_shader_program(loc, 3);

    loc = gl_get_uniform_location_in_shader_program(shader, "use_directional_shadow_map");
    gl_set_uniform_1i_on_active_shader_program(loc, xx (light.enabled && light.casts_shadows && shadow_map.initialized));

    loc = gl_get_uniform_location_in_shader_program(shader, "world_to_light_clip");
    gl_set_uniform_matrix_4fv_on_active_shader_program(loc, 1, GL_TRUE, *shadow_map.world_to_light_clip.coef[0][0]);
}
