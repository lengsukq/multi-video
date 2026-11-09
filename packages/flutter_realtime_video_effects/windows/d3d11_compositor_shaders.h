#pragma once

// Original Direct3D 11 compute shaders for vendor-neutral Windows effects.
// All textures are R8G8B8A8 but camera bytes remain BGRA on both upload and
// readback, so there is no channel swap or additional pixel copy.
namespace realtime_video_effects {
constexpr const char* kCompositorHlsl = R"HLSL(
cbuffer Parameters : register(b0) {
  uint4 dimensions;  // camera width, height, mask width, height
  uint4 options;     // background width, height, reduced-res blur radius, mode
};
Texture2D<float4> camera_tex : register(t0);
Texture2D<float> person_tex : register(t1);
Texture2D<float4> background_tex : register(t2);
RWTexture2D<float4> result_tex : register(u0);

[numthreads(8, 8, 1)]
void Horizontal(uint3 index : SV_DispatchThreadID) {
  uint2 p = index.xy;
  if (p.x >= options.x || p.y >= options.y) return;
  float4 total = 0;
  uint count = 0;
  int r = min(12, (int)options.z);
  // For 720p+ run the blur pyramid at quarter resolution. Sampling four
  // quadrants of each source block keeps the low-frequency background smooth
  // without an expensive full/half-resolution blur per camera frame.
  int scale = max(2, int((dimensions.x + options.x - 1) / options.x));
  for (int i = -r; i <= r; ++i) {
    int x = clamp(int(p.x) * scale + i * scale, 0, int(dimensions.x) - 1);
    int y = min(int(p.y) * scale, int(dimensions.y) - 1);
    int offset = max(1, scale / 2);
    int x2 = min(x + offset, int(dimensions.x) - 1);
    int y2 = min(y + offset, int(dimensions.y) - 1);
    total += camera_tex.Load(int3(x, y, 0));
    total += camera_tex.Load(int3(x2, y, 0));
    total += camera_tex.Load(int3(x, y2, 0));
    total += camera_tex.Load(int3(x2, y2, 0));
    count += 4;
  }
  result_tex[p] = float4(total.rgb / count, 1);
}

// Second and later blur passes operate entirely on the reduced-resolution
// background. Keep the full-resolution camera input untouched so person
// edges stay sharp and expensive camera sampling happens only once.
[numthreads(8, 8, 1)]
void HorizontalReduced(uint3 index : SV_DispatchThreadID) {
  uint2 p = index.xy;
  if (p.x >= options.x || p.y >= options.y) return;
  float3 total = 0;
  int r = min(12, (int)options.z);
  for (int i = -r; i <= r; ++i) {
    int x = clamp(int(p.x) + i, 0, int(options.x) - 1);
    total += background_tex.Load(int3(x, p.y, 0)).rgb;
  }
  result_tex[p] = float4(total / (r * 2 + 1), 1);
}

[numthreads(8, 8, 1)]
void Vertical(uint3 index : SV_DispatchThreadID) {
  uint2 p = index.xy;
  if (p.x >= options.x || p.y >= options.y) return;
  float4 total = 0;
  int r = min(12, (int)options.z);
  for (int i = -r; i <= r; ++i) {
    int y = clamp(int(p.y) + i, 0, int(options.y) - 1);
    total += background_tex.Load(int3(p.x, y, 0));
  }
  result_tex[p] = float4(total.rgb / (r * 2 + 1), 1);
}

float PersonAlpha(uint2 pixel) {
  float2 uv = ((float2(pixel) + 0.5) *
      float2(dimensions.z, dimensions.w) /
      float2(dimensions.x, dimensions.y)) - 0.5;
  float2 uv0 = floor(uv);
  float2 fraction = saturate(uv - uv0);
  int2 a = clamp(int2(uv0), int2(0, 0),
                 int2(dimensions.z - 1, dimensions.w - 1));
  int2 b = clamp(int2(uv0) + int2(1, 0), int2(0, 0),
                 int2(dimensions.z - 1, dimensions.w - 1));
  int2 c = clamp(int2(uv0) + int2(0, 1), int2(0, 0),
                 int2(dimensions.z - 1, dimensions.w - 1));
  int2 d = clamp(int2(uv0) + int2(1, 1), int2(0, 0),
                 int2(dimensions.z - 1, dimensions.w - 1));
  float upper = lerp(person_tex.Load(int3(a, 0)),
                     person_tex.Load(int3(b, 0)), fraction.x);
  float lower = lerp(person_tex.Load(int3(c, 0)),
                     person_tex.Load(int3(d, 0)), fraction.x);
  return saturate(lerp(upper, lower, fraction.y));
}

[numthreads(8, 8, 1)]
void Composite(uint3 index : SV_DispatchThreadID) {
  uint2 p = index.xy;
  if (p.x >= dimensions.x || p.y >= dimensions.y) return;
  float4 foreground = camera_tex.Load(int3(p, 0));
  if (options.w == 0) {
    result_tex[p] = foreground;
    return;
  }
  float4 background;
  if (options.w == 1) {
    uint scale = max(2, (dimensions.x + options.x - 1) / options.x);
    background = background_tex.Load(int3(
        min(p.x / scale, options.x - 1),
        min(p.y / scale, options.y - 1), 0));
  } else {
    float scaling = max(float(dimensions.x) / options.x,
                        float(dimensions.y) / options.y);
    float2 offset = (float2(dimensions.xy) -
                     float2(options.xy) * scaling) * 0.5;
    float2 coordinate = (float2(p) + 0.5 - offset) / scaling;
    uint2 replacement_pixel = uint2(clamp(coordinate,
        float2(0,0), float2(options.xy - 1)));
    background = background_tex.Load(int3(replacement_pixel, 0));
  }
  float alpha = PersonAlpha(p);
  result_tex[p] = float4(lerp(background.rgb, foreground.rgb, alpha), 1);
}
)HLSL";
}
