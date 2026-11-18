// Hermes orb (redesign spec §5.1): a daytime sky seen through a round window.
// Upper part: zenith-to-horizon blue gradient. Lower part: a cloud bank whose
// soft, wavy horizon comes from 4-octave fbm. Crisp circular edge, 1 dp rim.
// All colours are the orb palette tokens (§3.1). Output is premultiplied.
#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;
uniform float uScale;
uniform float uCloud;
uniform float uTilt;
uniform float uRoll;
uniform float uDrift;
uniform float uTurb;
uniform float uSat;
uniform float uHue;
uniform float uBright;
uniform float uOpacity;
uniform float uDpr;

out vec4 fragColor;

const vec3 SKY_TOP = vec3(0.184, 0.333, 0.941);   // #2F55F0
const vec3 SKY_LOW = vec3(0.498, 0.608, 1.000);   // #7F9BFF
const vec3 CLOUD = vec3(0.957, 0.945, 0.980);     // #F4F1FA
const vec3 SHADE = vec3(0.812, 0.776, 0.890);     // #CFC6E3
const vec3 ERR_TOP = vec3(0.549, 0.353, 0.353);   // #8C5A5A
const vec3 ERR_LOW = vec3(0.788, 0.576, 0.576);   // #C99393

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
  for (int i = 0; i < 4; i++) {
    v += a * vnoise(p);
    p = m * p;
    a *= 0.5;
  }
  return v;
}

mat2 rot(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat2(c, -s, s, c);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 centre = 0.5 * uSize;
  float R = 0.5 * min(uSize.x, uSize.y) * uScale;
  vec2 d = frag - centre;
  float dist = length(d);
  // Coordinates are logical pixels. Crisp edge: about one physical pixel
  // of anti-aliasing.
  float aa = 0.75 / max(uDpr, 1.0);
  float inside = 1.0 - smoothstep(R - aa, R + aa, dist);
  if (inside <= 0.0 || R < 0.5) {
    fragColor = vec4(0.0);
    return;
  }
  vec2 q = d / R;                  // unit disc, y points down
  vec2 h = rot(uTilt) * q;         // horizon frame (tilt)
  vec2 n = rot(uRoll) * q;         // noise frame (roll)
  float t = uTime;

  // Wavy horizon.
  float wave = (fbm(vec2(h.x * 1.5 + uDrift * 2.0, t * 0.20)) - 0.5) * (0.34 * uTurb)
             + (fbm(vec2(h.x * 3.6 - uDrift * 3.0 + 7.1, t * 0.33 + 3.0)) - 0.5) * (0.12 * uTurb);
  float horizon = 1.0 - 2.0 * uCloud;
  float yy = h.y - wave;
  float feather = 0.12;            // 6 % of the diameter, in radius units
  float bank = smoothstep(horizon - feather, horizon + feather, yy);

  // Sky: zenith to horizon, with the error tint.
  vec3 top = mix(SKY_TOP, ERR_TOP, uHue);
  vec3 low = mix(SKY_LOW, ERR_LOW, uHue);
  float sk = clamp((h.y + 1.0) / max(horizon + 1.0, 0.2), 0.0, 1.0);
  vec3 sky = mix(top, low, smoothstep(0.0, 1.0, sk));

  // Thin wisps just above the bank.
  float w = fbm(n * 2.2 + vec2(uDrift * 4.0, t * 0.05));
  float wisp = smoothstep(0.52, 0.86, w) * smoothstep(horizon - 0.75, horizon, yy);
  sky = mix(sky, CLOUD, wisp * 0.6);

  // The cloud bank: billows, shade towards the bottom and in the folds,
  // and a bright lip where it meets the sky.
  float b = fbm(n * 2.4 + vec2(uDrift * 3.0, -t * 0.04) + 11.0);
  float b2 = fbm(n * 5.0 - vec2(uDrift * 5.0, 0.0) + 3.7);
  float depth = clamp((yy - horizon) / max(1.0 - horizon, 0.25), 0.0, 1.0);
  float shade = clamp(0.18 + 0.5 * depth - 0.7 * (b - 0.5) - 0.25 * (b2 - 0.5), 0.0, 1.0);
  vec3 cloud = mix(CLOUD, SHADE, shade * 0.8);
  cloud = mix(cloud, CLOUD, (1.0 - smoothstep(0.0, 0.22, depth)) * 0.55);

  vec3 col = mix(sky, cloud, bank);

  // A window, not a ball: only a faint limb.
  float r2 = dot(q, q);
  col *= 1.0 - 0.06 * smoothstep(0.6, 1.0, r2);

  // Muted: desaturate to 35 %, then darken to 0.85.
  float luma = dot(col, vec3(0.299, 0.587, 0.114));
  col = mix(vec3(luma), col, uSat);
  col *= mix(0.85, 1.0, clamp((uSat - 0.35) / 0.65, 0.0, 1.0));
  col *= 1.0 + uBright;

  // 1 dp inner rim highlight.
  float rim = smoothstep(R - 1.0 - aa, R - aa, dist);
  col = mix(col, vec3(1.0), rim * 0.35);

  float a = inside * uOpacity;
  fragColor = vec4(clamp(col, 0.0, 1.0) * a, a);
}
