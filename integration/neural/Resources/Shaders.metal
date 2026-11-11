#include <metal_stdlib>
using namespace metal;

constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);

kernel void resizeFrame(texture2d<float, access::sample> source [[texture(0)]],
                        texture2d<float, access::write> output [[texture(1)]],
                        uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 uv = (float2(p) + 0.5f) / float2(output.get_width(), output.get_height());
    output.write(float4(source.sample(imageSampler, uv).rgb, 1), p);
}

// The delta belongs to this exact original frame. Never apply a previous
// frame's neural result to a newer capture: that ghosts moving windows/text.
kernel void compositeFrame(texture2d<float, access::sample> original [[texture(0)]],
                           texture2d<float, access::sample> networkInput [[texture(1)]],
                           texture2d<float, access::sample> networkOutput [[texture(2)]],
                           texture2d<float, access::write> output [[texture(3)]],
                           constant float &split [[buffer(0)]],
                           uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 uv = (float2(p) + 0.5f) / float2(output.get_width(), output.get_height());
    float3 native = original.sample(imageSampler, uv).rgb;
    float3 delta = networkOutput.sample(imageSampler, uv).rgb - networkInput.sample(imageSampler, uv).rgb;
    float3 color = uv.x < split ? native : clamp(native + delta, 0.0f, 1.0f);
    if (split > 0 && split < 1 && abs(float(p.x) - split * output.get_width()) < 1)
        color = float3(0.35, 0.9, 0.7);
    output.write(float4(color, 1), p);
}

struct VertexOutput { float4 position [[position]]; float2 uv; };
vertex VertexOutput screenVertex(uint id [[vertex_id]]) {
    float2 positions[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    float2 uvs[] = {float2(0,1), float2(2,1), float2(0,-1)};
    return {float4(positions[id], 0, 1), uvs[id]};
}
fragment float4 screenFragment(VertexOutput in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
    return float4(frame.sample(imageSampler, in.uv).rgb, 1);
}
