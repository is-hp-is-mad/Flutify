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
#define _198_uUseMaskTex int(_198_uUseMaskTex__f)
#define _198_uHit int(_198_uHit__f)
#define _198_uIconMove int(_198_uIconMove__f)
#define _198_uHasRotation int(_198_uHasRotation__f)
#define _198_uUsePowGate int(_198_uUsePowGate__f)
#define _198_colorSpaceConvertMode int(_198_colorSpaceConvertMode__f)
#define hdr_info_enable_hdr int(hdr_info_enable_hdr__f)
#define glass_tint_enabled int(glass_tint_enabled__f)
uniform vec2 _fl_size;
uniform vec4 _fl_rect;
uniform float _fl_sdf_range;
uniform float _fl_fused;
uniform float _fl_kr;
uniform float _fl_k0;
uniform vec4 _fl_k;
uniform vec2 _198_uResolution;
uniform vec3 _198_uGeoPxSize;
uniform float _198_uShapeEdgePx;
uniform float _198_uShapeEdgePow;
uniform float _198_uShapeThicknessPx;
uniform float _198_uShapeReflectOffsetPx;
uniform vec3 _198_uDirectionalLightDirection;
uniform float _198_uDirectionalLightIntensity;
uniform float _198_uDirectionalLightOppositeIntensity;
uniform float _198_uDirectionalLightAngleRange;
uniform float _198_uDirectionalLightLightWidth;
uniform float _198_uRefractIOR;
uniform float _198_uReflectionStrength;
uniform float _198_uReflectionLighten;
uniform float _198_uDirectionalLightEdgePow;
uniform vec4 _198_uGlassColor;
uniform float _198_uInnerBottom;
uniform float _198_uRefractBlurScale;
uniform float _198_uColorPow;
uniform float _198_uAlpha;
uniform vec2 _198_uInvResolution;
uniform vec2 _198_uScale;
uniform float _198_uUseMaskTex__f;
uniform float _198_uHit__f;
uniform float _198_uUnshade;
uniform vec2 _198_uRotationTrig;
uniform float _198_uIconMove__f;
uniform vec2 _198_uIconGeoPxPos;
uniform float _198_iLightRadius;
uniform vec3 _198_uIconGeoPxSize;
uniform float _198_uIconLightStrength;
uniform vec3 _198_uDynamicLightDirection;
uniform float _198_uHasRotation__f;
uniform float _198_uUsePowGate__f;
uniform mat4 _198_srcTF;
uniform mat4 _198_destTF;
uniform mat4 _198_gamutTransform;
uniform float _198_colorSpaceConvertMode__f;
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

f16vec4 _3476 = f16vec4(float16_t(0.0));


uniform sampler2D uSdfTex;
uniform sampler2D uMaskTex;
uniform sampler2D uRefractTex;

out vec4 fragColor;

uniform sampler2D _fl_refractA;
uniform sampler2D _fl_backdrop;
highp float _fl_kw(int a)
{
    if (a == 0) return _fl_k0;
    if (a == 1) return _fl_k.x;
    if (a == 2) return _fl_k.y;
    if (a == 3) return _fl_k.z;
    return _fl_k.w;
}
highp vec4 _fl_tint(vec4 _fl_c, vec4 _fl_big, highp vec2 _fl_px)
{
    vec4 _580 = _fl_c;
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
        vec4 _1094 = _fl_big;
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
        highp vec2 _611 = _fl_px;
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
    return _1469;
}

highp vec4 _fl_refract(highp vec2 uv)
{
    if (_fl_fused < 0.5) return vec4(texture(uRefractTex, uv).rgb, texture(_fl_refractA, uv).r);
    highp vec3 acc = vec3(0.0);
    if (_fl_kr < 1.5)
    {
        // 3x3 kernel [k1 k0 k1]^2 as 4 bilinear taps at (+-d, +-d), d = _fl_k.x (exact with linear filtering)
        highp vec2 d = vec2(_fl_k.x) * _198_uInvResolution;
        acc = 0.25 * (texture(_fl_backdrop, uv + d).rgb + texture(_fl_backdrop, uv - d).rgb
                    + texture(_fl_backdrop, uv + vec2(d.x, -d.y)).rgb + texture(_fl_backdrop, uv + vec2(-d.x, d.y)).rgb);
        return _fl_tint(vec4(acc, 1.0), vec4(texture(_fl_backdrop, uv).rgb, 1.0), uv / _198_uInvResolution);
    }
    for (int j = -4; j <= 4; j++)
    {
        if (abs(float(j)) > _fl_kr) continue;
        highp float wj = _fl_kw(j < 0 ? -j : j);
        for (int i = -4; i <= 4; i++)
        {
            if (abs(float(i)) > _fl_kr) continue;
            acc += (wj * _fl_kw(i < 0 ? -i : i)) * texture(_fl_backdrop, uv + vec2(float(i), float(j)) * _198_uInvResolution).rgb;
        }
    }
    return _fl_tint(vec4(acc, 1.0), vec4(texture(_fl_backdrop, uv).rgb, 1.0), uv / _198_uInvResolution);
}

uniform sampler2D _fl_sdfB;
highp vec4 _fl_sdf(highp vec2 uv)
{
    highp vec4 a = texture(uSdfTex, uv);
    highp vec4 b = texture(_fl_sdfB, uv);
    highp vec2 t = vec2(b.x + b.y / 255.0, a.z + b.z / 255.0);
    return vec4(a.xy * 2.0 - 1.0, (t - 0.5) * (2.0 * _fl_sdf_range));
}

void main()
{
    highp vec3 v_screen_pos = vec3(FlutterFragCoord().xy, 1.0);
    highp vec2 v_texcoord = (FlutterFragCoord().xy - _fl_rect.xy) / _fl_rect.zw;
    bool _1328 = v_texcoord.x > 1.0;
    bool _1335 = false;
    if (!_1328)
    {
        _1335 = v_texcoord.y > 1.0;
    }
    else
    {
        _1335 = _1328;
    }
    bool _1342 = false;
    if (!_1335)
    {
        _1342 = v_texcoord.x < 0.0;
    }
    else
    {
        _1342 = _1335;
    }
    bool _1349 = false;
    if (!_1342)
    {
        _1349 = v_texcoord.y < 0.0;
    }
    else
    {
        _1349 = _1342;
    }
    highp vec2 _1542 = v_texcoord * _198_uGeoPxSize.xy;
    highp vec4 _1509 = _fl_sdf(clamp(min(_1542, _198_uGeoPxSize.xy - _1542) / vec2(max(_198_uGeoPxSize.z, _198_uShapeEdgePx) + 10.0), vec2(0.0), vec2(1.0)));
    f16vec4 _1510 = f16vec4(_1509);
    f16vec2 _1512 = _1510.xy;
    float16_t _3435 = float16_t(0.0);
    if (_1349)
    {
        _3435 = float16_t(5.0);
    }
    else
    {
        _3435 = _1510.w;
    }
    f16vec4 _3469 = f16vec4(float16_t(0.0));
    if (float(_3435) > 0.0)
    {
        _3469 = f16vec4(float16_t(0.0));
    }
    else
    {
        float16_t _1598 = float16_t(_198_uShapeEdgePx);
        float16_t _1602 = (-_3435) / _1598;
        highp float _1605 = float(_1510.z);
        highp float _1610 = (-_1605) / _198_uShapeEdgePx;
        highp float _3436 = 0.0;
        if (_1610 >= 0.85000002384185791015625)
        {
            _3436 = 1.0;
        }
        else
        {
            highp float _1814 = clamp(mix(0.5, 1.0, pow(clamp(clamp(_1610, 0.0, 1.0), 0.0, 1.0), 0.5)), 0.0, 1.0);
            _3436 = 1.0 - pow(1.0 - (((((_1814 * _1814) * _1814) * ((_1814 * ((_1814 * 6.0) - 15.0)) + 10.0)) - 0.5) * 2.0), 1.0);
        }
        f16vec3 _3437 = f16vec3(float16_t(0.0));
        if (_3435 <= (-_1598))
        {
            _3437 = f16vec3(float16_t(0.0), float16_t(0.0), float16_t(-1.0));
        }
        else
        {
            _3437 = normalize(f16vec3(mix(_1512, -_1512, f16vec2(step(vec2(0.5), v_texcoord))), float16_t(1.0)));
        }
        float16_t _1632 = float16_t(1.0) - _1602;
        float16_t _3439 = float16_t(0.0);
        if (_198_uIconMove == 1)
        {
            highp float _3438 = 0.0;
            if (abs(v_screen_pos.z) < 9.9999999747524270787835121154785e-07)
            {
                _3438 = (v_screen_pos.z < 0.0) ? (-9.9999999747524270787835121154785e-07) : 9.9999999747524270787835121154785e-07;
            }
            else
            {
                _3438 = v_screen_pos.z;
            }
            highp vec2 _1843 = (v_screen_pos.xy / vec2(_3438)) - _198_uIconGeoPxPos;
            highp vec2 _1850 = step(vec2(0.0), _1843);
            highp vec2 _1855 = step(_1843, _198_uIconGeoPxSize.xy);
            _3439 = (smoothstep(float16_t(0.0), float16_t(1.0), float16_t(texture(uMaskTex, _1843 / _198_uIconGeoPxSize.xy).x)) * float16_t(((_1850.x * _1850.y) * _1855.x) * _1855.y)) * float16_t(_198_uIconLightStrength);
        }
        else
        {
            _3439 = float16_t(0.0);
        }
        float16_t _1645 = float16_t(_198_uShapeThicknessPx);
        f16vec4 _3446 = f16vec4(float16_t(0.0));
        for (int _once1 = 0; _once1 < 1; _once1++)
        {
            if (_1602 >= float16_t(1.0))
            {
                f16vec4 _3445 = f16vec4(float16_t(0.0));
                for (int _once2 = 0; _once2 < 1; _once2++)
                {
                    highp float _3444 = 0.0;
                    if (abs(v_screen_pos.z) < 9.9999999747524270787835121154785e-07)
                    {
                        _3444 = (v_screen_pos.z < 0.0) ? (-9.9999999747524270787835121154785e-07) : 9.9999999747524270787835121154785e-07;
                    }
                    else
                    {
                        _3444 = v_screen_pos.z;
                    }
                    highp vec4 _2040 = _fl_refract(((v_screen_pos.xy / vec2(_3444)) - _198_uResolution) * _198_uInvResolution);
                    f16vec4 _2041 = f16vec4(_2040);
                    if (_3439 < float16_t(9.953975677490234375e-06))
                    {
                        _3445 = _2041;
                        break;
                    }
                    f16vec3 _2074 = _2041.xyz;
                    float16_t _2083 = dot(_2074, f16vec3(float16_t(0.2125244140625), float16_t(0.71484375), float16_t(0.0721435546875)));
                    float16_t _2092 = smoothstep(float16_t(0.0), float16_t(0.5), _2083);
                    float16_t _2103 = float16_t(1.0) + (smoothstep(float16_t(0.0), float16_t(1.0), _3439) * mix(float16_t(0.75), float16_t(0.39990234375), _2092));
                    float16_t _2116 = _2041.w;
                    f16vec3 _2009 = _2074 + ((f16vec4((_2074 * _2103) + f16vec3(mix(float16_t(1.0) - _2083, _2083, _2092) * (_2103 - float16_t(1.0))), _2116).xyz - _2074) * _2116);
                    f16vec4 _3334 = _2041;
                    _3334.x = _2009.x;
                    _3334.y = _2009.y;
                    _3334.z = _2009.z;
                    _3445 = _3334;
                }
                _3446 = _3445;
                break;
            }
            highp vec2 _2151 = vec2(refract(f16vec3(float16_t(0.0), float16_t(0.0), float16_t(-1.0)), _3437, float16_t(1.0) / (float16_t(_198_uRefractIOR) + (float16_t(0.199951171875) * float16_t(_198_uHit)))).xy * mix((_1645 - _1598) * float16_t(2.0), _1645 * float16_t(2.0), _1602));
            highp vec2 _3440 = vec2(0.0);
            for (int _once3 = 0; _once3 < 1; _once3++)
            {
                if (_198_uHasRotation == 0)
                {
                    _3440 = _2151;
                    break;
                }
                highp float _2170 = _2151.x;
                highp float _2174 = _2151.y;
                _3440 = vec2((_2170 * _198_uRotationTrig.x) - (_2174 * _198_uRotationTrig.y), (_2170 * _198_uRotationTrig.y) + (_2174 * _198_uRotationTrig.x));
            }
            f16vec4 _3442 = f16vec4(float16_t(0.0));
            for (int _once4 = 0; _once4 < 1; _once4++)
            {
                highp float _3441 = 0.0;
                if (abs(v_screen_pos.z) < 9.9999999747524270787835121154785e-07)
                {
                    _3441 = (v_screen_pos.z < 0.0) ? (-9.9999999747524270787835121154785e-07) : 9.9999999747524270787835121154785e-07;
                }
                else
                {
                    _3441 = v_screen_pos.z;
                }
                highp vec4 _2251 = _fl_refract((((v_screen_pos.xy / vec2(_3441)) + _3440) - _198_uResolution) * _198_uInvResolution);
                f16vec4 _2252 = f16vec4(_2251);
                if (_3439 < float16_t(9.953975677490234375e-06))
                {
                    _3442 = _2252;
                    break;
                }
                f16vec3 _2285 = _2252.xyz;
                float16_t _2294 = dot(_2285, f16vec3(float16_t(0.2125244140625), float16_t(0.71484375), float16_t(0.0721435546875)));
                float16_t _2303 = smoothstep(float16_t(0.0), float16_t(0.5), _2294);
                float16_t _2314 = float16_t(1.0) + (smoothstep(float16_t(0.0), float16_t(1.0), _3439) * mix(float16_t(0.75), float16_t(0.39990234375), _2303));
                float16_t _2327 = _2252.w;
                f16vec3 _2220 = _2285 + ((f16vec4((_2285 * _2314) + f16vec3(mix(float16_t(1.0) - _2294, _2294, _2303) * (_2314 - float16_t(1.0))), _2327).xyz - _2285) * _2327);
                f16vec4 _3346 = _2252;
                _3346.x = _2220.x;
                _3346.y = _2220.y;
                _3346.z = _2220.z;
                _3442 = _3346;
            }
            _3446 = _3442;
        }
        f16vec4 _3459 = f16vec4(float16_t(0.0));
        if (_1632 <= float16_t(9.5367431640625e-07))
        {
            _3459 = _3446;
        }
        else
        {
            highp vec2 _2354 = vec2(_3437.xy * (float16_t(2.0) * _3437.z)) * (_198_uShapeReflectOffsetPx * (1.0 - float(_1602)));
            highp vec2 _3456 = vec2(0.0);
            for (int _once5 = 0; _once5 < 1; _once5++)
            {
                if (_198_uHasRotation == 0)
                {
                    _3456 = _2354;
                    break;
                }
                highp float _2378 = _2354.x;
                highp float _2382 = _2354.y;
                _3456 = vec2((_2378 * _198_uRotationTrig.x) - (_2382 * _198_uRotationTrig.y), (_2378 * _198_uRotationTrig.y) + (_2382 * _198_uRotationTrig.x));
            }
            f16vec4 _3458 = f16vec4(float16_t(0.0));
            for (int _once6 = 0; _once6 < 1; _once6++)
            {
                highp float _3457 = 0.0;
                if (abs(v_screen_pos.z) < 9.9999999747524270787835121154785e-07)
                {
                    _3457 = (v_screen_pos.z < 0.0) ? (-9.9999999747524270787835121154785e-07) : 9.9999999747524270787835121154785e-07;
                }
                else
                {
                    _3457 = v_screen_pos.z;
                }
                highp vec4 _2459 = _fl_refract((((v_screen_pos.xy / vec2(_3457)) + _3456) - _198_uResolution) * _198_uInvResolution);
                f16vec4 _2460 = f16vec4(_2459);
                if (_3439 < float16_t(9.953975677490234375e-06))
                {
                    _3458 = _2460;
                    break;
                }
                f16vec3 _2493 = _2460.xyz;
                float16_t _2502 = dot(_2493, f16vec3(float16_t(0.2125244140625), float16_t(0.71484375), float16_t(0.0721435546875)));
                float16_t _2511 = smoothstep(float16_t(0.0), float16_t(0.5), _2502);
                float16_t _2522 = float16_t(1.0) + (smoothstep(float16_t(0.0), float16_t(1.0), _3439) * mix(float16_t(0.75), float16_t(0.39990234375), _2511));
                float16_t _2535 = _2460.w;
                f16vec3 _2428 = _2493 + ((f16vec4((_2493 * _2522) + f16vec3(mix(float16_t(1.0) - _2502, _2502, _2511) * (_2522 - float16_t(1.0))), _2535).xyz - _2493) * _2535);
                f16vec4 _3359 = f16vec4(float16_t(0.0));
                _3359.x = _2428.x;
                _3359.y = _2428.y;
                _3359.z = _2428.z;
                _3458 = _3359;
            }
            f16vec3 _1683 = mix(_3446, _3458, f16vec4((float16_t(1.0) - float16_t(_3436)) * float16_t(_198_uReflectionStrength))).xyz;
            f16vec3 _2558 = _1683 + ((_3458.xyz * ((_1632 * float16_t(_198_uReflectionLighten)) * _3446.w)) * (float16_t(0.2998046875) + (float16_t(0.69970703125) * clamp(float16_t(1.8994140625) - (float16_t(2.1484375) * dot(_1683, f16vec3(float16_t(0.2125244140625), float16_t(0.71484375), float16_t(0.0721435546875)))), float16_t(0.0), float16_t(1.0)))));
            f16vec4 _3366 = f16vec4(float16_t(0.0));
            _3366.x = _2558.x;
            _3366.y = _2558.y;
            _3366.z = _2558.z;
            _3459 = _3366;
        }
        float16_t _2569 = smoothstep(float16_t(1.0), float16_t(0.0), float16_t(1.0) - f16vec2(v_texcoord).y);
        f16vec4 _3474 = f16vec4(_3459.xyz + f16vec3((_2569 * _2569) * float16_t(_198_uInnerBottom)), float16_t(1.0));
        f16vec4 _3467 = f16vec4(float16_t(0.0));
        if (_1632 <= float16_t(0.00099945068359375))
        {
            _3467 = _3474;
        }
        else
        {
            float16_t _2639 = float16_t(_198_uDirectionalLightIntensity);
            float16_t _2642 = float16_t(_198_uDirectionalLightOppositeIntensity);
            f16vec3 _3382 = _3437;
            _3382.y = -_3437.y;
            float16_t _2652 = float16_t(1.0) / (float16_t(3.140625) * float16_t(_198_uDirectionalLightAngleRange));
            f16vec3 _2656 = normalize(f16vec3(_198_uDirectionalLightDirection));
            float16_t _2659 = dot(_3382, _2656);
            float16_t _2662 = float16_t(2.0) * _3437.z;
            float16_t _2667 = (_2662 * _2656.z) - _2659;
            float16_t _2782 = clamp(_2659, float16_t(-1.0), float16_t(1.0));
            float16_t _2805 = abs(_2782);
            float16_t _2821 = ((((((float16_t(-0.0187225341796875) * _2805) + float16_t(0.07421875)) * _2805) - float16_t(0.2120361328125)) * _2805) + float16_t(1.5703125)) * sqrt(float16_t(1.0) - _2805);
            float16_t _2836 = clamp(_2667, float16_t(-1.0), float16_t(1.0));
            float16_t _2859 = abs(_2836);
            float16_t _2875 = ((((((float16_t(-0.0187225341796875) * _2859) + float16_t(0.07421875)) * _2859) - float16_t(0.2120361328125)) * _2859) + float16_t(1.5703125)) * sqrt(float16_t(1.0) - _2859);
            float16_t _2678 = (max(_2659, float16_t(0.0)) * max(_2639 * (float16_t(1.0) - ((_2821 + (float16_t(_2782 < float16_t(0.0)) * (float16_t(3.140625) - (float16_t(2.0) * _2821)))) * _2652)), float16_t(0.0))) + (max(_2667, float16_t(0.0)) * max(_2642 * (float16_t(1.0) - ((_2875 + (float16_t(_2836 < float16_t(0.0)) * (float16_t(3.140625) - (float16_t(2.0) * _2875)))) * _2652)), float16_t(0.0)));
            bool _2681 = _198_uIconMove != 0;
            bool _2690 = false;
            if (_2681)
            {
                _2690 = dot(_198_uDynamicLightDirection, _198_uDynamicLightDirection) > 0.0;
            }
            else
            {
                _2690 = _2681;
            }
            float16_t _3466 = float16_t(0.0);
            if (_2690)
            {
                f16vec3 _2695 = normalize(f16vec3(_198_uDynamicLightDirection));
                float16_t _2698 = dot(_3382, _2695);
                float16_t _2706 = (_2662 * _2695.z) - _2698;
                float16_t _2890 = clamp(_2698, float16_t(-1.0), float16_t(1.0));
                float16_t _2913 = abs(_2890);
                float16_t _2929 = ((((((float16_t(-0.0187225341796875) * _2913) + float16_t(0.07421875)) * _2913) - float16_t(0.2120361328125)) * _2913) + float16_t(1.5703125)) * sqrt(float16_t(1.0) - _2913);
                float16_t _2944 = clamp(_2706, float16_t(-1.0), float16_t(1.0));
                float16_t _2967 = abs(_2944);
                float16_t _2983 = ((((((float16_t(-0.0187225341796875) * _2967) + float16_t(0.07421875)) * _2967) - float16_t(0.2120361328125)) * _2967) + float16_t(1.5703125)) * sqrt(float16_t(1.0) - _2967);
                highp vec2 _2721 = _198_uIconGeoPxSize.xy * 0.5;
                highp float _3460 = 0.0;
                if (abs(v_screen_pos.z) < 9.9999999747524270787835121154785e-07)
                {
                    _3460 = (v_screen_pos.z < 0.0) ? (-9.9999999747524270787835121154785e-07) : 9.9999999747524270787835121154785e-07;
                }
                else
                {
                    _3460 = v_screen_pos.z;
                }
                float16_t _2739 = clamp(float16_t(_198_uIconLightStrength), float16_t(0.0), float16_t(1.0));
                _3466 = mix(_2678, (max(_2698, float16_t(0.0)) * max(_2639 * (float16_t(1.0) - ((_2929 + (float16_t(_2890 < float16_t(0.0)) * (float16_t(3.140625) - (float16_t(2.0) * _2929)))) * _2652)), float16_t(0.0))) + (max(_2706, float16_t(0.0)) * max(_2642 * (float16_t(1.0) - ((_2983 + (float16_t(_2944 < float16_t(0.0)) * (float16_t(3.140625) - (float16_t(2.0) * _2983)))) * _2652)), float16_t(0.0))), float16_t(smoothstep(1.0, 0.0, length(((v_screen_pos.xy / vec2(_3460)) - (_198_uIconGeoPxPos + _2721)) / max(_2721, vec2(1.0))))) * _2739) * mix(float16_t(1.0), (_198_uIconMove == 2) ? float16_t(3.0) : float16_t(1.0), _2739);
            }
            else
            {
                _3466 = _2678;
            }
            f16vec3 _2760 = _3474.xyz;
            float16_t _3017 = dot(_2760, f16vec3(float16_t(0.2125244140625), float16_t(0.71484375), float16_t(0.0721435546875)));
            float16_t _3039 = smoothstep(float16_t(0.0), float16_t(0.5), _3017);
            float16_t _3050 = float16_t(1.0) + (smoothstep(float16_t(0.0), float16_t(1.0), (_3466 * float16_t(2.0)) * (_3017 * (float16_t(0.5) + (float16_t(0.5) * smoothstep(float16_t(0.199951171875), float16_t(1.0), distance(f16vec3(float16_t(1.0)), _2760)))))) * mix(float16_t(0.75), float16_t(0.39990234375), _3039));
            _3467 = f16vec4((_2760 * _3050) + f16vec3(mix(float16_t(1.0) - _3017, _3017, _3039) * (_3050 - float16_t(1.0))), float16_t(1.0));
        }
        f16vec4 _3468 = f16vec4(float16_t(0.0));
        if (_198_uUsePowGate != 0)
        {
            f16vec3 _1722 = f16vec3(pow(vec3(_3467.xyz), vec3(_198_uColorPow)));
            f16vec4 _3389 = _3467;
            _3389.x = _1722.x;
            _3389.y = _1722.y;
            _3389.z = _1722.z;
            _3468 = _3389;
        }
        else
        {
            _3468 = _3467;
        }
        _3469 = f16vec4(mix(clamp(_3468.xyz, f16vec3(float16_t(0.0)), f16vec3(float16_t(1.0))), f16vec3(_198_uGlassColor.xyz), f16vec3(float16_t(_198_uUnshade))), _3468.w * (float16_t(1.0 - smoothstep(-2.0, 0.0, _1605)) * float16_t(_198_uAlpha)));
    }
    highp vec4 _1391 = vec4(_3469);
    highp vec4 _3470 = vec4(0.0);
    if (_198_colorSpaceConvertMode == 1)
    {
        highp vec3 _1401 = _1391.xyz;
        highp vec3 _3100 = abs(_1401);
        highp vec3 _3129 = sign(_1401) * mix((_3100 * _198_srcTF[0].w) + vec3(_198_srcTF[1].z), pow(max((_3100 * _198_srcTF[0].y) + vec3(_198_srcTF[0].z), vec3(0.0)), vec3(_198_srcTF[0].x)) + vec3(_198_srcTF[1].y), step(vec3(_198_srcTF[1].x), _3100));
        highp vec4 _3404 = _1391;
        _3404.x = _3129.x;
        _3404.y = _3129.y;
        _3404.z = _3129.z;
        highp vec3 _1423 = mat3(_198_gamutTransform[0].xyz, _198_gamutTransform[1].xyz, _198_gamutTransform[2].xyz) * _3404.xyz;
        highp vec4 _3410 = _3404;
        _3410.x = _1423.x;
        _3410.y = _1423.y;
        _3410.z = _1423.z;
        highp vec3 _3161 = abs(_3410.xyz);
        highp vec3 _3190 = sign(_3410.xyz) * mix((_3161 * _198_destTF[0].w) + vec3(_198_destTF[1].z), pow(max((_3161 * _198_destTF[0].y) + vec3(_198_destTF[0].z), vec3(0.0)), vec3(_198_destTF[0].x)) + vec3(_198_destTF[1].y), step(vec3(_198_destTF[1].x), _3161));
        highp vec4 _3416 = _3410;
        _3416.x = _3190.x;
        _3416.y = _3190.y;
        _3416.z = _3190.z;
        _3470 = _3416;
    }
    else
    {
        highp vec4 _3471 = vec4(0.0);
        if (_198_colorSpaceConvertMode == 2)
        {
            highp vec3 _1448 = _1391.xyz;
            highp vec3 _3222 = abs(_1448);
            highp vec3 _3251 = sign(_1448) * mix((_3222 * _198_srcTF[0].w) + vec3(_198_srcTF[1].z), pow(max((_3222 * _198_srcTF[0].y) + vec3(_198_srcTF[0].z), vec3(0.0)), vec3(_198_srcTF[0].x)) + vec3(_198_srcTF[1].y), step(vec3(_198_srcTF[1].x), _3222));
            highp vec4 _3422 = _1391;
            _3422.x = _3251.x;
            _3422.y = _3251.y;
            _3422.z = _3251.z;
            highp vec3 _3283 = abs(_3422.xyz);
            highp vec3 _3312 = sign(_3422.xyz) * mix((_3283 * _198_destTF[0].w) + vec3(_198_destTF[1].z), pow(max((_3283 * _198_destTF[0].y) + vec3(_198_destTF[0].z), vec3(0.0)), vec3(_198_destTF[0].x)) + vec3(_198_destTF[1].y), step(vec3(_198_destTF[1].x), _3283));
            highp vec4 _3428 = _3422;
            _3428.x = _3312.x;
            _3428.y = _3312.y;
            _3428.z = _3312.z;
            _3471 = _3428;
        }
        else
        {
            _3471 = _1391;
        }
        _3470 = _3471;
    }
    fragColor = vec4(_3470.xyz * _3470.w, _3470.w);
}

