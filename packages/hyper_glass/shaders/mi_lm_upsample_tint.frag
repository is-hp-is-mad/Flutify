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
#define hdr_info_enable_hdr int(hdr_info_enable_hdr__f)
#define glass_tint_enabled int(glass_tint_enabled__f)
uniform vec2 _fl_size;
uniform float _fl_out_pass;
uniform float hdr_info_enable_hdr__f;
uniform mat4 hdr_info_srcTF;
uniform mat4 hdr_info_destTF;
uniform mat4 hdr_info_gamutTransform;
uniform vec4 glass_tint_luminance_coeffs;
uniform vec4 glass_tint_glass_color;
uniform vec2 glass_tint_darker_range;
uniform float glass_tint_enabled__f;
uniform float glass_tint_bg_color_sat;
uniform float glass_tint_bg_color_bri;
uniform float glass_tint_luminance_amount;
uniform float glass_tint_saturation;
uniform float glass_tint_brightness;
uniform float glass_tint_inner_color_white;
uniform float glass_tint_inner_color_mix;
uniform float glass_tint_burn;
uniform float glass_tint_darker;
uniform float upsample_info_noise_coeff;
uniform vec2 upsample_info_output_size;
uniform float upsample_info_downsample_scale;

vec4 _1473 = vec4(0.0);




uniform sampler2D big_blur_sampler;
uniform sampler2D texture_sampler;

out vec4 frag_color;

void main()
{
    highp vec2 v_texture_coords = FlutterFragCoord().xy / _fl_size;
    vec4 _580 = texture(texture_sampler, v_texture_coords);
    highp vec4 _1467 = vec4(0.0);
    if (hdr_info_enable_hdr == 1)
    {
        float _680 = _580.x;
        highp float hp_copy_680 = _680;
        highp float _750 = abs(hp_copy_680);
        highp float _1454 = 0.0;
        if (_750 < hdr_info_srcTF[1].x)
        {
            _1454 = (hdr_info_srcTF[0].w * _750) + hdr_info_srcTF[1].z;
        }
        else
        {
            _1454 = pow((hdr_info_srcTF[0].y * _750) + hdr_info_srcTF[0].z, hdr_info_srcTF[0].x) + hdr_info_srcTF[1].y;
        }
        float _684 = _580.y;
        highp float hp_copy_684 = _684;
        highp float _803 = abs(hp_copy_684);
        highp float _1457 = 0.0;
        if (_803 < hdr_info_srcTF[1].x)
        {
            _1457 = (hdr_info_srcTF[0].w * _803) + hdr_info_srcTF[1].z;
        }
        else
        {
            _1457 = pow((hdr_info_srcTF[0].y * _803) + hdr_info_srcTF[0].z, hdr_info_srcTF[0].x) + hdr_info_srcTF[1].y;
        }
        float _688 = _580.z;
        highp float hp_copy_688 = _688;
        highp float _856 = abs(hp_copy_688);
        highp float _1459 = 0.0;
        if (_856 < hdr_info_srcTF[1].x)
        {
            _1459 = (hdr_info_srcTF[0].w * _856) + hdr_info_srcTF[1].z;
        }
        else
        {
            _1459 = pow((hdr_info_srcTF[0].y * _856) + hdr_info_srcTF[0].z, hdr_info_srcTF[0].x) + hdr_info_srcTF[1].y;
        }
        highp vec3 _702 = mat3(hdr_info_gamutTransform[0].xyz, hdr_info_gamutTransform[1].xyz, hdr_info_gamutTransform[2].xyz) * vec3(sign(hp_copy_680) * _1454, sign(hp_copy_684) * _1457, sign(hp_copy_688) * _1459);
        highp float _704 = _702.x;
        highp float _909 = abs(_704);
        highp float _1461 = 0.0;
        if (_909 < hdr_info_destTF[1].x)
        {
            _1461 = (hdr_info_destTF[0].w * _909) + hdr_info_destTF[1].z;
        }
        else
        {
            _1461 = pow((hdr_info_destTF[0].y * _909) + hdr_info_destTF[0].z, hdr_info_destTF[0].x) + hdr_info_destTF[1].y;
        }
        highp float _708 = _702.y;
        highp float _962 = abs(_708);
        highp float _1463 = 0.0;
        if (_962 < hdr_info_destTF[1].x)
        {
            _1463 = (hdr_info_destTF[0].w * _962) + hdr_info_destTF[1].z;
        }
        else
        {
            _1463 = pow((hdr_info_destTF[0].y * _962) + hdr_info_destTF[0].z, hdr_info_destTF[0].x) + hdr_info_destTF[1].y;
        }
        highp float _712 = _702.z;
        highp float _1015 = abs(_712);
        highp float _1465 = 0.0;
        if (_1015 < hdr_info_destTF[1].x)
        {
            _1465 = (hdr_info_destTF[0].w * _1015) + hdr_info_destTF[1].z;
        }
        else
        {
            _1465 = pow((hdr_info_destTF[0].y * _1015) + hdr_info_destTF[0].z, hdr_info_destTF[0].x) + hdr_info_destTF[1].y;
        }
        _1467 = vec4(sign(_704) * _1461, sign(_708) * _1463, sign(_712) * _1465, _580.w);
    }
    else
    {
        _1467 = _580;
    }
    highp vec4 _1468 = vec4(0.0);
    if (glass_tint_enabled != 0)
    {
        highp vec3 _1215 = mix(_1467.xyz, vec3(0.07874000072479248046875, 0.028480000793933868408203125, 0.092780001461505889892578125), vec3(glass_tint_darker * smoothstep(glass_tint_darker_range.x, glass_tint_darker_range.y, dot(_1467.xyz, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875)))));
        highp vec4 _1401 = vec4(0.0);
        _1401.x = _1215.x;
        _1401.y = _1215.y;
        _1401.z = _1215.z;
        highp float _1227 = max(_1467.w, 9.9999997473787516355514526367188e-05);
        highp float _1233 = clamp(dot(_1401.xyz, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875)) / _1227, 0.0, 1.0);
        highp vec3 _1275 = vec4(mix(_1401.xyz, vec3(clamp((((((_1233 * glass_tint_luminance_coeffs.x) + glass_tint_luminance_coeffs.y) * _1233) + glass_tint_luminance_coeffs.z) * _1233) + glass_tint_luminance_coeffs.w, 0.0, 1.0) * _1227), vec3(glass_tint_luminance_amount)), _1467.w).xyz;
        highp vec3 _1293 = ((_1275 * glass_tint_saturation) + (vec3(dot(_1275, vec3(0.2125000059604644775390625, 0.715300023555755615234375, 0.07209999859333038330078125))) * (1.0 - glass_tint_saturation))) + vec3(glass_tint_brightness * _1467.w);
        highp vec4 _1415 = vec4(0.0);
        _1415.x = _1293.x;
        _1415.y = _1293.y;
        _1415.z = _1293.z;
        vec4 _1094 = texture(big_blur_sampler, v_texture_coords);
        vec3 _1096 = _1094.xyz;
        highp vec3 _1317 = mix(_1096, vec3(0.07874000072479248046875, 0.028480000793933868408203125, 0.092780001461505889892578125), vec3(glass_tint_darker * smoothstep(glass_tint_darker_range.x, glass_tint_darker_range.y, dot(_1096, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875)))));
        highp vec4 _1421 = vec4(0.0);
        _1421.x = _1317.x;
        _1421.y = _1317.y;
        _1421.z = _1317.z;
        float _1342 = _1094.w;
        highp vec3 _1115 = mix(vec4(((_1421.xyz * glass_tint_bg_color_sat) + (vec3(dot(_1421.xyz, vec3(0.2125000059604644775390625, 0.715300023555755615234375, 0.07209999859333038330078125))) * (1.0 - glass_tint_bg_color_sat))) + vec3(glass_tint_bg_color_bri * _1342), _1342).xyz, vec3(1.0), vec3(glass_tint_inner_color_white));
        highp vec4 _1429 = vec4(0.0);
        _1429.x = _1115.x;
        _1429.y = _1115.y;
        _1429.z = _1115.z;
        highp float _1125 = clamp(dot(_1429.xyz, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875)), 0.0, 1.0);
        highp float _1130 = pow(_1125, glass_tint_burn) - 0.5;
        highp float _1140 = 0.800000011920928955078125 * mix(_1125, 1.0, (((1.58700001239776611328125 * _1130) * _1130) * _1130) + 0.5);
        highp vec3 _1145 = mix(vec3(1.0), _1429.xyz, vec3(_1140));
        highp vec3 _1151 = vec3(dot(_1145, vec3(0.3333333432674407958984375)));
        highp vec3 _1169 = mix(mix(_1151, _1145, vec3(smoothstep(0.0, 0.4000000059604644775390625, length(_1429.xyz - _1151)))), glass_tint_glass_color.xyz, vec3(glass_tint_glass_color.w));
        highp float _1173 = glass_tint_inner_color_mix * _1140;
        _1468 = vec4(_1169 * mix(_1415.xyz, vec3(1.0), vec3(_1173)), ((1.0 - glass_tint_luminance_amount) * dot(_1169, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))) * (1.0 - _1173));
    }
    else
    {
        _1468 = _1467;
    }
    highp vec4 _1469 = vec4(0.0);
    if (upsample_info_noise_coeff > 0.0)
    {
        highp vec2 _611 = v_texture_coords * upsample_info_output_size;
        highp vec2 _624 = _1468.xy + vec2((fract(sin(dot(_611, vec2(6.989799976348876953125, 78.233001708984375))) * 43734.546875) - 0.5) * upsample_info_noise_coeff);
        highp vec4 _1443 = _1468;
        _1443.x = _624.x;
        _1443.y = _624.y;
        highp vec2 _638 = _1443.xz + vec2((fract(sin(dot(_611, vec2(7.989799976348876953125, 78.233001708984375))) * 43745.546875) - 0.5) * upsample_info_noise_coeff);
        highp vec4 _1447 = _1443;
        _1447.x = _638.x;
        _1447.z = _638.y;
        highp vec2 _652 = _1447.yz + vec2((fract(sin(dot(_611, vec2(8.98980045318603515625, 78.233001708984375))) * 43767.546875) - 0.5) * upsample_info_noise_coeff);
        highp vec4 _1451 = _1447;
        _1451.y = _652.x;
        _1451.z = _652.y;
        _1469 = _1451;
    }
    else
    {
        _1469 = _1468;
    }
    frag_color = _fl_out_pass < 0.5 ? vec4(_1469.rgb, 1.0) : vec4(vec3(_1469.a), 1.0);
}

