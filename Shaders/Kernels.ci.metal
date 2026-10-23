// Core Image kernels of the develop chain, as Metal. tools/build-kernels.sh compiles this file into
// Sources/Kadr/KernelLibrary.swift (the metallib as data), so a build needs no Metal compiler.
// Each one is the exact port of the former Core Image Kernel Language version; KernelTests compares them.
#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" {
namespace coreimage {

// Vignette around `c` (pixels): darkens (amount < 0) or lightens towards white, on a doubly smoothed ramp.
[[stitchable]] float4 vignette(sampler s, float2 c, float radius, float amount, destination dest) {
    float4 p = s.sample(s.coord());
    float d = distance(dest.coord(), c) / radius;
    float k = smoothstep(0.3, 1.0, d);
    k = k * k * (3.0 - 2.0 * k);
    float3 rgb = amount < 0.0 ? p.rgb * (1.0 + amount * 0.95 * k) : p.rgb + (float3(1.0) - p.rgb) * amount * 0.9 * k;
    return float4(rgb, p.a);
}

// a → b by k (LUT strength 0–200%): linear, alpha-blind, never below zero.
[[stitchable]] float4 mixk(sample_t a, sample_t b, float k) {
    return float4(max(a.rgb + (b.rgb - a.rgb) * k, float3(0.0)), a.a);
}

// Film grain: brightness scaled by the noise's red channel around its mid-grey.
[[stitchable]] float4 grain(sample_t s, sample_t n, float a) {
    return float4(s.rgb * (1.0 + (n.r - 0.5) * a), s.a);
}

// AI noise reduction carried over to the base: base + k·(denoised − clamp(base)).
[[stitchable]] float4 dn(sample_t b, sample_t d, float k) {
    float3 c = clamp(b.rgb, 0.0, 1.0);
    return float4(b.rgb + (d.rgb - c) * k, b.a);
}

}
}
