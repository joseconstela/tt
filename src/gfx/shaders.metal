#include <metal_stdlib>
using namespace metal;

// One instance = one quad. Must match `Instance` in draw.zig.
struct Instance {
    float4 rect;         // x, y, w, h   (device pixels, origin top-left)
    float4 uv;           // u0, v0, u1, v1: atlas texels for kind 1, normalised for kind 2
    float4 color;        // straight-alpha fill / tint
    float4 border_color; // straight-alpha border colour
    float4 params;       // radius, border width, kind (0 = shape, 1 = atlas mask, 2 = image), unused
    float4 clip;         // x0, y0, x1, y1 clip rectangle (device pixels)
};

struct Uniforms {
    float2 viewport;     // drawable size in pixels
    float2 atlas_size;   // atlas size in texels
};

struct VOut {
    float4 position [[position]];
    float2 local;        // pixel position relative to the quad centre
    float2 uv;
    uint   iid [[flat]];
};

vertex VOut conch_vs(uint vid [[vertex_id]],
                     uint iid [[instance_id]],
                     const device Instance* instances [[buffer(0)]],
                     constant Uniforms& u [[buffer(1)]])
{
    Instance inst = instances[iid];
    float2 corner = float2(float(vid & 1), float((vid >> 1) & 1));
    float2 px = inst.rect.xy + corner * inst.rect.zw;

    VOut o;
    o.position = float4(px.x / u.viewport.x * 2.0 - 1.0,
                        1.0 - px.y / u.viewport.y * 2.0, 0.0, 1.0);
    o.local = (corner - 0.5) * inst.rect.zw;
    o.uv = mix(inst.uv.xy, inst.uv.zw, corner);
    if (inst.params.z < 1.5) o.uv /= u.atlas_size;
    o.iid = iid;
    return o;
}

static float sd_round_rect(float2 p, float2 half_size, float r)
{
    float2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

fragment float4 conch_fs(VOut in [[stage_in]],
                         const device Instance* instances [[buffer(0)]],
                         texture2d<float> atlas [[texture(0)]],
                         texture2d<float> image [[texture(1)]])
{
    constexpr sampler smp(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler img_smp(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    Instance inst = instances[in.iid];

    float2 frag = in.position.xy;
    if (frag.x < inst.clip.x || frag.y < inst.clip.y ||
        frag.x >= inst.clip.z || frag.y >= inst.clip.w) {
        discard_fragment();
    }

    if (inst.params.z > 1.5) {
        // Premultiplied BGRA texture; the tint is straight alpha.
        float4 c = image.sample(img_smp, in.uv);
        return float4(c.rgb * inst.color.rgb * inst.color.a, c.a * inst.color.a);
    }

    if (inst.params.z > 0.5) {
        float cov = atlas.sample(smp, in.uv).r;
        float a = inst.color.a * cov;
        return float4(inst.color.rgb * a, a);
    }

    float2 half_size = inst.rect.zw * 0.5;
    float radius = min(inst.params.x, min(half_size.x, half_size.y));
    float d = sd_round_rect(in.local, half_size, radius);
    float outer = clamp(0.5 - d, 0.0, 1.0);
    float bw = inst.params.y;
    float inner = (bw > 0.0) ? clamp(0.5 - (d + bw), 0.0, 1.0) : outer;
    float ring = max(outer - inner, 0.0);

    float fa = inst.color.a * inner;
    float ba = inst.border_color.a * ring;
    float3 rgb = inst.color.rgb * fa + inst.border_color.rgb * ba;
    return float4(rgb, fa + ba);
}
