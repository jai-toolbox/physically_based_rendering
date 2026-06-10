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
    vertex_shader_loaded, vertex_shader_source := load_asset("data/shaders/out/directional_shadow_depth.vert");
    assert(vertex_shader_loaded, "Failed to load directional shadow vertex shader");
    fragment_shader_loaded, fragment_shader_source := load_asset("data/shaders/out/directional_shadow_depth.frag");
    assert(fragment_shader_loaded, "Failed to load directional shadow fragment shader");

    shadow_shader_program, shader_ok := create_shader_program(vertex_shader_source, fragment_shader_source);
    assert(shader_ok, "Failed to create directional shadow shader");
    shader_program_gl_handle = shadow_shader_program;
    world_to_light_clip_uniform_location = glGetUniformLocation(shader_program_gl_handle, "world_to_light_clip");

    glGenFramebuffers(1, *framebuffer_gl_handle);

    glGenTextures(1, *depth_texture_gl_handle);
    glBindTexture(GL_TEXTURE_2D, depth_texture_gl_handle);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, 0, GL_DEPTH_COMPONENT, GL_FLOAT, null);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);

    border_color := float32.[1.0, 1.0, 1.0, 1.0];
    glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, border_color.data);

    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_gl_handle);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth_texture_gl_handle, 0);
    glDrawBuffer(GL_NONE);
    glReadBuffer(GL_NONE);

    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE {
        log_error("Directional shadow framebuffer is incomplete");
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    initialized = true;
}

render_directional_shadow_map :: (
    using shadow_map: *Directional_Shadow_Map,
    renderer: *Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderer,
    renderables: [] Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable,
    world_to_light_clip_matrix: Matrix4,
    window_width: s32,
    window_height: s32
) {
    if !initialized return;

    world_to_light_clip = world_to_light_clip_matrix;

    glViewport(0, 0, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_gl_handle);
    glClear(GL_DEPTH_BUFFER_BIT);

    glUseProgram(shader_program_gl_handle);
    glUniformMatrix4fv(world_to_light_clip_uniform_location, 1, GL_TRUE, *world_to_light_clip.coef[0][0]);

    upload_to_gpu(*renderer.ltw_pool);

    shadow_vertex_array: GLuint;
    glGenVertexArrays(1, *shadow_vertex_array);
    glBindVertexArray(shadow_vertex_array);
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

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, renderer.index_buffer_gl_handle);
    glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, 0, geom_indices_to_render.count * size_of(u32), geom_indices_to_render.data);
    glDrawElements(GL_TRIANGLES, xx geom_indices_to_render.count, GL_UNSIGNED_INT, cast(*void) 0);

    glBindVertexArray(0);
    glDeleteVertexArrays(1, *shadow_vertex_array);
    glUseProgram(0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDrawBuffer(GL_BACK);
    glReadBuffer(GL_BACK);
    glViewport(0, 0, xx window_width, xx window_height);
}

bind_directional_shadow_attributes :: (
    shader: GLuint,
    renderer: *Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderer
) {
    local_to_world_location := glGetAttribLocation(shader, "local_to_world_index");
    if local_to_world_location >= 0 {
        glBindBuffer(GL_ARRAY_BUFFER, renderer.local_to_world_index_buffer_gl_handle);
        glEnableVertexAttribArray(xx local_to_world_location);
        glVertexAttribIPointer(xx local_to_world_location, 1, GL_UNSIGNED_INT, 0, null);
    }

    position_location := glGetAttribLocation(shader, "position");
    if position_location >= 0 {
        glBindBuffer(GL_ARRAY_BUFFER, renderer.positions_buffer_gl_handle);
        glEnableVertexAttribArray(xx position_location);
        glVertexAttribPointer(xx position_location, 3, GL_FLOAT, GL_FALSE, 0, null);
    }
}

set_directional_light_uniforms :: (
    shader: GLuint,
    light: Directional_Light,
    shadow_map: *Directional_Shadow_Map
) {
    direction := normalize(light.direction);

    loc := glGetUniformLocation(shader, "directional_light.direction");
    glUniform3f(loc, direction.x, direction.y, direction.z);

    loc = glGetUniformLocation(shader, "directional_light.color");
    glUniform3f(loc, light.color.x, light.color.y, light.color.z);

    loc = glGetUniformLocation(shader, "directional_light.intensity");
    glUniform1f(loc, light.intensity);

    loc = glGetUniformLocation(shader, "directional_light.enabled");
    glUniform1i(loc, xx light.enabled);

    loc = glGetUniformLocation(shader, "directional_shadow_map");
    glUniform1i(loc, 3);

    loc = glGetUniformLocation(shader, "use_directional_shadow_map");
    glUniform1i(loc, xx (light.enabled && light.casts_shadows && shadow_map.initialized));

    loc = glGetUniformLocation(shader, "world_to_light_clip");
    glUniformMatrix4fv(loc, 1, GL_TRUE, *shadow_map.world_to_light_clip.coef[0][0]);
}
