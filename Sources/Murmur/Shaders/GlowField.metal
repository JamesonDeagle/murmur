//
//  GlowField.metal — Murmur ambient notch glow.
//
//  Domain-warped fBM colour field (техника Inigo Quilez,
//  https://iquilezles.org/articles/warp/). Вместо бегущего линейного
//  градиента — органично морфящиеся цветные пятна, перетекающие друг
//  в друга, в духе Apple Intelligence edge glow.
//
//  Вызывается через SwiftUI .colorEffect (macOS 14+). Без собственного
//  таймера — время приходит uniform'ом из TimelineView-интегратора.
//
#include <metal_stdlib>
using namespace metal;

// ---------- hash / value noise / fbm ----------

// Не-sin хэш: стабилен на больших координатах (time входит в p),
// fract(sin(...)*43758) деградирует уже на p ~ 10^3.
static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);          // smoothstep-фейд
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 3 октавы. Поворот между октавами убирает осевые артефакты сетки.
static inline float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    const float2x2 rot = float2x2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 3; i++) {
        v += amp * vnoise(p);
        p = rot * p * 2.03;
        amp *= 0.5;
    }
    return v;   // ~[0.1, 0.9]
}

// ---------- основной эффект ----------
//
// position — pt внутри вью; color — пиксель источника (белый Rectangle,
// нужен только alpha); size — размер вью в pt.
// time      — накопленные «циклы» из advancePhase (скорость уже
//             промодулирована голосом на CPU).
// warpAmp   — амплитуда domain warp, 1.1 (тишина) … 3.5 (крик).
// brightness— общий гейн яркости, 0.75 … 1.2.
// cA..cD    — 4 стопа палитры, уже слерпленные по transitionProgress.
//
[[ stitchable ]] half4 glowField(
    float2 position, half4 color, float2 size,
    float time, float warpAmp, float brightness,
    half4 cA, half4 cB, half4 cC, half4 cD
) {
    // Нормализация по высоте — пятна круглые независимо от ширины панели.
    float2 uv = position / max(size.y, 1.0);
    // Базовая частота: ~2–3 пятна на ширину notch-зоны.
    float2 p = uv * 2.2;
    // Лёгкая горизонтальная адвекция — сохраняет знакомое «течение
    // влево→вправо» из v3.21, но теперь течёт само морфящееся поле.
    p.x -= time * 0.35;

    float t = time;
    // Уровень 1 warp'а: поле q, эволюционирует со временем.
    float2 q = float2(
        fbm(p + 0.20 * t),
        fbm(p + float2(5.2, 1.3) - 0.15 * t)
    );
    // Уровень 2: поле r, искажённое q. Разные скорости/фазы по осям —
    // пятна вращаются и перетекают, а не пульсируют синхронно.
    float2 r = float2(
        fbm(p + warpAmp * q + float2(1.7, 9.2) + 0.30 * t),
        fbm(p + warpAmp * q + float2(8.3, 2.8) - 0.26 * t)
    );
    float v = fbm(p + warpAmp * r);

    // Контраст: fbm живёт в середине диапазона — растягиваем.
    float vv = smoothstep(0.15, 0.85, v);

    // Цвет: классическое IQ-смешение по трём независимым каналам поля.
    half3 colAB = mix(cA.rgb, cB.rgb, half(saturate(vv)));
    half3 colCD = mix(cC.rgb, cD.rgb, half(saturate(q.x)));
    half3 col   = mix(colAB, colCD, half(saturate(r.y * 1.4 - 0.2)));

    // Светящиеся ядра: пики поля уводим к белому — после внешнего
    // SwiftUI-blur'а это читается как bloom-вспышки внутри потока.
    half peak = half(smoothstep(0.62, 0.95, v));
    col = mix(col, half3(1.0h), peak * 0.35h);

    col *= half(brightness);
    return half4(col, 1.0h) * color.a;
}
