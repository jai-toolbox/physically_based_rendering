PBR_GLTF_VERBOSE_LOGGING :: false;
PBR_GLTF_BLENDER_EXPORT_INTENSITY_SCALE :: 1.0 / BLENDER_GLTF_WATTS_TO_LUMENS;
PBR_GLTF_PUNCTUAL_LIGHT_INTENSITY_SCALE :: PBR_GLTF_BLENDER_EXPORT_INTENSITY_SCALE;
PBR_GLTF_DIRECTIONAL_LIGHT_INTENSITY_SCALE :: PBR_GLTF_BLENDER_EXPORT_INTENSITY_SCALE;

pbr_gltf_log :: (fmt: string, args: ..Any) #expand {
    #if PBR_GLTF_VERBOSE_LOGGING {
        log(fmt, ..args);
    }
}

find_pbr_texture :: (
    lookup_table: *Table(string, Packed_Texture_Lookup),
    path: string,
    channel_name: string
) -> container_index: s32, metadata_index: s32 {
    if path.count == 0 {
        pbr_gltf_log("  PBR channel '%': no path, using shader default", channel_name);
        return -1, -1;
    }

    found, result := table_find(lookup_table, path);
    if !found {
        pbr_gltf_log("  PBR channel '%': '%' not found in packed textures", channel_name, path);
        return -1, -1;
    }

    pbr_gltf_log("  PBR channel '%': '%' -> container=%, metadata=%",
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
        punctual_intensity := light.intensity * PBR_GLTF_PUNCTUAL_LIGHT_INTENSITY_SCALE;
        punctual_color := light.color * punctual_intensity;

        if light.light_type == {
            case .POINT;
                position := transform_point(world_transform, .{0, 0, 0});
                _, ok := add_light(pbr, position, punctual_color);
                log("glTF light '%': type=point raw_intensity=% normalized_intensity=% uploaded_color={%, %, %} position={%, %, %} range=%",
                    light.name,
                    light.intensity,
                    punctual_intensity,
                    punctual_color.x, punctual_color.y, punctual_color.z,
                    position.x, position.y, position.z,
                    light.range);
                if ok pbr_gltf_log("Loaded glTF point light '%' at {%, %, %}", light.name, position.x, position.y, position.z);

            case .SPOT;
                position := transform_point(world_transform, .{0, 0, 0});
                direction := normalize(transform_vector(world_transform, .{0, 0, -1}));
                _, ok := add_spot_light(pbr, position, direction, punctual_color, light.inner_cone_angle, light.outer_cone_angle, light.range);
                log("glTF light '%': type=spot raw_intensity=% normalized_intensity=% uploaded_color={%, %, %} position={%, %, %} direction={%, %, %} inner=% outer=% range=%",
                    light.name,
                    light.intensity,
                    punctual_intensity,
                    punctual_color.x, punctual_color.y, punctual_color.z,
                    position.x, position.y, position.z,
                    direction.x, direction.y, direction.z,
                    light.inner_cone_angle, light.outer_cone_angle,
                    light.range);
                if ok pbr_gltf_log("Loaded glTF spot light '%' at {%, %, %}", light.name, position.x, position.y, position.z);

            case .DIRECTIONAL;
                direction := normalize(transform_vector(world_transform, .{0, 0, -1}));
                directional_intensity := light.intensity * PBR_GLTF_DIRECTIONAL_LIGHT_INTENSITY_SCALE;
                set_directional_light(pbr, direction, light.color, directional_intensity, true);
                log("glTF light '%': type=directional raw_intensity=% normalized_intensity=% uploaded_color={%, %, %} direction={%, %, %}",
                    light.name,
                    light.intensity,
                    directional_intensity,
                    light.color.x, light.color.y, light.color.z,
                    direction.x, direction.y, direction.z);
                pbr_gltf_log("Loaded glTF directional light '%' direction {%, %, %}", light.name, direction.x, direction.y, direction.z);
        }
    }

    for node.children {
        load_gltf_lights_recursive(pbr, gltf, it, world_transform);
    }
}

load_gltf_lights :: (pbr: *PBR_Packed_Texture_Rendering, gltf: *Gltf_Data) {
    if gltf.all_lights.count == 0 {
        pbr_gltf_log("glTF has no KHR_lights_punctual lights");
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
    transparent_renderables: *[..] Transparent_PBR_Renderable,
    loaded_model: *PBR_Model_Instance = null
) {

    lookup_table := build_packed_texture_lookup_table(metadata);

    mesh_transforms := collect_mesh_transforms(gltf);

    pbr_gltf_log("=== BEGIN loading glTF into PBR renderables ===");
    pbr_gltf_log("glTF has % meshes, % materials, % textures, % images",
        gltf.all_meshes.count, gltf.all_materials.count,
        gltf.all_textures.count, gltf.all_images.count);
    pbr_gltf_log("glTF has % buffers, % buffer views, % accessors",
        gltf.all_buffers.count, gltf.all_buffer_views.count,
        gltf.all_accessors.count);
    pbr_gltf_log("Found % mesh instances from scene graph", mesh_transforms.count);

    for buf, buf_idx: gltf.all_buffers {
        pbr_gltf_log("  Buffer[%]: uri='%', byte_length=%, loaded_data.count=%",
            buf_idx, buf.uri, buf.byte_length, buf.loaded_data.count);
    }

    for img, img_idx: gltf.all_images {
        pbr_gltf_log("  Image[%]: uri='%'", img_idx, img.uri);
    }

    pbr_gltf_log("Packed texture metadata: % entries, side_length=%",
        metadata.textures.count, metadata.side_length_px);

    for mt: mesh_transforms {
        mesh_idx := mt.mesh_index;
        if mesh_idx < 0 || mesh_idx >= gltf.all_meshes.count continue;

        mesh := *gltf.all_meshes[mesh_idx];
        pbr_gltf_log("\n--- Mesh[%]: '%', % primitives ---", mesh_idx, mesh.name, mesh.primitives.count);

        for * prim, prim_idx: mesh.primitives {
            pbr_gltf_log("\n  Primitive[%]:", prim_idx);
            pbr_gltf_log("    position_accessor=%,  normal_accessor=%,  tangent_accessor=%",
                prim.position_accessor, prim.normal_accessor, prim.tangent_accessor);
            pbr_gltf_log("    indices_accessor=%,  material_index=%,  mode=%",
                prim.indices_accessor, prim.material_index, prim.mode);
            pbr_gltf_log("    texcoord_accessors.count=%", prim.texcoord_accessors.count);
            for tc_idx: 0..prim.texcoord_accessors.count - 1 {
                pbr_gltf_log("      texcoord_accessors[%] = %", tc_idx, prim.texcoord_accessors[tc_idx]);
            }

            if prim.position_accessor >= 0 && prim.position_accessor < gltf.all_accessors.count {
                acc := *gltf.all_accessors[prim.position_accessor];
                pbr_gltf_log("    Position accessor: buffer_view=%, byte_offset=%, count=%, component_type=%, accessor_type=%",
                    acc.buffer_view_index, acc.byte_offset, acc.count, acc.component_type, acc.accessor_type);
                if acc.buffer_view_index >= 0 && acc.buffer_view_index < gltf.all_buffer_views.count {
                    bv := *gltf.all_buffer_views[acc.buffer_view_index];
                    pbr_gltf_log("      BufferView: buffer=%, byte_offset=%, byte_length=%, byte_stride=%",
                        bv.buffer_index, bv.byte_offset, bv.byte_length, bv.byte_stride);
                }
            }

            if prim.indices_accessor >= 0 && prim.indices_accessor < gltf.all_accessors.count {
                acc := *gltf.all_accessors[prim.indices_accessor];
                pbr_gltf_log("    Indices accessor: buffer_view=%, byte_offset=%, count=%, component_type=%, accessor_type=%",
                    acc.buffer_view_index, acc.byte_offset, acc.count, acc.component_type, acc.accessor_type);
                if acc.buffer_view_index >= 0 && acc.buffer_view_index < gltf.all_buffer_views.count {
                    bv := *gltf.all_buffer_views[acc.buffer_view_index];
                    pbr_gltf_log("      BufferView: buffer=%, byte_offset=%, byte_length=%, byte_stride=%",
                        bv.buffer_index, bv.byte_offset, bv.byte_length, bv.byte_stride);
                }
            }

            renderable: Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable;

            positions := read_accessor_as_vector3_array(gltf, prim.position_accessor);
            pbr_gltf_log("    Read % positions", positions.count);
            if positions.count == 0 {
                pbr_gltf_log("    Skipping primitive with no positions");
                continue;
            }
            if positions.count >= 3 {
                pbr_gltf_log("      positions[0] = {%, %, %}", positions[0].x, positions[0].y, positions[0].z);
                pbr_gltf_log("      positions[1] = {%, %, %}", positions[1].x, positions[1].y, positions[1].z);
                pbr_gltf_log("      positions[2] = {%, %, %}", positions[2].x, positions[2].y, positions[2].z);
            }

            all_same_pos := true;
            for i: 1..min(positions.count - 1, 99) {
                if positions[i].x != positions[0].x || positions[i].y != positions[0].y || positions[i].z != positions[0].z {
                    all_same_pos = false;
                    break;
                }
            }
            if all_same_pos pbr_gltf_log("    WARNING: first 100 positions are ALL IDENTICAL!");

            normals := read_accessor_as_vector3_array(gltf, prim.normal_accessor);
            pbr_gltf_log("    Read % normals", normals.count);
            if normals.count == 0 {
                array_resize(*normals, positions.count);
                for * normals  it.* = .{0, 1, 0};
                pbr_gltf_log("    Generated default normals");
            }

            texture_coordinates := read_primitive_texcoords(gltf, prim, 0);
            pbr_gltf_log("    Read % texture_coordinates", texture_coordinates.count);
            if texture_coordinates.count == 0 {
                array_resize(*texture_coordinates, positions.count);
                for * texture_coordinates  it.* = .{0, 0};
                pbr_gltf_log("    Generated default UVs");
            }
            if texture_coordinates.count >= 3 {
                pbr_gltf_log("      uv[0] = {%, %}", texture_coordinates[0].x, texture_coordinates[0].y);
                pbr_gltf_log("      uv[1] = {%, %}", texture_coordinates[1].x, texture_coordinates[1].y);
                pbr_gltf_log("      uv[2] = {%, %}", texture_coordinates[2].x, texture_coordinates[2].y);
            }

            indices := read_accessor_as_index_array(gltf, prim.indices_accessor);
            pbr_gltf_log("    Read % indices", indices.count);
            if indices.count == 0 {
                array_reserve(*indices, positions.count);
                for i: 0..positions.count - 1 {
                    array_add(*indices, cast(u32) i);
                }
                pbr_gltf_log("    Generated sequential indices");
            }
            if indices.count >= 6 {
                pbr_gltf_log("      indices[0..5] = %, %, %, %, %, %",
                    indices[0], indices[1], indices[2], indices[3], indices[4], indices[5]);
            }

            max_index: u32 = 0;
            for indices {
                if it > max_index max_index = it;
            }
            pbr_gltf_log("    Index range: 0 to % (position count = %)", max_index, positions.count);
            if max_index >= cast(u32) positions.count {
                pbr_gltf_log("    ERROR: max index % exceeds position count %!", max_index, positions.count);
            }

            all_zero_indices := true;
            for indices {
                if it != 0 { all_zero_indices = false; break; }
            }
            if all_zero_indices pbr_gltf_log("    WARNING: ALL INDICES ARE ZERO!");

            tangents: [..] Vector4;
            if prim.tangent_accessor >= 0 {
                tangents_vec4 := read_accessor_as_vector4_array(gltf, prim.tangent_accessor);
                pbr_gltf_log("    Read % tangents from glTF (vec4)", tangents_vec4.count);
                array_reserve(*tangents, tangents_vec4.count);
                for tangents_vec4 {
                    array_add(*tangents, it);
                }
            } else {
                tangent_result := compute_tangents_from_indexed_triangles(positions, normals, texture_coordinates, indices);
                tangents = tangent_result.tangents;
                array_free(tangent_result.valid);
                pbr_gltf_log("    Computed % tangents from geometry", tangents.count);
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
            material_parameters := Vector4.{1, 1, 1, 1};
            glass_parameters := Vector4.{0, 1.5, 0, 0};
            volume_parameters := Vector4.{1, 1, 1, 1000000.0};
            alpha_mode := Gltf_Alpha_Mode.OPAQUE;
            alpha_cutoff := 0.5;

            mat := get_gltf_material(gltf, prim.material_index);
            if mat != null {
                pbr_gltf_log("    Material: '%'", mat.name);
                pbr_gltf_log("      base_color_texture.texture_index = %", mat.pbr_metallic_roughness.base_color_texture.texture_index);
                pbr_gltf_log("      metallic_roughness_texture.texture_index = %", mat.pbr_metallic_roughness.metallic_roughness_texture.texture_index);
                pbr_gltf_log("      normal_texture.texture_index = %", mat.normal_texture.texture_index);
                pbr_gltf_log("      occlusion_texture.texture_index = %", mat.occlusion_texture.texture_index);
                pbr_gltf_log("      alpha_mode = %, base_color_factor.a = %", mat.alpha_mode, mat.pbr_metallic_roughness.base_color_factor.w);
                pbr_gltf_log("      glass: transmission=%, ior=%, thickness=%", mat.transmission_factor, mat.ior, mat.thickness_factor);

                base_color_factor = mat.pbr_metallic_roughness.base_color_factor;
                material_parameters = .{
                    mat.pbr_metallic_roughness.metallic_factor,
                    mat.pbr_metallic_roughness.roughness_factor,
                    mat.normal_texture.scale,
                    mat.occlusion_texture.strength,
                };
                glass_parameters = .{
                    mat.transmission_factor,
                    mat.ior,
                    mat.thickness_factor,
                    0,
                };
                volume_parameters = .{
                    mat.attenuation_color.x,
                    mat.attenuation_color.y,
                    mat.attenuation_color.z,
                    mat.attenuation_distance,
                };
                alpha_mode = mat.alpha_mode;
                alpha_cutoff = mat.alpha_cutoff;

                bc_path := resolve_gltf_image_path(gltf, mat.pbr_metallic_roughness.base_color_texture.texture_index);
                pbr_gltf_log("      base_color path: '%'", bc_path);
                base_color_container, base_color_meta = find_pbr_texture(*lookup_table, bc_path, "base_color");

                n_path := resolve_gltf_image_path(gltf, mat.normal_texture.texture_index);
                pbr_gltf_log("      normal path: '%'", n_path);
                normal_container, normal_meta = find_pbr_texture(*lookup_table, n_path, "normal");

                mr_path := resolve_gltf_image_path(gltf, mat.pbr_metallic_roughness.metallic_roughness_texture.texture_index);
                pbr_gltf_log("      metallic_roughness path: '%'", mr_path);
                mr_container, mr_meta = find_pbr_texture(*lookup_table, mr_path, "metallic_roughness");

                ao_path := resolve_gltf_image_path(gltf, mat.occlusion_texture.texture_index);
                pbr_gltf_log("      ambient_occlusion path: '%'", ao_path);
                ao_container, ao_meta = find_pbr_texture(*lookup_table, ao_path, "ambient_occlusion");
                if ao_container < 0 {
                    material_parameters.w = 0.0;
                }

                pbr_gltf_log("      Resolved: bc=(%,%), n=(%,%), mr=(%,%), ao=(%,%)",
                    base_color_container, base_color_meta,
                    normal_container, normal_meta,
                    mr_container, mr_meta,
                    ao_container, ao_meta);
            } else {
                pbr_gltf_log("    No material for this primitive");
            }

            renderable.indices = indices;
            renderable.positions = positions;
            renderable.normals = normals;
            renderable.tangents = tangents;
            renderable.texture_coordinates = texture_coordinates;

            vertex_count := positions.count;

            pbr_gltf_log("    Filling renderable: % vertices, % indices", vertex_count, indices.count);

            array_resize(*renderable.packed_texture_index_for_base_color, vertex_count);
            array_resize(*renderable.packed_texture_bounding_box_index_for_base_color, vertex_count);
            array_resize(*renderable.packed_texture_index_for_normal, vertex_count);
            array_resize(*renderable.packed_texture_bounding_box_index_for_normal, vertex_count);
            array_resize(*renderable.packed_texture_index_for_metallic_roughness, vertex_count);
            array_resize(*renderable.packed_texture_bounding_box_index_for_metallic_roughness, vertex_count);
            array_resize(*renderable.packed_texture_index_for_ambient_occlusion, vertex_count);
            array_resize(*renderable.packed_texture_bounding_box_index_for_ambient_occlusion, vertex_count);
            array_resize(*renderable.base_color_factors, vertex_count);
            array_resize(*renderable.material_parameters, vertex_count);
            array_resize(*renderable.glass_parameters, vertex_count);
            array_resize(*renderable.volume_parameters, vertex_count);
            array_resize(*renderable.alpha_parameters, vertex_count);

            alpha_mode_for_shader := PBR_ALPHA_MODE_OPAQUE;
            if alpha_mode == .MASK  alpha_mode_for_shader = PBR_ALPHA_MODE_MASK;
            if alpha_mode == .BLEND alpha_mode_for_shader = PBR_ALPHA_MODE_BLEND;

            for i: 0..vertex_count - 1 {
                renderable.base_color_factors[i] = base_color_factor;
                renderable.material_parameters[i] = material_parameters;
                renderable.glass_parameters[i] = glass_parameters;
                renderable.volume_parameters[i] = volume_parameters;
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

            pbr_gltf_log("    Pre-buffer check:");
            pbr_gltf_log("      renderable.positions.count = %", renderable.positions.count);
            pbr_gltf_log("      renderable.normals.count = %", renderable.normals.count);
            pbr_gltf_log("      renderable.tangents.count = %", renderable.tangents.count);
            pbr_gltf_log("      renderable.texture_coordinates.count = %", renderable.texture_coordinates.count);
            pbr_gltf_log("      renderable.indices.count = %", renderable.indices.count);
            pbr_gltf_log("      renderable.packed_texture_index_for_base_color.count = %", renderable.packed_texture_index_for_base_color.count);

            if renderable.positions.count != renderable.normals.count
                pbr_gltf_log("      ERROR: positions.count != normals.count");
            if renderable.positions.count != renderable.tangents.count
                pbr_gltf_log("      ERROR: positions.count != tangents.count");
            if renderable.positions.count != renderable.texture_coordinates.count
                pbr_gltf_log("      ERROR: positions.count != texture_coordinates.count");

            local_to_world := mt.world_transform;

            success := buffer_object(renderer, *renderable);
            if !success {
                log_error("    FAILED to buffer PBR primitive from mesh '%'", mesh.name);
            } else {
                pbr_gltf_log("    Buffered OK: object_index=%, local_to_world_index=%",
                    renderable.object_index, renderable.local_to_world_index);

                set_local_to_world_matrix(renderer, renderable, local_to_world);

            }

            local_center := compute_center(renderable.positions);
            if alpha_mode == .BLEND || glass_parameters.x > 0.0 {
                local_center := compute_center(renderable.positions);
                sort_position := transform_point(local_to_world, local_center);
                model_index := transparent_renderables.count;
                array_add(transparent_renderables, .{
                    renderable = renderable,
                    sort_position = sort_position,
                });

                if loaded_model {
                    array_add(*loaded_model.renderables, .{
                        is_transparent = true,
                        index = model_index,
                        local_to_model = local_to_world,
                        local_center = local_center,
                    });
                }
            } else {
                model_index := opaque_renderables.count;
                array_add(opaque_renderables, renderable);
                if loaded_model {
                    array_add(*loaded_model.renderables, .{
                        is_transparent = false,
                        index = model_index,
                        local_to_model = local_to_world,
                        local_center = local_center,
                    });
                }
            }
        }
    }

    pbr_gltf_log("\n=== DONE: loaded % opaque and % transparent renderables ===", opaque_renderables.count, transparent_renderables.count);
}

load_gltf_model_instance :: (using ptr: *PBR_Packed_Texture_Rendering, gltf_path: string) -> PBR_Model_Instance {
    result: PBR_Model_Instance;
    gltf := load_gltf(gltf_path);
    load_gltf_lights(ptr, *gltf);
    load_gltf_into_pbr_packed_texture_renderables(*gltf, *metadata, *renderer, *opaque_renderables, *transparent_renderables, *result);
    return result;
}

load_gltf_model :: (using ptr: *PBR_Packed_Texture_Rendering, gltf_path: string) {
    _ := load_gltf_model_instance(ptr, gltf_path);
}
