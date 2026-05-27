render_pbr :: (using ptr: *PBR_Packed_Texture_Rendering, camera_position: Vector3) {
    bind_packed_textures(base);
    if has_reflection_cubemap {
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_CUBE_MAP, reflection_cubemap.texture_gl_handle);
    }
    if shadow_map.initialized {
        glActiveTexture(GL_TEXTURE3);
        glBindTexture(GL_TEXTURE_2D, shadow_map.depth_texture_gl_handle);
    }

    shader := renderer.shader_program_gl_handle;
    glUseProgram(shader);

    set_camera_position_uniform(*renderer, camera_position);
    set_num_active_lights_uniform(*renderer, num_active_lights);
    set_use_reflection_cubemap_uniform(*renderer, has_reflection_cubemap);
    set_lights_uniform(shader, array_view(lights, 0, num_active_lights));
    spot_count_loc := glGetUniformLocation(shader, "num_active_spot_lights");
    glUniform1i(spot_count_loc, num_active_spot_lights);
    set_spot_lights_uniform(shader, array_view(spot_lights, 0, num_active_spot_lights));
    set_directional_light_uniforms(shader, directional_light, *shadow_map);

    glUseProgram(0);

    for opaque_renderables {
        queue_render(*renderer, it);
    }
    render(*renderer);

    if transparent_renderables.count > 0 {
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

        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glDepthMask(GL_FALSE);

        for sorted {
            queue_render(*renderer, it.renderable);
        }
        render(*renderer);

        glDepthMask(GL_TRUE);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDisable(GL_BLEND);
    }
}
