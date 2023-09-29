#version 460

layout (location = 0) in vec2 pos;
layout (location = 1) in vec4 color;
layout (location = 2) in uint glyph[3];

layout (location = 0) out vec4 out_color;
layout (location = 1) out uint out_glyph[3];

void main() {
    out_color = color;
    out_glyph = glyph;
    gl_Position = vec4(pos.x, pos.y, 1.0, 1.0);
}
