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
#define pushConstants_uIsCircle int(pushConstants_uIsCircle__f)
uniform vec2 _fl_size;
uniform float _fl_sdf_range;
uniform float _fl_sdf_pass;
uniform vec3 pushConstants_rectDimensions;
uniform vec3 pushConstants_edgeParams;
uniform float pushConstants_uIsCircle__f;


out vec4 outColor;

void main()
{
    highp vec2 v_texture_coords = FlutterFragCoord().xy / _fl_size;
    bool _778 = false;
    highp float _797 = 0.0;
    f16vec2 _605 = f16vec2(FlutterFragCoord().xy);
    float16_t _615 = float16_t(pushConstants_rectDimensions.y);
    float16_t _625 = float16_t(pushConstants_edgeParams.x);
    f16vec2 _633 = f16vec2(float16_t(pushConstants_rectDimensions.x), _615);
    f16vec2 _637 = _633 * float16_t(0.5);
    f16vec2 _3111 = _637;
    _3111.y = _615 - _637.y;
    highp vec2 _651 = vec2(_605 - _3111);
    highp vec2 _653 = vec2(_637);
    highp float _655 = float(float16_t(pushConstants_rectDimensions.z));
    highp float _657 = float(_625);
    highp float _3246 = 0.0;
    for (int _once1 = 0; _once1 < 1; _once1++)
    {
        _778 = pushConstants_uIsCircle != 0;
        highp float _3240 = 0.0;
        if (_778)
        {
            highp vec2 _846 = (abs(abs(_651)) - _653) + vec2(_655);
            _3240 = (min(max(_846.x, _846.y), 0.0) + length(max(_846, vec2(0.0)))) - _655;
        }
        else
        {
            highp float _886 = 1.52866494655609130859375 * abs(_655);
            highp vec2 _899 = vec2(_886);
            highp vec2 _901 = _899 + (abs(_651) - _653);
            highp vec2 _908 = abs(max(vec2(0.0), _901 / _899));
            highp float _910 = _908.x;
            highp float _912 = _908.y;
            highp float _913 = max(_910, _912);
            highp float _3238 = 0.0;
            if (_913 == 0.0)
            {
                _3238 = 0.0;
            }
            else
            {
                _3238 = clamp(min(_910, _912) / _913, 0.0, 1.0);
            }
            highp float _944 = length(_908);
            highp float _957 = (_944 + 1.0) - (1.0 / (1.0 - (((_3238 * _3238) * clamp(_944, 0.0, 1.0)) * (((((((((-0.739119708538055419921875) * _3238) + 2.4034926891326904296875) * _3238) - 2.4907319545745849609375) * _3238) + 0.47687089443206787109375) * _3238) + 0.4747847616672515869140625))));
            highp float _980 = (_912 > _910) ? 1.0 : (-1.0);
            _3240 = min(max(_901.x, _901.y), 0.0) + (_886 * (mix(_957, _957, clamp((0.5 - _980) + (_980 * _3238), 0.0, 1.0)) - 1.0));
        }
        _797 = -_657;
        highp float _3244 = 0.0;
        if (_3240 < _797)
        {
            _3244 = _797;
        }
        else
        {
            highp float _3245 = 0.0;
            if (_3240 < 0.0)
            {
                highp float _809 = (-_3240) / _657;
                highp float _3241 = 0.0;
                for (int _once2 = 0; _once2 < 1; _once2++)
                {
                    if (_809 >= 0.85000002384185791015625)
                    {
                        _3241 = 1.0;
                        break;
                    }
                    highp float _1143 = clamp(mix(0.5, 1.0, pow(clamp(clamp(_809, 0.0, 1.0), 0.0, 1.0), 0.5)), 0.0, 1.0);
                    _3241 = 1.0 - pow(1.0 - (((((_1143 * _1143) * _1143) * ((_1143 * ((_1143 * 6.0) - 15.0)) + 10.0)) - 0.5) * 2.0), float(float16_t(pushConstants_edgeParams.y)));
                }
                if ((_655 + 1.0) <= (-10.0))
                {
                    _3246 = -_3241;
                    break;
                }
                _3245 = (-_3241) * _657;
            }
            else
            {
                _3245 = _3240;
            }
            _3244 = _3245;
        }
        _3246 = _3244;
    }
    float16_t _753 = float16_t(_3246);
    highp float _3249 = 0.0;
    if (_778)
    {
        highp vec2 _1210 = (abs(abs(_651)) - _653) + vec2(_655);
        _3249 = (min(max(_1210.x, _1210.y), 0.0) + length(max(_1210, vec2(0.0)))) - _655;
    }
    else
    {
        highp float _1250 = 1.52866494655609130859375 * abs(_655);
        highp vec2 _1263 = vec2(_1250);
        highp vec2 _1265 = _1263 + (abs(_651) - _653);
        highp vec2 _1272 = abs(max(vec2(0.0), _1265 / _1263));
        highp float _1274 = _1272.x;
        highp float _1276 = _1272.y;
        highp float _1277 = max(_1274, _1276);
        highp float _3247 = 0.0;
        if (_1277 == 0.0)
        {
            _3247 = 0.0;
        }
        else
        {
            _3247 = clamp(min(_1274, _1276) / _1277, 0.0, 1.0);
        }
        highp float _1308 = length(_1272);
        highp float _1321 = (_1308 + 1.0) - (1.0 / (1.0 - (((_3247 * _3247) * clamp(_1308, 0.0, 1.0)) * (((((((((-0.739119708538055419921875) * _3247) + 2.4034926891326904296875) * _3247) - 2.4907319545745849609375) * _3247) + 0.47687089443206787109375) * _3247) + 0.4747847616672515869140625))));
        highp float _1344 = (_1276 > _1274) ? 1.0 : (-1.0);
        _3249 = min(max(_1265.x, _1265.y), 0.0) + (_1250 * (mix(_1321, _1321, clamp((0.5 - _1344) + (_1344 * _3247), 0.0, 1.0)) - 1.0));
    }
    f16vec3 _3287 = f16vec3(float16_t(0.0));
    if (_753 <= (-_625))
    {
        _3287 = f16vec3(float16_t(0.0), float16_t(0.0), float16_t(1.0));
    }
    else
    {
        highp vec2 _1431 = vec2(_633) * 0.5;
        highp vec2 _1434 = vec2(_605) - vec2(_3111);
        highp vec2 _1438 = _1434 + vec2(1.0, 0.0);
        highp float _3259 = 0.0;
        for (int _once3 = 0; _once3 < 1; _once3++)
        {
            highp float _3253 = 0.0;
            if (_778)
            {
                highp vec2 _1577 = (abs(abs(_1438)) - _1431) + vec2(_655);
                _3253 = (min(max(_1577.x, _1577.y), 0.0) + length(max(_1577, vec2(0.0)))) - _655;
            }
            else
            {
                highp float _1617 = 1.52866494655609130859375 * abs(_655);
                highp vec2 _1630 = vec2(_1617);
                highp vec2 _1632 = _1630 + (abs(_1438) - _1431);
                highp vec2 _1639 = abs(max(vec2(0.0), _1632 / _1630));
                highp float _1641 = _1639.x;
                highp float _1643 = _1639.y;
                highp float _1644 = max(_1641, _1643);
                highp float _3251 = 0.0;
                if (_1644 == 0.0)
                {
                    _3251 = 0.0;
                }
                else
                {
                    _3251 = clamp(min(_1641, _1643) / _1644, 0.0, 1.0);
                }
                highp float _1675 = length(_1639);
                highp float _1688 = (_1675 + 1.0) - (1.0 / (1.0 - (((_3251 * _3251) * clamp(_1675, 0.0, 1.0)) * (((((((((-0.739119708538055419921875) * _3251) + 2.4034926891326904296875) * _3251) - 2.4907319545745849609375) * _3251) + 0.47687089443206787109375) * _3251) + 0.4747847616672515869140625))));
                highp float _1711 = (_1643 > _1641) ? 1.0 : (-1.0);
                _3253 = min(max(_1632.x, _1632.y), 0.0) + (_1617 * (mix(_1688, _1688, clamp((0.5 - _1711) + (_1711 * _3251), 0.0, 1.0)) - 1.0));
            }
            highp float _3257 = 0.0;
            if (_3253 < _797)
            {
                _3257 = _797;
            }
            else
            {
                highp float _3258 = 0.0;
                if (_3253 < 0.0)
                {
                    highp float _1540 = (-_3253) / _657;
                    highp float _3254 = 0.0;
                    for (int _once4 = 0; _once4 < 1; _once4++)
                    {
                        if (_1540 >= 0.85000002384185791015625)
                        {
                            _3254 = 1.0;
                            break;
                        }
                        highp float _1874 = clamp(mix(0.5, 1.0, pow(clamp(clamp(_1540, 0.0, 1.0), 0.0, 1.0), 0.5)), 0.0, 1.0);
                        _3254 = 1.0 - pow(1.0 - (((((_1874 * _1874) * _1874) * ((_1874 * ((_1874 * 6.0) - 15.0)) + 10.0)) - 0.5) * 2.0), pushConstants_edgeParams.y);
                    }
                    if ((_655 + 1.0) <= (-10.0))
                    {
                        _3259 = -_3254;
                        break;
                    }
                    _3258 = (-_3254) * _657;
                }
                else
                {
                    _3258 = _3253;
                }
                _3257 = _3258;
            }
            _3259 = _3257;
        }
        highp vec2 _1447 = _1434 - vec2(1.0, 0.0);
        highp float _3268 = 0.0;
        for (int _once5 = 0; _once5 < 1; _once5++)
        {
            highp float _3262 = 0.0;
            if (_778)
            {
                highp vec2 _1983 = (abs(abs(_1447)) - _1431) + vec2(_655);
                _3262 = (min(max(_1983.x, _1983.y), 0.0) + length(max(_1983, vec2(0.0)))) - _655;
            }
            else
            {
                highp float _2023 = 1.52866494655609130859375 * abs(_655);
                highp vec2 _2036 = vec2(_2023);
                highp vec2 _2038 = _2036 + (abs(_1447) - _1431);
                highp vec2 _2045 = abs(max(vec2(0.0), _2038 / _2036));
                highp float _2047 = _2045.x;
                highp float _2049 = _2045.y;
                highp float _2050 = max(_2047, _2049);
                highp float _3260 = 0.0;
                if (_2050 == 0.0)
                {
                    _3260 = 0.0;
                }
                else
                {
                    _3260 = clamp(min(_2047, _2049) / _2050, 0.0, 1.0);
                }
                highp float _2081 = length(_2045);
                highp float _2094 = (_2081 + 1.0) - (1.0 / (1.0 - (((_3260 * _3260) * clamp(_2081, 0.0, 1.0)) * (((((((((-0.739119708538055419921875) * _3260) + 2.4034926891326904296875) * _3260) - 2.4907319545745849609375) * _3260) + 0.47687089443206787109375) * _3260) + 0.4747847616672515869140625))));
                highp float _2117 = (_2049 > _2047) ? 1.0 : (-1.0);
                _3262 = min(max(_2038.x, _2038.y), 0.0) + (_2023 * (mix(_2094, _2094, clamp((0.5 - _2117) + (_2117 * _3260), 0.0, 1.0)) - 1.0));
            }
            highp float _3266 = 0.0;
            if (_3262 < _797)
            {
                _3266 = _797;
            }
            else
            {
                highp float _3267 = 0.0;
                if (_3262 < 0.0)
                {
                    highp float _1946 = (-_3262) / _657;
                    highp float _3263 = 0.0;
                    for (int _once6 = 0; _once6 < 1; _once6++)
                    {
                        if (_1946 >= 0.85000002384185791015625)
                        {
                            _3263 = 1.0;
                            break;
                        }
                        highp float _2280 = clamp(mix(0.5, 1.0, pow(clamp(clamp(_1946, 0.0, 1.0), 0.0, 1.0), 0.5)), 0.0, 1.0);
                        _3263 = 1.0 - pow(1.0 - (((((_2280 * _2280) * _2280) * ((_2280 * ((_2280 * 6.0) - 15.0)) + 10.0)) - 0.5) * 2.0), pushConstants_edgeParams.y);
                    }
                    if ((_655 + 1.0) <= (-10.0))
                    {
                        _3268 = -_3263;
                        break;
                    }
                    _3267 = (-_3263) * _657;
                }
                else
                {
                    _3267 = _3262;
                }
                _3266 = _3267;
            }
            _3268 = _3266;
        }
        highp vec2 _1456 = _1434 + vec2(0.0, 1.0);
        highp float _3277 = 0.0;
        for (int _once7 = 0; _once7 < 1; _once7++)
        {
            highp float _3271 = 0.0;
            if (_778)
            {
                highp vec2 _2389 = (abs(abs(_1456)) - _1431) + vec2(_655);
                _3271 = (min(max(_2389.x, _2389.y), 0.0) + length(max(_2389, vec2(0.0)))) - _655;
            }
            else
            {
                highp float _2429 = 1.52866494655609130859375 * abs(_655);
                highp vec2 _2442 = vec2(_2429);
                highp vec2 _2444 = _2442 + (abs(_1456) - _1431);
                highp vec2 _2451 = abs(max(vec2(0.0), _2444 / _2442));
                highp float _2453 = _2451.x;
                highp float _2455 = _2451.y;
                highp float _2456 = max(_2453, _2455);
                highp float _3269 = 0.0;
                if (_2456 == 0.0)
                {
                    _3269 = 0.0;
                }
                else
                {
                    _3269 = clamp(min(_2453, _2455) / _2456, 0.0, 1.0);
                }
                highp float _2487 = length(_2451);
                highp float _2500 = (_2487 + 1.0) - (1.0 / (1.0 - (((_3269 * _3269) * clamp(_2487, 0.0, 1.0)) * (((((((((-0.739119708538055419921875) * _3269) + 2.4034926891326904296875) * _3269) - 2.4907319545745849609375) * _3269) + 0.47687089443206787109375) * _3269) + 0.4747847616672515869140625))));
                highp float _2523 = (_2455 > _2453) ? 1.0 : (-1.0);
                _3271 = min(max(_2444.x, _2444.y), 0.0) + (_2429 * (mix(_2500, _2500, clamp((0.5 - _2523) + (_2523 * _3269), 0.0, 1.0)) - 1.0));
            }
            highp float _3275 = 0.0;
            if (_3271 < _797)
            {
                _3275 = _797;
            }
            else
            {
                highp float _3276 = 0.0;
                if (_3271 < 0.0)
                {
                    highp float _2352 = (-_3271) / _657;
                    highp float _3272 = 0.0;
                    for (int _once8 = 0; _once8 < 1; _once8++)
                    {
                        if (_2352 >= 0.85000002384185791015625)
                        {
                            _3272 = 1.0;
                            break;
                        }
                        highp float _2686 = clamp(mix(0.5, 1.0, pow(clamp(clamp(_2352, 0.0, 1.0), 0.0, 1.0), 0.5)), 0.0, 1.0);
                        _3272 = 1.0 - pow(1.0 - (((((_2686 * _2686) * _2686) * ((_2686 * ((_2686 * 6.0) - 15.0)) + 10.0)) - 0.5) * 2.0), pushConstants_edgeParams.y);
                    }
                    if ((_655 + 1.0) <= (-10.0))
                    {
                        _3277 = -_3272;
                        break;
                    }
                    _3276 = (-_3272) * _657;
                }
                else
                {
                    _3276 = _3271;
                }
                _3275 = _3276;
            }
            _3277 = _3275;
        }
        highp vec2 _1465 = _1434 - vec2(0.0, 1.0);
        highp float _3286 = 0.0;
        for (int _once9 = 0; _once9 < 1; _once9++)
        {
            highp float _3280 = 0.0;
            if (_778)
            {
                highp vec2 _2795 = (abs(abs(_1465)) - _1431) + vec2(_655);
                _3280 = (min(max(_2795.x, _2795.y), 0.0) + length(max(_2795, vec2(0.0)))) - _655;
            }
            else
            {
                highp float _2835 = 1.52866494655609130859375 * abs(_655);
                highp vec2 _2848 = vec2(_2835);
                highp vec2 _2850 = _2848 + (abs(_1465) - _1431);
                highp vec2 _2857 = abs(max(vec2(0.0), _2850 / _2848));
                highp float _2859 = _2857.x;
                highp float _2861 = _2857.y;
                highp float _2862 = max(_2859, _2861);
                highp float _3278 = 0.0;
                if (_2862 == 0.0)
                {
                    _3278 = 0.0;
                }
                else
                {
                    _3278 = clamp(min(_2859, _2861) / _2862, 0.0, 1.0);
                }
                highp float _2893 = length(_2857);
                highp float _2906 = (_2893 + 1.0) - (1.0 / (1.0 - (((_3278 * _3278) * clamp(_2893, 0.0, 1.0)) * (((((((((-0.739119708538055419921875) * _3278) + 2.4034926891326904296875) * _3278) - 2.4907319545745849609375) * _3278) + 0.47687089443206787109375) * _3278) + 0.4747847616672515869140625))));
                highp float _2929 = (_2861 > _2859) ? 1.0 : (-1.0);
                _3280 = min(max(_2850.x, _2850.y), 0.0) + (_2835 * (mix(_2906, _2906, clamp((0.5 - _2929) + (_2929 * _3278), 0.0, 1.0)) - 1.0));
            }
            highp float _3284 = 0.0;
            if (_3280 < _797)
            {
                _3284 = _797;
            }
            else
            {
                highp float _3285 = 0.0;
                if (_3280 < 0.0)
                {
                    highp float _2758 = (-_3280) / _657;
                    highp float _3281 = 0.0;
                    for (int _once10 = 0; _once10 < 1; _once10++)
                    {
                        if (_2758 >= 0.85000002384185791015625)
                        {
                            _3281 = 1.0;
                            break;
                        }
                        highp float _3092 = clamp(mix(0.5, 1.0, pow(clamp(clamp(_2758, 0.0, 1.0), 0.0, 1.0), 0.5)), 0.0, 1.0);
                        _3281 = 1.0 - pow(1.0 - (((((_3092 * _3092) * _3092) * ((_3092 * ((_3092 * 6.0) - 15.0)) + 10.0)) - 0.5) * 2.0), pushConstants_edgeParams.y);
                    }
                    if ((_655 + 1.0) <= (-10.0))
                    {
                        _3286 = -_3281;
                        break;
                    }
                    _3285 = (-_3281) * _657;
                }
                else
                {
                    _3285 = _3280;
                }
                _3284 = _3285;
            }
            _3286 = _3284;
        }
        _3287 = f16vec3(f16vec2(vec2((_3259 - _3268) * 0.5, (_3277 - _3286) * 0.5)), float16_t(1.0));
    }
    highp vec4 _fl_s = vec4(f16vec4(_3287.xy, float16_t((_3249 < _797) ? _797 : _3249), _753));
    {
        highp vec2 _fl_t = clamp(_fl_s.zw / (2.0 * _fl_sdf_range) + 0.5, 0.0, 1.0);
        highp vec2 _fl_hi = floor(_fl_t * 255.0) / 255.0;
        highp vec2 _fl_lo = fract(_fl_t * 255.0);
        outColor = _fl_sdf_pass < 0.5 ? vec4(clamp(_fl_s.xy * 0.5 + 0.5, 0.0, 1.0), _fl_hi.y, 1.0)
                                      : vec4(_fl_hi.x, _fl_lo.x, _fl_lo.y, 1.0);
    }
}

