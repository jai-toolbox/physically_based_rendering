prepare_pbr_render :: (using ptr: *PBR_Packed_Texture_Rendering, camera_position: Vector3) {
    bind_packed_textures(base);
    if has_reflection_cubemap {
        gl_set_active_texture_unit(GL_TEXTURE2);
        gl_bind_texture_to_binding_target_of_active_texture_unit(
            GL_TEXTURE_CUBE_MAP,
            reflection_cubemap.texture_gl_handle,
        );
    }
    if shadow_map.initialized {
        gl_set_active_texture_unit(GL_TEXTURE3);
        gl_bind_texture_to_binding_target_of_active_texture_unit(
            GL_TEXTURE_2D,
            shadow_map.depth_texture_gl_handle,
        );
    }

    shader := renderer.shader_program_gl_handle;
    gl_set_active_shader_program(shader);

    set_camera_position_uniform(*renderer, camera_position);
    set_num_active_lights_uniform(*renderer, num_active_lights);
    set_use_reflection_cubemap_uniform(*renderer, has_reflection_cubemap);
    set_lights_uniform(shader, array_view(lights, 0, num_active_lights));
    spot_count_loc := gl_get_uniform_location_in_shader_program(shader, "num_active_spot_lights");
    gl_set_uniform_1i_on_active_shader_program(spot_count_loc, num_active_spot_lights);
    set_spot_lights_uniform(shader, array_view(spot_lights, 0, num_active_spot_lights));
    set_directional_light_uniforms(shader, directional_light, *shadow_map);
    gl_set_uniform_1i_on_active_shader_program(gl_get_uniform_location_in_shader_program(shader, "debug_render_normals"), xx debug_render_normals);
    gl_set_uniform_1i_on_active_shader_program(gl_get_uniform_location_in_shader_program(shader, "decode_base_color_srgb"), 1);
    gl_set_uniform_1f_on_active_shader_program(gl_get_uniform_location_in_shader_program(shader, "ambient_strength"), ambient_strength);
    world_background_loc := gl_get_uniform_location_in_shader_program(shader, "world_background_color");
    gl_set_uniform_3f_on_active_shader_program(world_background_loc, world_background_color.x, world_background_color.y, world_background_color.z);
    gl_set_uniform_1i_on_active_shader_program(gl_get_uniform_location_in_shader_program(shader, "use_pbr_transparency_resolve"), 0);

    gl_clear_active_shader_program();
}

render_pbr_opaque :: (using ptr: *PBR_Packed_Texture_Rendering, camera_position: Vector3) {
    prepare_pbr_render(ptr, camera_position);

    for opaque_renderables {
        queue_render(*renderer, it);
    }
    render(*renderer);
}

render_pbr_transparent :: (using ptr: *PBR_Packed_Texture_Rendering, camera_position: Vector3) {
    if transparent_renderables.count > 0 {
        prepare_pbr_render(ptr, camera_position);

        sorted: [..] Transparent_PBR_Renderable;
        defer array_free(sorted);
        for transparent_renderables array_add(*sorted, it);

        for i: 1..sorted.count - 1 {
            item := sorted[i];
            item_distance := pbr_sort_distance_squared(camera_position, item.sort_position);
            j := i;
            while j > 0 {
                previous_distance := pbr_sort_distance_squared(camera_position, sorted[j - 1].sort_position);
                if previous_distance >= item_distance break;
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = item;
        }

        gl_enable_blending();
        gl_set_separate_blend_function(GL_ONE, GL_SRC1_COLOR, GL_ONE, GL_SRC1_ALPHA);
        gl_set_depth_writes_enabled(GL_FALSE);
        gl_set_active_shader_program(renderer.shader_program_gl_handle);
        gl_set_uniform_1i_on_active_shader_program(
            gl_get_uniform_location_in_shader_program(renderer.shader_program_gl_handle, "use_pbr_transparency_resolve"),
            1,
        );
        gl_clear_active_shader_program();

        for sorted {
            queue_render(*renderer, it.renderable);
        }
        render(*renderer);

        gl_set_depth_writes_enabled(GL_TRUE);
        gl_set_blend_function(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        gl_disable_blending();
    }
}

render_pbr :: (using ptr: *PBR_Packed_Texture_Rendering, camera_position: Vector3) {
    render_pbr_opaque(ptr, camera_position);
    render_pbr_transparent(ptr, camera_position);
}
