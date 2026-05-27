find_pbr_texture :: (
    lookup_table: *Table(string, Packed_Texture_Lookup),
    path: string,
    channel_name: string
) -> container_index: s32, metadata_index: s32 {
    if path.count == 0 {
        log("  PBR channel '%': no path, using shader default", channel_name);
        return -1, -1;
    }

    found, result := table_find(lookup_table, path);
    if !found {
        log("  PBR channel '%': '%' not found in packed textures", channel_name, path);
        return -1, -1;
    }

    log("  PBR channel '%': '%' -> container=%, metadata=%",
        channel_name, path, result.container_index, result.metadata_index);
    return result.container_index, result.metadata_index;
}

// startfold node transform helpers

compute_node_local_transform :: (node: *Gltf_Node) -> Matrix4 {
    if node.has_matrix return node.matrix;

    t := node.translation;
    r := node.rotation;
    s := node.scale;

    rotation := rotation_matrix(Matrix4, r);

    scale_matrix := Matrix4_Identity;
    scale_matrix.coef[0][0] = s.x;
    scale_matrix.coef[1][1] = s.y;
    scale_matrix.coef[2][2] = s.z;

    translation_matrix := Matrix4_Identity;
    translation_matrix.coef[0][3] = t.x;
    translation_matrix.coef[1][3] = t.y;
    translation_matrix.coef[2][3] = t.z;

    return translation_matrix * rotation * scale_matrix;
}

Mesh_Transform :: struct {
    mesh_index: int;
    world_transform: Matrix4;
}

collect_mesh_transforms_recursive :: (
    gltf: *Gltf_Data,
    node_index: int,
    parent_transform: Matrix4,
    result: *[..] Mesh_Transform
) {
    if node_index < 0 || node_index >= gltf.all_nodes.count return;

    node := *gltf.all_nodes[node_index];
    local_transform := compute_node_local_transform(node);
    world_transform := parent_transform * local_transform;

    if node.mesh_index >= 0 {
        array_add(result, Mesh_Transform.{
            mesh_index = node.mesh_index,
            world_transform = world_transform,
        });
    }

    for node.children {
        collect_mesh_transforms_recursive(gltf, it, world_transform, result);
    }
}

collect_mesh_transforms :: (gltf: *Gltf_Data) -> [..] Mesh_Transform {
    result: [..] Mesh_Transform;

    scene := get_default_scene(gltf);
    if scene == null {
        for node_idx: 0..gltf.all_nodes.count - 1 {
            collect_mesh_transforms_recursive(gltf, node_idx, Matrix4_Identity, *result);
        }
        return result;
    }

    for scene.nodes {
        collect_mesh_transforms_recursive(gltf, it, Matrix4_Identity, *result);
    }

    return result;
}

load_gltf_lights_recursive :: (
    pbr: *PBR_Packed_Texture_Rendering,
    gltf: *Gltf_Data,
    node_index: int,
    parent_transform: Matrix4
) {
    if node_index < 0 || node_index >= gltf.all_nodes.count return;

    node := *gltf.all_nodes[node_index];
    local_transform := compute_node_local_transform(node);
    world_transform := parent_transform * local_transform;

    if node.light_index >= 0 && node.light_index < gltf.all_lights.count {
        light := *gltf.all_lights[node.light_index];
        calibrated_intensity := light.intensity / BLENDER_GLTF_WATTS_TO_LUMENS;
        color := light.color * calibrated_intensity;

        if light.light_type == {
            case .POINT;
                position := transform_point(world_transform, .{0, 0, 0});
                _, ok := add_light(pbr, position, color);
                if ok log("Loaded glTF point light '%' at {%, %, %}", light.name, position.x, position.y, position.z);

            case .SPOT;
                position := transform_point(world_transform, .{0, 0, 0});
                direction := normalize(transform_vector(world_transform, .{0, 0, -1}));
                _, ok := add_spot_light(pbr, position, direction, color, light.inner_cone_angle, light.outer_cone_angle, light.range);
                if ok log("Loaded glTF spot light '%' at {%, %, %}", light.name, position.x, position.y, position.z);

            case .DIRECTIONAL;
                direction := normalize(transform_vector(world_transform, .{0, 0, -1}));
                set_directional_light(pbr, direction, light.color, calibrated_intensity, true);
                log("Loaded glTF directional light '%' direction {%, %, %}", light.name, direction.x, direction.y, direction.z);
        }
    }

    for node.children {
        load_gltf_lights_recursive(pbr, gltf, it, world_transform);
    }
}

load_gltf_lights :: (pbr: *PBR_Packed_Texture_Rendering, gltf: *Gltf_Data) {
    if gltf.all_lights.count == 0 {
        log("glTF has no KHR_lights_punctual lights");
        return;
    }

    scene := get_default_scene(gltf);
    if scene == null {
        for node_idx: 0..gltf.all_nodes.count - 1 {
            load_gltf_lights_recursive(pbr, gltf, node_idx, Matrix4_Identity);
        }
        return;
    }

    for scene.nodes {
        load_gltf_lights_recursive(pbr, gltf, it, Matrix4_Identity);
    }
}

// endfold node transform helpers

load_gltf_into_pbr_packed_texture_renderables :: (
    gltf: *Gltf_Data,
    metadata: *Packed_Textures_Metadata,
    renderer: *Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderer,
    opaque_renderables: *[..] Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable,
    transparent_renderables: *[..] Transparent_PBR_Renderable
) {

    lookup_table := build_packed_texture_lookup_table(metadata);

    mesh_transforms := collect_mesh_transforms(gltf);

    log("=== BEGIN loading glTF into PBR renderables ===");
    log("glTF has % meshes, % materials, % textures, % images",
        gltf.all_meshes.count, gltf.all_materials.count,
        gltf.all_textures.count, gltf.all_images.count);
    log("glTF has % buffers, % buffer views, % accessors",
        gltf.all_buffers.count, gltf.all_buffer_views.count,
        gltf.all_accessors.count);
    log("Found % mesh instances from scene graph", mesh_transforms.count);

    for buf, buf_idx: gltf.all_buffers {
        log("  Buffer[%]: uri='%', byte_length=%, loaded_data.count=%",
            buf_idx, buf.uri, buf.byte_length, buf.loaded_data.count);
    }

    for img, img_idx: gltf.all_images {
        log("  Image[%]: uri='%'", img_idx, img.uri);
    }

    log("Packed texture metadata: % entries, side_length=%",
        metadata.textures.count, metadata.side_length_px);

    for mt: mesh_transforms {
        mesh_idx := mt.mesh_index;
        if mesh_idx < 0 || mesh_idx >= gltf.all_meshes.count continue;

        mesh := *gltf.all_meshes[mesh_idx];
        log("\n--- Mesh[%]: '%', % primitives ---", mesh_idx, mesh.name, mesh.primitives.count);

        for * prim, prim_idx: mesh.primitives {
            log("\n  Primitive[%]:", prim_idx);
            log("    position_accessor=%,  normal_accessor=%,  tangent_accessor=%",
                prim.position_accessor, prim.normal_accessor, prim.tangent_accessor);
            log("    indices_accessor=%,  material_index=%,  mode=%",
                prim.indices_accessor, prim.material_index, prim.mode);
            log("    texcoord_accessors.count=%", prim.texcoord_accessors.count);
            for tc_idx: 0..prim.texcoord_accessors.count - 1 {
                log("      texcoord_accessors[%] = %", tc_idx, prim.texcoord_accessors[tc_idx]);
            }

            if prim.position_accessor >= 0 && prim.position_accessor < gltf.all_accessors.count {
                acc := *gltf.all_accessors[prim.position_accessor];
                log("    Position accessor: buffer_view=%, byte_offset=%, count=%, component_type=%, accessor_type=%",
                    acc.buffer_view_index, acc.byte_offset, acc.count, acc.component_type, acc.accessor_type);
                if acc.buffer_view_index >= 0 && acc.buffer_view_index < gltf.all_buffer_views.count {
                    bv := *gltf.all_buffer_views[acc.buffer_view_index];
                    log("      BufferView: buffer=%, byte_offset=%, byte_length=%, byte_stride=%",
                        bv.buffer_index, bv.byte_offset, bv.byte_length, bv.byte_stride);
                }
            }

            if prim.indices_accessor >= 0 && prim.indices_accessor < gltf.all_accessors.count {
                acc := *gltf.all_accessors[prim.indices_accessor];
                log("    Indices accessor: buffer_view=%, byte_offset=%, count=%, component_type=%, accessor_type=%",
                    acc.buffer_view_index, acc.byte_offset, acc.count, acc.component_type, acc.accessor_type);
                if acc.buffer_view_index >= 0 && acc.buffer_view_index < gltf.all_buffer_views.count {
                    bv := *gltf.all_buffer_views[acc.buffer_view_index];
                    log("      BufferView: buffer=%, byte_offset=%, byte_length=%, byte_stride=%",
                        bv.buffer_index, bv.byte_offset, bv.byte_length, bv.byte_stride);
                }
            }

            renderable: Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable;

            positions := read_accessor_as_vector3_array(gltf, prim.position_accessor);
            log("    Read % positions", positions.count);
            if positions.count == 0 {
                log("    Skipping primitive with no positions");
                continue;
            }
            if positions.count >= 3 {
                log("      positions[0] = {%, %, %}", positions[0].x, positions[0].y, positions[0].z);
                log("      positions[1] = {%, %, %}", positions[1].x, positions[1].y, positions[1].z);
                log("      positions[2] = {%, %, %}", positions[2].x, positions[2].y, positions[2].z);
            }

            all_same_pos := true;
            for i: 1..min(positions.count - 1, 99) {
                if positions[i].x != positions[0].x || positions[i].y != positions[0].y || positions[i].z != positions[0].z {
                    all_same_pos = false;
                    break;
                }
            }
            if all_same_pos log("    WARNING: first 100 positions are ALL IDENTICAL!");

            normals := read_accessor_as_vector3_array(gltf, prim.normal_accessor);
            log("    Read % normals", normals.count);
            if normals.count == 0 {
                array_resize(*normals, positions.count);
                for * normals  it.* = .{0, 1, 0};
                log("    Generated default normals");
            }

            texture_coordinates := read_primitive_texcoords(gltf, prim, 0);
            log("    Read % texture_coordinates", texture_coordinates.count);
            if texture_coordinates.count == 0 {
                array_resize(*texture_coordinates, positions.count);
                for * texture_coordinates  it.* = .{0, 0};
                log("    Generated default UVs");
            }
            if texture_coordinates.count >= 3 {
                log("      uv[0] = {%, %}", texture_coordinates[0].x, texture_coordinates[0].y);
                log("      uv[1] = {%, %}", texture_coordinates[1].x, texture_coordinates[1].y);
                log("      uv[2] = {%, %}", texture_coordinates[2].x, texture_coordinates[2].y);
            }

            indices := read_accessor_as_index_array(gltf, prim.indices_accessor);
            log("    Read % indices", indices.count);
            if indices.count == 0 {
                array_reserve(*indices, positions.count);
                for i: 0..positions.count - 1 {
                    array_add(*indices, cast(u32) i);
                }
                log("    Generated sequential indices");
            }
            if indices.count >= 6 {
                log("      indices[0..5] = %, %, %, %, %, %",
                    indices[0], indices[1], indices[2], indices[3], indices[4], indices[5]);
            }

            max_index: u32 = 0;
            for indices {
                if it > max_index max_index = it;
            }
            log("    Index range: 0 to % (position count = %)", max_index, positions.count);
            if max_index >= cast(u32) positions.count {
                log("    ERROR: max index % exceeds position count %!", max_index, positions.count);
            }

            all_zero_indices := true;
            for indices {
                if it != 0 { all_zero_indices = false; break; }
            }
            if all_zero_indices log("    WARNING: ALL INDICES ARE ZERO!");

            tangents: [..] Vector3;
            if prim.tangent_accessor >= 0 {
                tangents_vec4 := read_accessor_as_vector4_array(gltf, prim.tangent_accessor);
                log("    Read % tangents from glTF (vec4)", tangents_vec4.count);
                array_reserve(*tangents, tangents_vec4.count);
                for tangents_vec4 {
                    array_add(*tangents, .{it.x, it.y, it.z});
                }
            } else {
                tangents = compute_tangents_from_indexed_mesh(positions, texture_coordinates, indices);
                log("    Computed % tangents from geometry", tangents.count);
            }

            base_color_container: s32 = -1;
            base_color_meta: s32 = -1;
            normal_container: s32 = -1;
            normal_meta: s32 = -1;
            mr_container: s32 = -1;
            mr_meta: s32 = -1;
            ao_container: s32 = -1;
            ao_meta: s32 = -1;
            base_color_factor := Vector4.{1, 1, 1, 1};
            alpha_mode := Gltf_Alpha_Mode.OPAQUE;
            alpha_cutoff := 0.5;

            mat := get_gltf_material(gltf, prim.material_index);
            if mat != null {
                log("    Material: '%'", mat.name);
                log("      base_color_texture.texture_index = %", mat.pbr_metallic_roughness.base_color_texture.texture_index);
                log("      metallic_roughness_texture.texture_index = %", mat.pbr_metallic_roughness.metallic_roughness_texture.texture_index);
                log("      normal_texture.texture_index = %", mat.normal_texture.texture_index);
                log("      occlusion_texture.texture_index = %", mat.occlusion_texture.texture_index);
                log("      alpha_mode = %, base_color_factor.a = %", mat.alpha_mode, mat.pbr_metallic_roughness.base_color_factor.w);

                base_color_factor = mat.pbr_metallic_roughness.base_color_factor;
                alpha_mode = mat.alpha_mode;
                alpha_cutoff = mat.alpha_cutoff;

                bc_path := resolve_gltf_image_path(gltf, mat.pbr_metallic_roughness.base_color_texture.texture_index);
                log("      base_color path: '%'", bc_path);
                base_color_container, base_color_meta = find_pbr_texture(*lookup_table, bc_path, "base_color");

                n_path := resolve_gltf_image_path(gltf, mat.normal_texture.texture_index);
                log("      normal path: '%'", n_path);
                normal_container, normal_meta = find_pbr_texture(*lookup_table, n_path, "normal");

                mr_path := resolve_gltf_image_path(gltf, mat.pbr_metallic_roughness.metallic_roughness_texture.texture_index);
                log("      metallic_roughness path: '%'", mr_path);
                mr_container, mr_meta = find_pbr_texture(*lookup_table, mr_path, "metallic_roughness");

                ao_path := resolve_gltf_image_path(gltf, mat.occlusion_texture.texture_index);
                log("      ambient_occlusion path: '%'", ao_path);
                ao_container, ao_meta = find_pbr_texture(*lookup_table, ao_path, "ambient_occlusion");

                log("      Resolved: bc=(%,%), n=(%,%), mr=(%,%), ao=(%,%)",
                    base_color_container, base_color_meta,
                    normal_container, normal_meta,
                    mr_container, mr_meta,
                    ao_container, ao_meta);
            } else {
                log("    No material for this primitive");
            }

            remapped_uvs: [..] Vector2;
            array_reserve(*remapped_uvs, texture_coordinates.count);
            for texture_coordinates {
                array_add(*remapped_uvs, remap_uv_to_packed_space(it, metadata, base_color_meta));
            }
            if remapped_uvs.count >= 3 {
                log("    Remapped uv[0] = {%, %}", remapped_uvs[0].x, remapped_uvs[0].y);
                log("    Remapped uv[1] = {%, %}", remapped_uvs[1].x, remapped_uvs[1].y);
                log("    Remapped uv[2] = {%, %}", remapped_uvs[2].x, remapped_uvs[2].y);
            }

            renderable.indices = indices;
            renderable.positions = positions;
            renderable.normals = normals;
            renderable.tangents = tangents;
            renderable.texture_coordinates = remapped_uvs;

            vertex_count := positions.count;

            log("    Filling renderable: % vertices, % indices", vertex_count, indices.count);

            array_resize(*renderable.packed_texture_index_for_base_color, vertex_count);
            array_resize(*renderable.packed_texture_bounding_box_index_for_base_color, vertex_count);
            array_resize(*renderable.packed_texture_index_for_normal, vertex_count);
            array_resize(*renderable.packed_texture_bounding_box_index_for_normal, vertex_count);
            array_resize(*renderable.packed_texture_index_for_metallic_roughness, vertex_count);
            array_resize(*renderable.packed_texture_bounding_box_index_for_metallic_roughness, vertex_count);
            array_resize(*renderable.packed_texture_index_for_ambient_occlusion, vertex_count);
            array_resize(*renderable.packed_texture_bounding_box_index_for_ambient_occlusion, vertex_count);
            array_resize(*renderable.base_color_factors, vertex_count);
            array_resize(*renderable.alpha_parameters, vertex_count);

            alpha_mode_for_shader := PBR_ALPHA_MODE_OPAQUE;
            if alpha_mode == .MASK  alpha_mode_for_shader = PBR_ALPHA_MODE_MASK;
            if alpha_mode == .BLEND alpha_mode_for_shader = PBR_ALPHA_MODE_BLEND;

            for i: 0..vertex_count - 1 {
                renderable.base_color_factors[i] = base_color_factor;
                renderable.alpha_parameters[i] = .{alpha_mode_for_shader, alpha_cutoff};

                renderable.packed_texture_index_for_base_color[i] = base_color_container;
                renderable.packed_texture_bounding_box_index_for_base_color[i] = base_color_meta;

                renderable.packed_texture_index_for_normal[i] = normal_container;
                renderable.packed_texture_bounding_box_index_for_normal[i] = normal_meta;

                renderable.packed_texture_index_for_metallic_roughness[i] = mr_container;
                renderable.packed_texture_bounding_box_index_for_metallic_roughness[i] = mr_meta;

                renderable.packed_texture_index_for_ambient_occlusion[i] = ao_container;
                renderable.packed_texture_bounding_box_index_for_ambient_occlusion[i] = ao_meta;
            }

            log("    Pre-buffer check:");
            log("      renderable.positions.count = %", renderable.positions.count);
            log("      renderable.normals.count = %", renderable.normals.count);
            log("      renderable.tangents.count = %", renderable.tangents.count);
            log("      renderable.texture_coordinates.count = %", renderable.texture_coordinates.count);
            log("      renderable.indices.count = %", renderable.indices.count);
            log("      renderable.packed_texture_index_for_base_color.count = %", renderable.packed_texture_index_for_base_color.count);

            if renderable.positions.count != renderable.normals.count
                log("      ERROR: positions.count != normals.count");
            if renderable.positions.count != renderable.tangents.count
                log("      ERROR: positions.count != tangents.count");
            if renderable.positions.count != renderable.texture_coordinates.count
                log("      ERROR: positions.count != texture_coordinates.count");

            local_to_world := mt.world_transform;

            success := buffer_object(renderer, *renderable);
            if !success {
                log_error("    FAILED to buffer PBR primitive from mesh '%'", mesh.name);
            } else {
                log("    Buffered OK: object_index=%, local_to_world_index=%",
                    renderable.object_index, renderable.local_to_world_index);

                set_local_to_world_matrix(renderer, renderable, local_to_world);

            }

            if alpha_mode == .BLEND {
                local_center := compute_center(renderable.positions);
                sort_position := transform_point(local_to_world, local_center);
                array_add(transparent_renderables, .{
                    renderable = renderable,
                    sort_position = sort_position,
                });
            } else {
                array_add(opaque_renderables, renderable);
            }
        }
    }

    log("\n=== DONE: loaded % opaque and % transparent renderables ===", opaque_renderables.count, transparent_renderables.count);
}

load_gltf_model :: (using ptr: *PBR_Packed_Texture_Rendering, gltf_path: string) {
    gltf := load_gltf(gltf_path);
    load_gltf_lights(ptr, *gltf);
    load_gltf_into_pbr_packed_texture_renderables(*gltf, *metadata, *renderer, *opaque_renderables, *transparent_renderables);
}
