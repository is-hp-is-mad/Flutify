#version 460 core
#include <flutter/runtime_effect.glsl>
// Converted from the HyperOS engine (libhyper_os_flutter.so) by tools/to_flutter.py.
// Interface changes only; the math below is the engine's spirv-cross output.
#define float16_t float
#define f16vec2 vec2
#define f16vec3 vec3
#define f16vec4 vec4
#define f16mat2 mat2
#define f16mat3 mat3
#define f16mat4 mat4
#define blur_info_sample_radius int(blur_info_sample_radius__f)
#define blur_info_is_self_blur int(blur_info_is_self_blur__f)
uniform vec2 _fl_size;
uniform vec2 blur_info_image_size;
uniform float blur_info_sample_radius__f;
uniform float blur_info_is_self_blur__f;
uniform float blur_info_blur_offset[14];
uniform float blur_info_blur_weight[7];


uniform sampler2D texture_sampler;

out vec4 frag_color;

void main()
{
    highp vec2 v_texture_coords = FlutterFragCoord().xy / _fl_size;
    highp vec2 _37 = vec2(1.0) / blur_info_image_size;
    highp vec4 _124 = vec4(0.0);
    _124 = vec4(0.0);
    for (int _123 = 0; _123 < 7; _123++)
    {
        if (_123 >= blur_info_sample_radius) break;
        highp vec2 _67 = vec2(blur_info_blur_offset[_123], blur_info_blur_offset[_123 + 7]) * _37;
        highp float _73 = blur_info_blur_weight[_123];
        float mp_copy_73 = _73;
        _124 += ((texture(texture_sampler, v_texture_coords + _67) + texture(texture_sampler, v_texture_coords - _67)) * mp_copy_73);
        continue;
    }
    if (blur_info_is_self_blur > 0)
    {
        frag_color = _124;
    }
    else
    {
        frag_color = vec4(_124.xyz, 1.0);
    }
}

