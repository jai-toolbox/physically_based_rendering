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

read_transformed_texture_coordinates :: (
    gltf: *Gltf_Data,
    primitive: *Gltf_Primitive,
    channel: int,
    transform: Gltf_Texture_Transform,
    vertex_count: int,
) -> [..] Vector2 {
    source := read_primitive_texcoords(gltf, primitive, channel);
    result: [..] Vector2;
    array_resize(*result, vertex_count);

    for i: 0..vertex_count - 1 {
        uv := Vector2.{};
        if i < source.count uv = source[i];

        scaled := uv * transform.scale;
        cosine := cos(transform.rotation);
        sine := sin(transform.rotation);
        result[i] = transform.offset + Vector2.{
            cosine * scaled.x - sine * scaled.y,
            sine * scaled.x + cosine * scaled.y,
        };
    }

    array_free(source);
    return result;
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

    for scene.root_nodes {
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
        punctual_color := light.color;

        if light.light_type == {
            case .POINT;
                position := transform_point(world_transform, .{0, 0, 0});
                _, ok := add_light(pbr, position, punctual_color, light.range, punctual_intensity);
                log("glTF light '%': type=point raw_intensity=% normalized_intensity=% color={%, %, %} position={%, %, %} range=%",
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
                _, ok := add_spot_light(pbr, position, direction, punctual_color, light.inner_cone_angle, light.outer_cone_angle, light.range, punctual_intensity);
                log("glTF light '%': type=spot raw_intensity=% normalized_intensity=% color={%, %, %} position={%, %, %} direction={%, %, %} inner=% outer=% range=%",
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

    for scene.root_nodes {
        load_gltf_lights_recursive(pbr, gltf, it, Matrix4_Identity);
    }
}

// endfold node transform helpers

load_gltf_pbr_packed_texture_model :: (
    gltf: *Gltf_Data,
    metadata: *Packed_Textures_Metadata,
) -> PBR_Packed_Texture_Model {
    result: PBR_Packed_Texture_Model;

    lookup_table := build_packed_texture_lookup_table(metadata);
    defer deinit(*lookup_table);

    mesh_transforms := collect_mesh_transforms(gltf);
    defer array_free(mesh_transforms);

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
        pbr_gltf_log("  Image[%]: uri='%'", img_idx, img.universal_resource_identifier);
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

            model_primitive: PBR_Packed_Texture_Primitive;

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

            mat := get_gltf_material(gltf, prim.material_index);

            base_color_channel := 0;
            normal_channel := 0;
            metallic_roughness_channel := 0;
            ambient_occlusion_channel := 0;
            base_color_transform: Gltf_Texture_Transform;
            normal_transform: Gltf_Texture_Transform;
            metallic_roughness_transform: Gltf_Texture_Transform;
            ambient_occlusion_transform: Gltf_Texture_Transform;
            if mat != null {
                base_color_channel = mat.pbr_metallic_roughness.base_color_texture.texcoord;
                base_color_transform = mat.pbr_metallic_roughness.base_color_texture.transform;
                normal_channel = mat.normal_texture.texcoord;
                normal_transform = mat.normal_texture.transform;
                metallic_roughness_channel = mat.pbr_metallic_roughness.metallic_roughness_texture.texcoord;
                metallic_roughness_transform = mat.pbr_metallic_roughness.metallic_roughness_texture.transform;
                ambient_occlusion_channel = mat.occlusion_texture.texcoord;
                ambient_occlusion_transform = mat.occlusion_texture.transform;
            }

            base_color_texture_coordinates := read_transformed_texture_coordinates(
                gltf, prim, base_color_channel, base_color_transform, positions.count);
            normal_texture_coordinates := read_transformed_texture_coordinates(
                gltf, prim, normal_channel, normal_transform, positions.count);
            metallic_roughness_texture_coordinates := read_transformed_texture_coordinates(
                gltf, prim, metallic_roughness_channel, metallic_roughness_transform, positions.count);
            ambient_occlusion_texture_coordinates := read_transformed_texture_coordinates(
                gltf, prim, ambient_occlusion_channel, ambient_occlusion_transform, positions.count);

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
            if mat != null && mat.normal_texture.texture_index >= 0 {
                /*
                glTF tangents describe the primitive's base UV set, while a
                normal texture may select another set or apply
                KHR_texture_transform. Build the tangent frame from the
                coordinates that actually sample the normal texture.
                */
                tangents = compute_tangents_from_indexed_mesh(
                    positions,
                    normals,
                    normal_texture_coordinates,
                    indices,
                );
                pbr_gltf_log("    Computed % tangents from normal-texture UVs", tangents.count);
            } else if prim.tangent_accessor >= 0 {
                tangents_vec4 := read_accessor_as_vector4_array(gltf, prim.tangent_accessor);
                pbr_gltf_log("    Read % tangents from glTF (vec4)", tangents_vec4.count);
                array_reserve(*tangents, tangents_vec4.count);
                for tangents_vec4 {
                    array_add(*tangents, it);
                }
                array_free(tangents_vec4);
            } else {
                /*
                without a normal texture, the shader's flat tangent-space
                normal resolves to the vertex normal. It only requires a
                valid orthogonal tangent, not an expensive UV solve.
                */
                array_resize(*tangents, positions.count);
                for i: 0..positions.count - 1 {
                    n := normals[i];
                    reference := Vector3.{0, 1, 0};
                    if abs(n.y) > 0.999 reference = .{1, 0, 0};
                    t := normalize(cross(reference, n));
                    tangents[i] = .{t.x, t.y, t.z, 1};
                }
                pbr_gltf_log("    Generated % fallback tangents", tangents.count);
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

            model_primitive.indices = indices;
            model_primitive.positions = positions;
            model_primitive.normals = normals;
            model_primitive.tangents = tangents;

            vertex_count := positions.count;

            array_resize(*model_primitive.texture_coordinates_0, vertex_count);
            array_resize(*model_primitive.texture_coordinates_1, vertex_count);
            for i: 0..vertex_count - 1 {
                base_uv := base_color_texture_coordinates[i];
                normal_uv := normal_texture_coordinates[i];
                mr_uv := metallic_roughness_texture_coordinates[i];
                ao_uv := ambient_occlusion_texture_coordinates[i];
                model_primitive.texture_coordinates_0[i] = .{base_uv.x, base_uv.y, normal_uv.x, normal_uv.y};
                model_primitive.texture_coordinates_1[i] = .{mr_uv.x, mr_uv.y, ao_uv.x, ao_uv.y};
            }
            array_free(base_color_texture_coordinates);
            array_free(normal_texture_coordinates);
            array_free(metallic_roughness_texture_coordinates);
            array_free(ambient_occlusion_texture_coordinates);

            pbr_gltf_log("    Filling renderable: % vertices, % indices", vertex_count, indices.count);

            array_resize(*model_primitive.base_color_texture_bindings, vertex_count);
            array_resize(*model_primitive.normal_texture_bindings, vertex_count);
            array_resize(*model_primitive.metallic_roughness_texture_bindings, vertex_count);
            array_resize(*model_primitive.ambient_occlusion_texture_bindings, vertex_count);
            array_resize(*model_primitive.base_color_factors, vertex_count);
            array_resize(*model_primitive.material_parameters, vertex_count);
            array_resize(*model_primitive.glass_parameters, vertex_count);
            array_resize(*model_primitive.volume_parameters, vertex_count);
            array_resize(*model_primitive.alpha_parameters, vertex_count);

            alpha_mode_for_shader := PBR_ALPHA_MODE_OPAQUE;
            if alpha_mode == .MASK  alpha_mode_for_shader = PBR_ALPHA_MODE_MASK;
            if alpha_mode == .BLEND alpha_mode_for_shader = PBR_ALPHA_MODE_BLEND;

            for i: 0..vertex_count - 1 {
                model_primitive.base_color_factors[i] = base_color_factor;
                model_primitive.material_parameters[i] = material_parameters;
                model_primitive.glass_parameters[i] = glass_parameters;
                model_primitive.volume_parameters[i] = volume_parameters;
                model_primitive.alpha_parameters[i] = .{alpha_mode_for_shader, alpha_cutoff};

                model_primitive.base_color_texture_bindings[i] = .[base_color_container, base_color_meta];
                model_primitive.normal_texture_bindings[i] = .[normal_container, normal_meta];
                model_primitive.metallic_roughness_texture_bindings[i] = .[mr_container, mr_meta];
                model_primitive.ambient_occlusion_texture_bindings[i] = .[ao_container, ao_meta];
            }

            pbr_gltf_log("    Pre-buffer check:");
            pbr_gltf_log("      model_primitive.positions.count = %", model_primitive.positions.count);
            pbr_gltf_log("      model_primitive.normals.count = %", model_primitive.normals.count);
            pbr_gltf_log("      model_primitive.tangents.count = %", model_primitive.tangents.count);
            pbr_gltf_log("      model_primitive.texture_coordinates_0.count = %", model_primitive.texture_coordinates_0.count);
            pbr_gltf_log("      model_primitive.texture_coordinates_1.count = %", model_primitive.texture_coordinates_1.count);
            pbr_gltf_log("      model_primitive.indices.count = %", model_primitive.indices.count);
            pbr_gltf_log("      model_primitive.base_color_texture_bindings.count = %", model_primitive.base_color_texture_bindings.count);

            if model_primitive.positions.count != model_primitive.normals.count
                pbr_gltf_log("      ERROR: positions.count != normals.count");
            if model_primitive.positions.count != model_primitive.tangents.count
                pbr_gltf_log("      ERROR: positions.count != tangents.count");
            if model_primitive.positions.count != model_primitive.texture_coordinates_0.count
                pbr_gltf_log("      ERROR: positions.count != texture_coordinates_0.count");
            if model_primitive.positions.count != model_primitive.texture_coordinates_1.count
                pbr_gltf_log("      ERROR: positions.count != texture_coordinates_1.count");

            model_primitive.local_to_model = mt.world_transform;
            model_primitive.local_center = compute_center(model_primitive.positions);
            model_primitive.is_transparent = alpha_mode == .BLEND || glass_parameters.x > 0.0;

            for position: model_primitive.positions {
                if !model_primitive.has_local_bounds {
                    model_primitive.local_bounds_min = position;
                    model_primitive.local_bounds_max = position;
                    model_primitive.has_local_bounds = true;
                } else {
                    model_primitive.local_bounds_min.x = min(model_primitive.local_bounds_min.x, position.x);
                    model_primitive.local_bounds_min.y = min(model_primitive.local_bounds_min.y, position.y);
                    model_primitive.local_bounds_min.z = min(model_primitive.local_bounds_min.z, position.z);
                    model_primitive.local_bounds_max.x = max(model_primitive.local_bounds_max.x, position.x);
                    model_primitive.local_bounds_max.y = max(model_primitive.local_bounds_max.y, position.y);
                    model_primitive.local_bounds_max.z = max(model_primitive.local_bounds_max.z, position.z);
                }
            }

            array_add(*result.primitives, model_primitive);
        }
    }

    pbr_gltf_log("\n=== DONE: prepared % CPU renderables ===", result.primitives.count);
    return result;
}

pbr_forget_moved_array :: (array: *[..] $T) {
    array.data = null;
    array.count = 0;
    array.allocated = 0;
}

move_pbr_primitive_into_opengl_renderable :: (
    source: *PBR_Packed_Texture_Primitive,
    destination: *Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable,
) {
    destination.indices = source.indices;
    destination.positions = source.positions;
    destination.normals = source.normals;
    destination.tangents = source.tangents;
    destination.texture_coordinates_0 = source.texture_coordinates_0;
    destination.texture_coordinates_1 = source.texture_coordinates_1;
    destination.base_color_factors = source.base_color_factors;
    destination.material_parameters = source.material_parameters;
    destination.glass_parameters = source.glass_parameters;
    destination.volume_parameters = source.volume_parameters;
    destination.alpha_parameters = source.alpha_parameters;
    destination.base_color_texture_bindings = source.base_color_texture_bindings;
    destination.normal_texture_bindings = source.normal_texture_bindings;
    destination.metallic_roughness_texture_bindings = source.metallic_roughness_texture_bindings;
    destination.ambient_occlusion_texture_bindings = source.ambient_occlusion_texture_bindings;

    pbr_forget_moved_array(*source.indices);
    pbr_forget_moved_array(*source.positions);
    pbr_forget_moved_array(*source.normals);
    pbr_forget_moved_array(*source.tangents);
    pbr_forget_moved_array(*source.texture_coordinates_0);
    pbr_forget_moved_array(*source.texture_coordinates_1);
    pbr_forget_moved_array(*source.base_color_factors);
    pbr_forget_moved_array(*source.material_parameters);
    pbr_forget_moved_array(*source.glass_parameters);
    pbr_forget_moved_array(*source.volume_parameters);
    pbr_forget_moved_array(*source.alpha_parameters);
    pbr_forget_moved_array(*source.base_color_texture_bindings);
    pbr_forget_moved_array(*source.normal_texture_bindings);
    pbr_forget_moved_array(*source.metallic_roughness_texture_bindings);
    pbr_forget_moved_array(*source.ambient_occlusion_texture_bindings);
}

install_pbr_packed_texture_model_opengl :: (
    model: *PBR_Packed_Texture_Model,
    renderer: *Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderer,
    opaque_renderables: *[..] Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable,
    transparent_renderables: *[..] Transparent_PBR_Renderable,
    loaded_model: *PBR_Model_Instance = null,
    queued_operations: *GL_Operation_Queue = null,
) -> int {
    installed_count := 0;
    for *primitive: model.primitives {
        renderable: Camera_Per_Object_Transform_Pbr_Packed_Texture_Renderable;
        move_pbr_primitive_into_opengl_renderable(primitive, *renderable);

        if !buffer_object(renderer, *renderable, queued_operations) {
            log_error("Failed to allocate renderer storage for a PBR primitive");
            deinit(*renderable);
            continue;
        }
        set_local_to_world_matrix(renderer, renderable, primitive.local_to_model);

        renderable_index: int;
        if primitive.is_transparent {
            renderable_index = transparent_renderables.count;
            array_add(transparent_renderables, .{
                renderable = renderable,
                sort_position = transform_point(primitive.local_to_model, primitive.local_center),
            });
        } else {
            renderable_index = opaque_renderables.count;
            array_add(opaque_renderables, renderable);
        }

        if loaded_model {
            array_add(*loaded_model.renderables, .{
                is_transparent = primitive.is_transparent,
                index = renderable_index,
                local_to_model = primitive.local_to_model,
                local_center = primitive.local_center,
                local_bounds_min = primitive.local_bounds_min,
                local_bounds_max = primitive.local_bounds_max,
                has_local_bounds = primitive.has_local_bounds,
            });
        }
        installed_count += 1;
    }
    return installed_count;
}

load_gltf_model :: (using ptr: *PBR_Packed_Texture_Rendering, gltf_path: string) {
    gltf := load_gltf(gltf_path);
    defer deinit(*gltf);
    load_gltf_lights(ptr, *gltf);
    model := load_gltf_pbr_packed_texture_model(*gltf, *metadata);
    defer deinit(*model);
    install_pbr_packed_texture_model_opengl(
        *model,
        *renderer,
        *opaque_renderables,
        *transparent_renderables,
    );
}
