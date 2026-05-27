LIGHT_POINT_GIZMO_RADIUS :: 0.18;
LIGHT_POINT_GIZMO_LATITUDE_SEGMENTS :: 8;
LIGHT_POINT_GIZMO_LONGITUDE_SEGMENTS :: 16;
LIGHT_SPOT_GIZMO_LENGTH :: 0.8;
LIGHT_SPOT_GIZMO_SEGMENTS :: 24;

light_gizmo_color :: (color: Vector3) -> Vector3 {
    max_component := max(max(color.x, color.y), color.z);
    if max_component <= 0.0 return .{1, 1, 1};
    if max_component <= 1.0 return color;
    return color / max_component;
}

make_point_light_gizmo :: (light: Light) -> Camera_Per_Object_Transform_Color_Renderable {
    renderable: Camera_Per_Object_Transform_Color_Renderable;
    geometry := create_itpc_with_color(
        create_sphere(light.position, LIGHT_POINT_GIZMO_RADIUS, LIGHT_POINT_GIZMO_LATITUDE_SEGMENTS, LIGHT_POINT_GIZMO_LONGITUDE_SEGMENTS),
        light_gizmo_color(light.color)
    );
    assign_geometry(*renderable, geometry);
    return renderable;
}

make_spot_light_gizmo :: (spot_light: Spot_Light) -> Camera_Per_Object_Transform_Color_Renderable {
    renderable: Camera_Per_Object_Transform_Color_Renderable;

    outer_cos := max(spot_light.outer_cos, 0.001);
    outer_sin := sqrt(max(0.0, 1.0 - outer_cos * outer_cos));
    radius := LIGHT_SPOT_GIZMO_LENGTH * outer_sin / outer_cos;
    base_center := spot_light.position + normalize(spot_light.direction) * LIGHT_SPOT_GIZMO_LENGTH;

    geometry := create_itpc_with_color(
        create_cone(spot_light.position, base_center, radius, LIGHT_SPOT_GIZMO_SEGMENTS),
        light_gizmo_color(spot_light.color)
    );
    assign_geometry(*renderable, geometry);
    return renderable;
}

create_light_gizmos :: (using ptr: *PBR_Packed_Texture_Rendering, color_renderer: *Camera_Per_Object_Transform_Color_Renderer) {
    for array_view(lights, 0, num_active_lights) {
        renderable := make_point_light_gizmo(it);
        if buffer_object(color_renderer, *renderable) {
            array_add(*point_light_gizmos, renderable);
        } else {
            deinit(*renderable);
            log("Failed to buffer point light gizmo");
        }
    }

    for array_view(spot_lights, 0, num_active_spot_lights) {
        renderable := make_spot_light_gizmo(it);
        if buffer_object(color_renderer, *renderable) {
            array_add(*spot_light_gizmos, renderable);
        } else {
            deinit(*renderable);
            log("Failed to buffer spot light gizmo");
        }
    }
}

queue_light_gizmos :: (using ptr: *PBR_Packed_Texture_Rendering, color_renderer: *Camera_Per_Object_Transform_Color_Renderer) {
    for point_light_gizmos queue_render(color_renderer, it);
    for spot_light_gizmos queue_render(color_renderer, it);
}

