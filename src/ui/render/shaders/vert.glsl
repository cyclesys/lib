#version 460

layout (location = 0) in vec2 pos;
layout (location = 1) in vec4 color;
layout (location = 2) in bool is_glyph;
layout (location = 3) in uint glyph[2];

layout (location = 0) out vec4 out_color;
layout (location = 1) out bool out_is_glyph;
layout (location = 2) out uint out_glyph[2];

void main() {
    out_color = color;
    out_is_glyph = is_glyph;
    out_glyph = glyph;
    gl_Position = vec4(pos.x, pos.y, 1.0, 1.0);
}
