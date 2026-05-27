compute_triangle_tangent :: (
    p0: Vector3, p1: Vector3, p2: Vector3,
    uv0: Vector2, uv1: Vector2, uv2: Vector2
) -> Vector3 {
    edge1 := p1 - p0;
    edge2 := p2 - p0;

    delta_uv1 := uv1 - uv0;
    delta_uv2 := uv2 - uv0;

    denom := delta_uv1.x * delta_uv2.y - delta_uv2.x * delta_uv1.y;
    if abs(denom) < 0.000001 return .{1, 0, 0};

    f := 1.0 / denom;

    tangent: Vector3;
    tangent.x = f * (delta_uv2.y * edge1.x - delta_uv1.y * edge2.x);
    tangent.y = f * (delta_uv2.y * edge1.y - delta_uv1.y * edge2.y);
    tangent.z = f * (delta_uv2.y * edge1.z - delta_uv1.y * edge2.z);

    len := length(tangent);
    if len < 0.000001 return .{1, 0, 0};

    return tangent / len;
}

compute_tangents_from_indexed_mesh :: (
    positions: [] Vector3,
    texture_coordinates: [] Vector2,
    indices: [] u32
) -> [..] Vector3 {

    tangents: [..] Vector3;
    array_resize(*tangents, positions.count);
    for * tangents  it.* = .{0, 0, 0};

    tri_count := indices.count / 3;
    for tri: 0..tri_count - 1 {
        i0 := indices[tri * 3 + 0];
        i1 := indices[tri * 3 + 1];
        i2 := indices[tri * 3 + 2];

        tangent := compute_triangle_tangent(
            positions[i0], positions[i1], positions[i2],
            texture_coordinates[i0], texture_coordinates[i1], texture_coordinates[i2]
        );

        tangents[i0] = tangents[i0] + tangent;
        tangents[i1] = tangents[i1] + tangent;
        tangents[i2] = tangents[i2] + tangent;
    }

    for * tangents {
        len := length(it.*);
        if len > 0.000001 {
            it.* = it.* / len;
        } else {
            it.* = .{1, 0, 0};
        }
    }

    return tangents;
}

// startfold UV remapping into packed atlas space

remap_uv_to_packed_space :: (
    tc: Vector2,
    metadata: *Packed_Textures_Metadata,
    metadata_index: s32
) -> Vector2 {
    if metadata_index < 0 return tc;

    side := cast(float) metadata.side_length_px;

    u_min  := cast(float) metadata.textures[metadata_index].top_left_x / side;
    v_min  := cast(float) metadata.textures[metadata_index].top_left_y / side;
    width  := cast(float) metadata.textures[metadata_index].w / side;
    height := cast(float) metadata.textures[metadata_index].h / side;

    v_min = 1.0 - v_min - height;

    result: Vector2;
    result.x = u_min + tc.x * width;
    result.y = v_min + tc.y * height;
    return result;
}

compute_center :: (positions: [] Vector3) -> Vector3 {
    if positions.count == 0 return .{0, 0, 0};

    center: Vector3;
    for positions center += it;
    return center / cast(float) positions.count;
}

transform_point :: (m: Matrix4, p: Vector3) -> Vector3 {
    return .{
        m.coef[0][0] * p.x + m.coef[0][1] * p.y + m.coef[0][2] * p.z + m.coef[0][3],
        m.coef[1][0] * p.x + m.coef[1][1] * p.y + m.coef[1][2] * p.z + m.coef[1][3],
        m.coef[2][0] * p.x + m.coef[2][1] * p.y + m.coef[2][2] * p.z + m.coef[2][3],
    };
}

transform_vector :: (m: Matrix4, v: Vector3) -> Vector3 {
    return .{
        m.coef[0][0] * v.x + m.coef[0][1] * v.y + m.coef[0][2] * v.z,
        m.coef[1][0] * v.x + m.coef[1][1] * v.y + m.coef[1][2] * v.z,
        m.coef[2][0] * v.x + m.coef[2][1] * v.y + m.coef[2][2] * v.z,
    };
}

pbr_sort_distance_squared :: (a: Vector3, b: Vector3) -> float {
    d := a - b;
    return dot(d, d);
}

// endfold UV remapping into packed atlas space
