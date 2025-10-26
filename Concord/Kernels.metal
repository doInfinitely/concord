#include <metal_stdlib>
using namespace metal;

// =================== Shared structs ===================
struct SimParams {
    uint   N;               // grid size (e.g., 256)
    float  dt;              // timestep (s)
    float  visc;            // viscosity
    float2 invTexSize;      // 1/N, 1/N (in grid cells)
    float  dyeDissipation;  // not used by particles, kept for completeness
};

struct Brush {
    float2 pos;     // in [0,1]
    float2 force;   // cells/sec
    float  radius;  // in [0..1]
    float  strength;
    uint   enabled; // 0/1
};

struct Particle {
    float2 pos;     // normalized [0,1]
    float  alive;   // >0 means render; <=0 invisible
};

// ============== Samplers & utils ==============
constant sampler linClamped(address::clamp_to_edge, filter::linear);

inline float2 uvFromIJ(uint2 ij, constant SimParams& P) {
    return saturate((float2(ij) + 0.5f) * P.invTexSize);
}
inline float2 sampleVel(texture2d<half, access::sample> vel, float2 uv) {
    return float2(vel.sample(linClamped, uv).rg);
}
inline float sampleScalar(texture2d<half, access::sample> t, float2 uv) {
    return float(t.sample(linClamped, uv).r);
}

// =================== Clear texture ===================
kernel void kClear(
    texture2d<half, access::write> tex [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    tex.write(half4(0, 0, 0, 0), gid);
}

// =================== Brush (force + dye) ===================
kernel void kBrush(
    texture2d<half, access::sample> velIn   [[texture(0)]],
    texture2d<half, access::sample> dyeIn   [[texture(1)]],
    texture2d<half, access::write>  velOut  [[texture(2)]],
    texture2d<half, access::write>  dyeOut  [[texture(3)]],
    constant SimParams& P                    [[buffer(0)]],
    constant Brush& B                        [[buffer(1)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    const float2 uv = uvFromIJ(gid, P);
    
    // Start with existing values
    half2 v = half2(sampleVel(velIn, uv));
    half4 dye = dyeIn.sample(linClamped, uv);
    
    // Apply brush if enabled
    if (B.enabled) {
        const float2 d  = uv - B.pos;
        const float  r  = B.radius;
        if (r > 0.0f) {
            const float d2 = dot(d,d);
            if (d2 <= r*r) {
                float w = 1.0f - (d2 / (r*r));  // smooth falloff
                w *= w;

                // Add velocity impulse
                v += half2(B.force * (B.strength * w));

                // Optional: add dye (greyscale)
                half nd = clamp(dye.r + half(B.strength * 0.6f * w), half(0), half(1));
                dye = half4(nd, nd, nd, half(1));
            }
        }
    }
    
    // Safety check for NaN
    if (isnan(v.x) || isnan(v.y) || isinf(v.x) || isinf(v.y)) {
        v = half2(0, 0);
    }
    
    velOut.write(half4(v,0,1), gid);
    dyeOut.write(dye, gid);
}

// =================== Advect field (semi-Lagrangian) ===================
kernel void kAdvect(
    texture2d<half, access::sample>  src     [[texture(0)]],
    texture2d<half, access::sample>  velTex  [[texture(1)]],
    texture2d<half, access::write>   dst     [[texture(2)]],
    constant SimParams& P                     [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    float2 uv   = uvFromIJ(gid, P);
    float2 v    = sampleVel(velTex, uv);
    float2 prev = uv - v * (P.dt * P.invTexSize);
    half4 s = src.sample(linClamped, prev);
    // NO damping - preserve velocity!
    dst.write(s, gid);
}

// =================== Diffuse (Jacobi) ===================
kernel void kJacobi(
    texture2d<half, access::sample>  xTex    [[texture(0)]],
    texture2d<half, access::sample>  bTex    [[texture(1)]],
    texture2d<half, access::write>   xOut    [[texture(2)]],
    constant SimParams& P                     [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    const float2 uv = uvFromIJ(gid, P);
    const float2 du = float2(P.invTexSize.x, 0);
    const float2 dv = float2(0, P.invTexSize.y);

    float4 l = float4(xTex.sample(linClamped, uv - du));
    float4 r = float4(xTex.sample(linClamped, uv + du));
    float4 d = float4(xTex.sample(linClamped, uv - dv));
    float4 u = float4(xTex.sample(linClamped, uv + dv));
    float4 b = float4(bTex.sample(linClamped, uv));

    float a = P.visc * P.dt * float(P.N * P.N);
    float c = 1.0f + 4.0f * a;
    float4 x = (b + a * (l + r + d + u)) / c;
    xOut.write(half4(x), gid);
}

// =================== Divergence, Pressure, Subtract Grad ===================
kernel void kDivergence(
    texture2d<half, access::sample>  velTex  [[texture(0)]],
    texture2d<half, access::write>   divOut  [[texture(1)]],
    constant SimParams& P                     [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    const float2 uv = uvFromIJ(gid, P);
    const float2 du = float2(P.invTexSize.x, 0);
    const float2 dv = float2(0, P.invTexSize.y);

    const float2 vl = sampleVel(velTex, uv - du);
    const float2 vr = sampleVel(velTex, uv + du);
    const float2 vd = sampleVel(velTex, uv - dv);
    const float2 vu = sampleVel(velTex, uv + dv);

    // Divergence without massive scaling (we're in grid space already)
    const float div = 0.5f * ((vr.x - vl.x) + (vu.y - vd.y));
    divOut.write(half4(div,0,0,1), gid);
}

kernel void kPressureJacobi(
    texture2d<half, access::sample>  pTex    [[texture(0)]],
    texture2d<half, access::sample>  divTex  [[texture(1)]],
    texture2d<half, access::write>   pOut    [[texture(2)]],
    constant SimParams& P                     [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    const float2 uv = uvFromIJ(gid, P);
    const float2 du = float2(P.invTexSize.x, 0);
    const float2 dv = float2(0, P.invTexSize.y);

    const float pl = sampleScalar(pTex, uv - du);
    const float pr = sampleScalar(pTex, uv + du);
    const float pd = sampleScalar(pTex, uv - dv);
    const float pu = sampleScalar(pTex, uv + dv);
    const float b  = sampleScalar(divTex, uv);

    const float p = (pl + pr + pd + pu - b) * 0.25f;
    pOut.write(half4(p,0,0,1), gid);
}

kernel void kSubtractGradient(
    texture2d<half, access::sample>  pTex    [[texture(0)]],
    texture2d<half, access::sample>  velIn   [[texture(1)]],
    texture2d<half, access::write>   velOut  [[texture(2)]],
    constant SimParams& P                     [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    const float2 uv = uvFromIJ(gid, P);
    const float2 du = float2(P.invTexSize.x, 0);
    const float2 dv = float2(0, P.invTexSize.y);

    const float pl = sampleScalar(pTex, uv - du);
    const float pr = sampleScalar(pTex, uv + du);
    const float pd = sampleScalar(pTex, uv - dv);
    const float pu = sampleScalar(pTex, uv + dv);

    // Gradient without massive scaling (matches divergence scaling)
    const float2 grad = 0.5f * float2(pr - pl, pu - pd);
    float2 v = sampleVel(velIn, uv);
    v -= grad;
    
    // Safety check for NaN
    if (isnan(v.x) || isnan(v.y) || isinf(v.x) || isinf(v.y)) {
        v = float2(0, 0);
    }
    
    velOut.write(half4(half2(v),0,1), gid);
}

// =================== PARTICLES ===================
inline float rand01(uint id, uint step) {
    // Tiny integer hash
    uint x = id * 1664525u + 1013904223u + step * 374761393u;
    x ^= x >> 17; x *= 0x85ebca6bu; x ^= x >> 13; x *= 0xc2b2ae35u; x ^= x >> 16;
    return float(x) / float(0xffffffffu);
}

kernel void kAdvectParticles(
    texture2d<half, access::sample> velTex    [[texture(0)]],
    device Particle*                particles [[buffer(0)]],
    constant SimParams&             P         [[buffer(1)]],
    constant uint&                  stepCount [[buffer(2)]],
    uint gid                                    [[thread_position_in_grid]])
{
    // CRITICAL FIX: Use direct reference instead of copying struct
    device Particle& p = particles[gid];
    
    if (p.alive <= 0.0f) {
        return;  // Don't touch dead particles
    }

    // Gradually fade out particles
    p.alive -= 0.0001f;
    if (p.alive <= 0.0f) {
        p.alive = 0.0f;
        return;
    }

    // Sample velocity from fluid field
    float2 vel = sampleVel(velTex, p.pos);
    
    // Check for invalid velocities and replace with zero
    if (isnan(vel.x) || isnan(vel.y) || isinf(vel.x) || isinf(vel.y)) {
        vel = float2(0, 0);
    }
    
    // Clamp velocity to safe range
    vel = clamp(vel, float2(-50.0), float2(50.0));
    
    // Apply velocity to particle (velocity is in grid cells/sec, scale appropriately)
    // Use very small multiplier for ultra-calm, gentle movement
    float2 displacement = P.dt * vel * P.invTexSize * 10.0f;
    p.pos.x += displacement.x;
    p.pos.y += displacement.y;
    
    // Wrap particles at edges (don't kill them)
    if (p.pos.x < 0.0f) p.pos.x += 1.0f;
    if (p.pos.x > 1.0f) p.pos.x -= 1.0f;
    if (p.pos.y < 0.0f) p.pos.y += 1.0f;
    if (p.pos.y > 1.0f) p.pos.y -= 1.0f;
    
    // Final safety check
    if (isnan(p.pos.x) || isnan(p.pos.y)) {
        p.alive = 0.0f;
    }
}

// =================== Particle render shaders ===================
struct VSOut {
    float4 pos [[position]];
    float  size [[point_size]];
    float2 uv;
    float  alpha;
};

struct ParticleRenderParams {
    float pointSizePx;   // particle radius in pixels (point size)
    float darkness;      // 0..1 multiplier (ink darkness)
    float2 viewport;     // w,h in pixels
};

vertex VSOut particleVS(
    const device Particle* particles   [[buffer(0)]],
    constant ParticleRenderParams& RP  [[buffer(1)]],
    uint vid                           [[vertex_id]])
{
    Particle p = particles[vid];
    VSOut o;
    if (p.alive <= 0.0f) {
        // Move off-screen and set size zero to skip rasterization cost
        o.pos = float4(-2.0, -2.0, 0.0, 1.0);
        o.size = 0.0;
        o.uv = float2(0);
        o.alpha = 0.0;
        return o;
    }
    // uv [0,1] -> clip [-1,1], Metal's Y is up; UIKit provides touches in Y-down, but we already store normalized.
    float2 clip = float2(p.pos.x * 2.0 - 1.0, 1.0 - p.pos.y * 2.0);
    o.pos = float4(clip, 0.0, 1.0);
    o.size = RP.pointSizePx;   // screen-space size
    o.uv = float2(0.0);        // unused in VS
    // Use alive as alpha so particles fade out smoothly
    o.alpha = clamp(p.alive, 0.0, 1.0) * RP.darkness;
    return o;
}

// Fragment shades a circular Gaussian falloff (black ink on white with alpha blending)
fragment half4 particleFS(VSOut in [[stage_in]],
                          float2 pointCoord [[point_coord]])
{
    float2 d = pointCoord * 2.0 - 1.0;      // center at 0
    float r2 = dot(d,d);            // 0 at center, 1 at edge (circle)
    if (r2 > 1.0) discard_fragment();

    // Gaussian falloff; adjust softness as desired
    const float sigma = 0.45;       // 0.3 sharper, 0.6 softer
    float g = exp(-r2 / (2.0 * sigma * sigma));

    float a = clamp(g, 0.0, 1.0) * in.alpha;   // alpha
    return half4(0.0, 0.0, 0.0, half(a));      // black ink
}

