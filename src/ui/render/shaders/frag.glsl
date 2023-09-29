#version 460

layout (location = 0) in vec4 color;
layout (location = 1) in flat uint glyph[3];
layout (origin_upper_left) in vec4 gl_FragCoord;

layout (binding = 0) uniform Text {
    float gamma;
} text;
layout (binding = 1) uniform sampler2D atlas;

layout (location = 0) out vec4 out_color;

void main() {
    if (glyph[0] > 0) {
        uint glyph_x = glyph[1];
        uint glyph_y = glyph[2];

        uint quad_x = glyph_x >> 16;
        uint quad_y = glyph_y >> 16;

        int delta_x = int(floor(gl_FragCoord.x)) - int(quad_x);
        int delta_y = int(floor(gl_FragCoord.y)) - int(quad_y);

        uint atlas_x = glyph_x & 0xFFFF;
        uint atlas_y = glyph_y & 0xFFFF;

        int coord_x = int(atlas_x) + delta_x;
        int coord_y = int(atlas_y) + delta_y;

        ivec2 tex_coord = ivec2(coord_x, coord_y);
        float alpha = texelFetch(atlas, tex_coord, 0).r;

        out_color.rgb = color.rgb;
        out_color.a = color.a * pow(alpha, 1.0 / text.gamma);
    } else {
        out_color = color;
    }
}
