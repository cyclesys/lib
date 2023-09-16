#version 460

layout (location = 0) in vec4 color;
layout (location = 1) in bool is_glyph;
layout (location = 2) in uint glyph[2];
layout (origin_upper_left) in vec4 gl_FragCoord;

layout (binding = 0) uniform float gamma;
layout (binding = 1) uniform gsampler2d glyph_atlas;

layout (location = 0) out vec4 out_color;

void main() {
    if (is_glyph) {
        uint glyph_x = glyph[0];
        uint glyph_y = glyph[1];

        uint quad_x = glyph_x >> 16;
        uint quad_y = glyph_y >> 16;

        int delta_x = int(floor(gl_FragCoord.x)) - quad_x;
        int delta_y = int(floor(gl_FragCoord.y)) - quad_y;

        uint atlas_x = glyph_x & 0xFFFF;
        uint atlas_y = glyph_y & 0xFFFF;

        int coord_x = atlas_x + delta_x;
        int coord_y = atlas_y = delta_y;

        ivec2 tex_coord = ivec2(coord_x, coord_y);
        ivec4 alpha = texelFetch(glyph_atlas, tex_coord).r;

        out_color.rgb = color.rgb;
        out_color.a = color.a * pow(alpha, 1.0 / gamma);
    } else {
        out_color = color;
    }
}
