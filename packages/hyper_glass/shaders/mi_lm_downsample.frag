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
#define downsample_info_downsample_type int(downsample_info_downsample_type__f)
uniform vec2 _fl_size;
uniform vec2 downsample_info_image_size;
uniform float downsample_info_downsample_type__f;
uniform vec2 downsample_info_down_size;


uniform sampler2D texture_sampler;

out vec4 frag_color;

void main()
{
    highp vec2 v_texture_coords = FlutterFragCoord().xy / _fl_size;
    highp vec4 _301 = vec4(0.0);
    if (downsample_info_downsample_type == 0)
    {
        _301 = texture(texture_sampler, v_texture_coords);
    }
    else
    {
        highp vec4 _302 = vec4(0.0);
        if (downsample_info_downsample_type == 1)
        {
            highp vec2 _70 = clamp((v_texture_coords * downsample_info_down_size) - vec2(0.5), vec2(0.0), downsample_info_down_size - vec2(1.0));
            highp vec2 _74 = vec2(1.0) / downsample_info_down_size;
            vec4 _103 = texture(texture_sampler, (_70 + vec2(0.25)) * _74);
            highp vec4 hp_copy_103 = _103;
            vec4 _106 = texture(texture_sampler, (_70 + vec2(0.25, 0.75)) * _74);
            highp vec4 hp_copy_106 = _106;
            _302 = (((hp_copy_103 + hp_copy_106) + texture(texture_sampler, (_70 + vec2(0.75, 0.25)) * _74)) + texture(texture_sampler, (_70 + vec2(0.75)) * _74)) * 0.25;
        }
        else
        {
            highp vec2 _132 = clamp((v_texture_coords * downsample_info_down_size) - vec2(0.5), vec2(0.0), downsample_info_down_size - vec2(1.0));
            highp vec2 _136 = vec2(1.0) / downsample_info_down_size;
            vec4 _145 = texture(texture_sampler, (_132 + vec2(0.125)) * _136);
            highp vec4 hp_copy_145 = _145;
            vec4 _155 = texture(texture_sampler, (_132 + vec2(0.375, 0.125)) * _136);
            highp vec4 hp_copy_155 = _155;
            _302 = (((((((((((((((hp_copy_145 + hp_copy_155) + texture(texture_sampler, (_132 + vec2(0.625, 0.125)) * _136)) + texture(texture_sampler, (_132 + vec2(0.875, 0.125)) * _136)) + texture(texture_sampler, (_132 + vec2(0.125, 0.375)) * _136)) + texture(texture_sampler, (_132 + vec2(0.375)) * _136)) + texture(texture_sampler, (_132 + vec2(0.625, 0.375)) * _136)) + texture(texture_sampler, (_132 + vec2(0.875, 0.375)) * _136)) + texture(texture_sampler, (_132 + vec2(0.125, 0.625)) * _136)) + texture(texture_sampler, (_132 + vec2(0.375, 0.625)) * _136)) + texture(texture_sampler, (_132 + vec2(0.625)) * _136)) + texture(texture_sampler, (_132 + vec2(0.875, 0.625)) * _136)) + texture(texture_sampler, (_132 + vec2(0.125, 0.875)) * _136)) + texture(texture_sampler, (_132 + vec2(0.375, 0.875)) * _136)) + texture(texture_sampler, (_132 + vec2(0.625, 0.875)) * _136)) + texture(texture_sampler, (_132 + vec2(0.875)) * _136)) * 0.0625;
        }
        _301 = _302;
    }
    frag_color = _301;
}

