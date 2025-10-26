# Metal Fluid Simulation Setup

## Overview
This document describes the Metal-based fluid simulation with GPU-advected particles that has been added to the ConversationListView.

## Files Added

### 1. `Concord/Kernels.metal`
Contains all Metal compute and render kernels for the fluid simulation:
- **Fluid dynamics**: Navier-Stokes solver with advection, diffusion, projection
- **Particle advection**: GPU-based particle movement with RK2 integration
- **Particle rendering**: Point sprite rendering with Gaussian falloff for ink-like appearance

### 2. `Concord/Views/FluidView.swift`
Swift/MetalKit integration:
- **FluidView**: UIViewRepresentable wrapper for MetalKit view
- **FluidBackgroundView**: UIViewController wrapper that handles touch forwarding
- **Coordinator**: Manages Metal resources, pipelines, textures, and rendering

### 3. Modified `Concord/Views/ConversationListView.swift`
- Replaced plain background color with `FluidBackgroundView()`
- Fluid sim renders behind all UI elements

## How It Works

### Touch Handling
The key innovation is **simultaneous touch handling**:
1. `FluidBackgroundViewController` receives all touch events via `touchesBegan` and `touchesMoved`
2. Touches are forwarded to the fluid coordinator to spawn particles
3. The Metal view has `isUserInteractionEnabled = false`, allowing touches to pass through to UI
4. Result: **Both** particle spawning AND UI interactions work simultaneously

### Particle System
- **Capacity**: 20,000 particles (ring buffer)
- **Emission**: 120 particles per frame when touching
- **Advection**: GPU-based using RK2 integration for smooth trajectories
- **Rendering**: Point sprites with Gaussian falloff (soft ink appearance)
- **Culling**: Off-screen particles marked invisible (no compaction needed)

### Fluid Simulation
- **Grid**: 256x256 (configurable in FluidView.swift)
- **Method**: Semi-Lagrangian advection + Jacobi pressure solver
- **Projection**: 18 Jacobi iterations for divergence-free velocity field
- **Runs entirely on GPU at 60-120 FPS**

## Performance Tuning

In `FluidView.swift`, you can adjust:

```swift
fileprivate let N: Int = 256                  // Fluid grid resolution (lower = faster)
fileprivate let particleCapacity = 20000      // Max particles (lower = faster)
fileprivate let emitPerFrame = 120            // Particles spawned per frame
fileprivate let pointSizePx: Float = 3.5      // Particle size (visual only)
fileprivate let particleDarkness: Float = 0.9 // Ink darkness (0-1)
```

For slower devices:
- Reduce `N` to 192 or 128
- Reduce `particleCapacity` to 10000
- Reduce `emitPerFrame` to 60

## Visual Customization

### Particle Appearance
In `Kernels.metal`, fragment shader `particleFS`:
```metal
const float sigma = 0.45;  // 0.3 = sharper, 0.6 = softer
```

### Background Color
In `FluidView.swift`, `makeUIView`:
```swift
v.clearColor = MTLClearColorMake(0.95, 0.95, 0.95, 1)  // Light gray
```

### Ink Color
In `Kernels.metal`, `particleFS`:
```metal
return half4(0.0, 0.0, 0.0, half(a));  // Black ink
```

## Technical Details

### Metal Kernels
1. **kBrush**: Applies force and dye at touch point
2. **kAdvect**: Semi-Lagrangian advection (velocity/dye)
3. **kJacobi**: Jacobi iteration for diffusion
4. **kDivergence**: Computes velocity field divergence
5. **kPressureJacobi**: Solves Poisson equation for pressure
6. **kSubtractGradient**: Projects velocity to be divergence-free
7. **kAdvectParticles**: Moves particles through velocity field
8. **particleVS/FS**: Renders particles as point sprites

### Memory Layout
- **Velocity**: RG16Float (2x 16-bit floats)
- **Pressure/Divergence**: R16Float (1x 16-bit float)
- **Particles**: Shared memory buffer (CPU-writable, GPU-readable)
- **Textures**: Private GPU memory for maximum performance

## Testing
1. Build and run the app in Xcode
2. Navigate to the conversation list
3. Drag your finger across the screen
4. You should see black ink particles spawning and flowing
5. UI interactions (tapping conversations, scrolling, etc.) should work normally

## Troubleshooting

### Metal Validation Errors
If you see Metal API validation errors in Xcode, check:
- Device supports Metal (iPhone 6s or later)
- All texture/buffer bindings are correct
- Thread group sizes are valid for the device

### Performance Issues
- Lower grid resolution (`N`)
- Reduce particle count
- Check GPU profiler in Instruments

### Particles Not Appearing
- Verify `clearColor` is light enough to see black particles
- Check particle count > 0 in debugger
- Ensure Metal view is behind UI in Z-order

## Future Enhancements
- Add color to particles based on velocity
- Implement particle aging/fade-out
- Add vorticity confinement for more turbulent flow
- Multi-touch support for multiple simultaneous particle sources
- Gesture velocity mapping to particle force

