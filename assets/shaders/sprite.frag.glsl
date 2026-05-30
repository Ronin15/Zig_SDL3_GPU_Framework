#version 450

layout(set = 2, binding = 0) uniform sampler2D sprite_texture;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(sprite_texture, in_uv) * in_color;
}

