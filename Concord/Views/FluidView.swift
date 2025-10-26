import SwiftUI
import MetalKit

// ===== Config (tuned for MAXIMUM calm, zen-like fluid behavior) =====
fileprivate let N: Int = 64                   // Higher resolution for smoother flow
fileprivate let jacobiIters = 24              // Maximum iterations for ultra stability
fileprivate let visc: Float = 0.0             // Zero viscosity
fileprivate let dt: Float = 1.0/60.0          // Standard timestep

// Particles
fileprivate let particleCapacity = 20000
fileprivate let emitPerFrame = 5              // Minimal particles for zen calm
fileprivate let emitRadius = 0.05 as Float    // Moderate spread
fileprivate let pointSizePx: Float = 48.0     // Large particles for visibility
fileprivate let particleDarkness: Float = 1.0 // Fully opaque

struct FluidView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.framebufferOnly = false
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.preferredFramesPerSecond = 120
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColorMake(0.95, 0.95, 0.95, 1)
        v.delegate = context.coordinator
        v.isUserInteractionEnabled = false // Allow touches to pass through
        
        context.coordinator.view = v
        context.coordinator.setup()
        return v
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        var device: MTLDevice!
        var queue: MTLCommandQueue!
        var lib: MTLLibrary!

        // Pipelines
        var pClear: MTLComputePipelineState!
        var pBrush: MTLComputePipelineState!
        var pAdvect: MTLComputePipelineState!
        var pJacobi: MTLComputePipelineState!
        var pDivergence: MTLComputePipelineState!
        var pPressureJacobi: MTLComputePipelineState!
        var pSubtractGradient: MTLComputePipelineState!
        var pAdvectParticles: MTLComputePipelineState!

        // Particle render
        var psoParticles: MTLRenderPipelineState!

        // Textures (ping-pong)
        var velA, velB: MTLTexture!      // RG16F
        var divTex: MTLTexture!          // R16F
        var pressA, pressB: MTLTexture!  // R16F
        // Dye is optional; keeping it for completeness (not drawn here)
        var dyeA, dyeB: MTLTexture!

        // Buffers
        var paramsBuf: MTLBuffer!
        var brushBuf: MTLBuffer!
        var particlesBuf: MTLBuffer!
        var particleRenderParams: MTLBuffer!
        var stepBuf: MTLBuffer!   // uint step counter

        // State
        weak var view: MTKView?
        var lastTouch: SIMD2<Float> = .zero // normalized
        var prevTouch: SIMD2<Float> = .zero // for velocity calculation
        var dragging = false
        var stepCount: UInt32 = 0
        var particleHead = 0 // ring buffer index
        var particleCount = 0
        var frameCount = 0

        // Mirror structs (match Kernels.metal)
        struct SimParams {
            var N: UInt32
            var dt: Float
            var visc: Float
            var invTexSize: SIMD2<Float>
            var dyeDissipation: Float
        }
        struct Brush {
            var pos: SIMD2<Float>
            var force: SIMD2<Float>
            var radius: Float
            var strength: Float
            var enabled: UInt32
        }
        struct Particle {
            var pos: SIMD2<Float>
            var alive: Float
        }
        struct ParticleRenderParams {
            var pointSizePx: Float
            var darkness: Float
            var viewport: SIMD2<Float>
        }

        // MARK: Setup
        func setup() {
            guard let dev = MTLCreateSystemDefaultDevice() else { return }
            device = dev
            queue = device.makeCommandQueue()
            lib = try! device.makeDefaultLibrary(bundle: .main)

            func cp(_ name: String) -> MTLComputePipelineState {
                try! device.makeComputePipelineState(function: lib.makeFunction(name: name)!)
            }
            pClear = cp("kClear")
            pBrush = cp("kBrush")
            pAdvect = cp("kAdvect")
            pJacobi = cp("kJacobi")
            pDivergence = cp("kDivergence")
            pPressureJacobi = cp("kPressureJacobi")
            pSubtractGradient = cp("kSubtractGradient")
            pAdvectParticles = cp("kAdvectParticles")

            // Particle render pipeline
            let vfn = lib.makeFunction(name: "particleVS")!
            let ffn = lib.makeFunction(name: "particleFS")!
            let rp = MTLRenderPipelineDescriptor()
            rp.vertexFunction = vfn
            rp.fragmentFunction = ffn
            rp.colorAttachments[0].pixelFormat = .bgra8Unorm
            // Alpha blending: black ink darkens white background
            let att = rp.colorAttachments[0]!
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.sourceAlphaBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            psoParticles = try! device.makeRenderPipelineState(descriptor: rp)

            makeTextures()
            makeBuffers()
            // Don't seed initial particles - they all die at once!
            // Particles only spawn from user touch
        }

        func makeTextures() {
            func makeTex(_ fmt: MTLPixelFormat) -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: N, height: N, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                return device.makeTexture(descriptor: d)!
            }
            velA = makeTex(.rg16Float); velB = makeTex(.rg16Float)
            divTex = makeTex(.r16Float)
            pressA = makeTex(.r16Float); pressB = makeTex(.r16Float)
            dyeA = makeTex(.rgba8Unorm); dyeB = makeTex(.rgba8Unorm)
            
            // CRITICAL: Clear all textures to zero (prevent NaN!)
            let cmd = queue.makeCommandBuffer()!
            let compute = cmd.makeComputeCommandEncoder()!
            compute.setComputePipelineState(pClear)
            
            for tex in [velA!, velB!, divTex!, pressA!, pressB!, dyeA!, dyeB!] {
                compute.setTexture(tex, index: 0)
                dispatch2D(compute, N, N)
            }
            
            compute.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        func makeBuffers() {
            paramsBuf = device.makeBuffer(length: MemoryLayout<SimParams>.stride, options: .storageModeShared)
            brushBuf  = device.makeBuffer(length: MemoryLayout<Brush>.stride, options: .storageModeShared)
            stepBuf   = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)

            particlesBuf = device.makeBuffer(length: MemoryLayout<Particle>.stride * particleCapacity,
                                             options: .storageModeShared)

            particleRenderParams = device.makeBuffer(length: MemoryLayout<ParticleRenderParams>.stride,
                                                     options: .storageModeShared)

            // Initialize particles dead
            let p = particlesBuf.contents().bindMemory(to: Particle.self, capacity: particleCapacity)
            for i in 0..<particleCapacity {
                p[i] = Particle(pos: SIMD2<Float>(-1, -1), alive: 0)
            }
        }

        func seedParticles(count: Int) {
            let p = particlesBuf.contents().bindMemory(to: Particle.self, capacity: particleCapacity)
            let c = min(count, particleCapacity)
            for i in 0..<c {
                // Spread particles more widely across screen
                let x = Float.random(in: 0.2...0.8)
                let y = Float.random(in: 0.2...0.8)
                let pos = SIMD2<Float>(x, y)
                p[i] = Particle(pos: pos, alive: 1)
            }
            particleHead = c % particleCapacity
            particleCount = max(particleCount, c)
        }
        
        // MARK: Public touch handling (called from wrapper)
        func handleTouch(at location: CGPoint, in bounds: CGRect, isMoving: Bool) {
            // Clamp UV to valid range [0,1]
            let x = Float(max(0, min(1, location.x / bounds.width)))
            let y = Float(max(0, min(1, location.y / bounds.height)))
            let uv = SIMD2<Float>(x, y)
            
            emitParticles(at: uv, count: emitPerFrame)
            
            if isMoving {
                dragging = true
            }
            prevTouch = lastTouch
            lastTouch = uv
        }

        func emitParticles(at uv: SIMD2<Float>, count: Int) {
            let pbuf = particlesBuf.contents().bindMemory(to: Particle.self, capacity: particleCapacity)
            
            for _ in 0..<count {
                let ang = Float.random(in: 0..<(2 * .pi))
                let r = Float.random(in: 0..<1).squareRoot() * emitRadius
                let pos = uv + SIMD2<Float>(r * cos(ang), r * sin(ang))
                
                // Use ring buffer - lifetime system handles recycling naturally
                pbuf[particleHead] = Particle(pos: pos, alive: 1)
                particleHead = (particleHead + 1) % particleCapacity
                particleCount = min(particleCount + 1, particleCapacity)
            }
        }

        // MARK: MTKViewDelegate
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let cmd = queue.makeCommandBuffer(),
                  let compute = cmd.makeComputeCommandEncoder()
            else { return }

            // --- Update params ---
            var P = SimParams(N: UInt32(N),
                              dt: dt,
                              visc: visc,
                              invTexSize: SIMD2<Float>(1.0/Float(N), 1.0/Float(N)),
                              dyeDissipation: 1.0)
            memcpy(paramsBuf.contents(), &P, MemoryLayout<SimParams>.stride)

            // Calculate touch velocity for force (ZEN-LIKE calm for maximum serenity)
            let touchVelocity = (lastTouch - prevTouch) / dt  // pixels/sec in normalized coords
            let forceGain: Float = 0.08 * Float(N)            // Zen gentle (was 0.15, originally 10.0)
            let force = dragging ? touchVelocity * forceGain : SIMD2<Float>(0, 0)
            
            var B = Brush(pos: lastTouch,
                          force: force,
                          radius: 0.12,  // Match Python DRAG_RADIUS_PX / W (64/800 ≈ 0.08, but make a bit bigger)
                          strength: dragging ? 1.0 : 0.0,
                          enabled: dragging ? 1 : 0)
            
            memcpy(brushBuf.contents(), &B, MemoryLayout<Brush>.stride)
            
            // Debug logging disabled for performance

            // Step counter for RNG in particle kernel
            stepCount &+= 1
            memcpy(stepBuf.contents(), &stepCount, MemoryLayout<UInt32>.stride)

            // --- FULL FLUID SIMULATION (matching Python stable_fluids) ---
            
            // 1. Apply brush force (add source) - now with ping-pong
            compute.setComputePipelineState(pBrush)
            compute.setTexture(velA, index: 0)
            compute.setTexture(dyeA, index: 1)
            compute.setTexture(velB, index: 2)
            compute.setTexture(dyeB, index: 3)
            compute.setBuffer(paramsBuf, offset: 0, index: 0)
            compute.setBuffer(brushBuf,  offset: 0, index: 1)
            dispatch2D(compute, N, N)
            swap(&velA, &velB)
            swap(&dyeA, &dyeB)
            
            // 2. SKIP Diffuse velocity (it's producing NaN, disable for now)
            // The Python version has visc=0.00035 but we'll skip it to isolate the issue
            if false && visc > 0.0001 {
                // Jacobi iterations for diffusion
                for _ in 0..<4 {
                    compute.setComputePipelineState(pJacobi)
                    compute.setTexture(velA, index: 0)
                    compute.setTexture(velA, index: 1)  // use itself as source
                    compute.setTexture(velB, index: 2)
                    compute.setBuffer(paramsBuf, offset: 0, index: 0)
                    dispatch2D(compute, N, N)
                    swap(&velA, &velB)  // ping-pong
                }
            }
            
            // 3. PROJECT: Make velocity field divergence-free (incompressible)
            // Compute divergence
            compute.setComputePipelineState(pDivergence)
            compute.setTexture(velA, index: 0)
            compute.setTexture(divTex, index: 1)
            compute.setBuffer(paramsBuf, offset: 0, index: 0)
            dispatch2D(compute, N, N)
            
            // CRITICAL: Clear pressure to zero before solving (prevent accumulation!)
            compute.setComputePipelineState(pClear)
            compute.setTexture(pressA, index: 0)
            dispatch2D(compute, N, N)
            compute.setTexture(pressB, index: 0)
            dispatch2D(compute, N, N)
            
            // Solve for pressure using Jacobi iterations (smoother convergence)
            for _ in 0..<jacobiIters {
                compute.setComputePipelineState(pPressureJacobi)
                compute.setTexture(pressA, index: 0)
                compute.setTexture(divTex, index: 1)
                compute.setTexture(pressB, index: 2)
                compute.setBuffer(paramsBuf, offset: 0, index: 0)
                dispatch2D(compute, N, N)
                swap(&pressA, &pressB)
            }
            
            // Subtract pressure gradient from velocity
            compute.setComputePipelineState(pSubtractGradient)
            compute.setTexture(pressA, index: 0)
            compute.setTexture(velA, index: 1)
            compute.setTexture(velB, index: 2)
            compute.setBuffer(paramsBuf, offset: 0, index: 0)
            dispatch2D(compute, N, N)
            swap(&velA, &velB)
            
            // 4. Advect velocity (makes it flow and persist!)
            compute.setComputePipelineState(pAdvect)
            compute.setTexture(velA, index: 0)
            compute.setTexture(velA, index: 1)
            compute.setTexture(velB, index: 2)
            compute.setBuffer(paramsBuf, offset: 0, index: 0)
            dispatch2D(compute, N, N)
            swap(&velA, &velB)
            
            // 5. SKIP second projection for debugging
            if false {
                compute.setComputePipelineState(pDivergence)
                compute.setTexture(velA, index: 0)
                compute.setTexture(divTex, index: 1)
                compute.setBuffer(paramsBuf, offset: 0, index: 0)
                dispatch2D(compute, N, N)
                
                for _ in 0..<jacobiIters {
                    compute.setComputePipelineState(pPressureJacobi)
                    compute.setTexture(pressA, index: 0)
                    compute.setTexture(divTex, index: 1)
                    compute.setTexture(pressB, index: 2)
                    compute.setBuffer(paramsBuf, offset: 0, index: 0)
                    dispatch2D(compute, N, N)
                    swap(&pressA, &pressB)
                }
                
                compute.setComputePipelineState(pSubtractGradient)
                compute.setTexture(pressA, index: 0)
                compute.setTexture(velA, index: 1)
                compute.setTexture(velB, index: 2)
                compute.setBuffer(paramsBuf, offset: 0, index: 0)
                dispatch2D(compute, N, N)
                swap(&velA, &velB)
            }
            
            // --- Advect particles on the GPU ---
            compute.setComputePipelineState(pAdvectParticles)
            compute.setTexture(velA, index: 0)
            compute.setBuffer(particlesBuf, offset: 0, index: 0)
            compute.setBuffer(paramsBuf,    offset: 0, index: 1)
            compute.setBuffer(stepBuf,      offset: 0, index: 2)
            // Dispatch for ALL particle slots (ring buffer needs all indices updated)
            dispatch1D(compute, particleCapacity)

            compute.endEncoding()
            
            // CRITICAL: Wait for compute to finish before rendering
            cmd.commit()
            cmd.waitUntilCompleted()
            
            // Create NEW command buffer for rendering (with updated particle data)
            guard let renderCmd = queue.makeCommandBuffer() else { return }

            // --- Render particles ---
            guard let drawable = view.currentDrawable else { renderCmd.commit(); return }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = drawable.texture
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = view.clearColor
            rp.colorAttachments[0].storeAction = .store

            let renc = renderCmd.makeRenderCommandEncoder(descriptor: rp)!
            renc.setRenderPipelineState(psoParticles)

            // Particle render params
            var PR = ParticleRenderParams(pointSizePx: pointSizePx,
                                          darkness: particleDarkness,
                                          viewport: SIMD2<Float>(Float(view.drawableSize.width),
                                                                 Float(view.drawableSize.height)))
            memcpy(particleRenderParams.contents(), &PR, MemoryLayout<ParticleRenderParams>.stride)

            renc.setVertexBuffer(particlesBuf, offset: 0, index: 0)
            renc.setVertexBuffer(particleRenderParams, offset: 0, index: 1)
            // Render ALL particle slots (ring buffer uses all indices)
            renc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCapacity)
            renc.endEncoding()

            renderCmd.present(drawable)
            renderCmd.commit()
            
            // Debug logging disabled for UI performance
            
            frameCount += 1
        }

        // MARK: dispatch helpers
        func dispatch2D(_ enc: MTLComputeCommandEncoder, _ w: Int, _ h: Int) {
            // Use threadgroups dispatch for simulator compatibility
            let tw = 16
            let th = 16
            let tg = MTLSize(width: tw, height: th, depth: 1)
            // Calculate number of threadgroups needed
            let numGroupsX = (w + tw - 1) / tw
            let numGroupsY = (h + th - 1) / th
            let numGroups = MTLSize(width: numGroupsX, height: numGroupsY, depth: 1)
            enc.dispatchThreadgroups(numGroups, threadsPerThreadgroup: tg)
        }
        func dispatch1D(_ enc: MTLComputeCommandEncoder, _ count: Int) {
            // Use threadgroups dispatch for simulator compatibility
            let tw = 64
            let tg = MTLSize(width: tw, height: 1, depth: 1)
            // Calculate number of threadgroups needed
            let numGroups = MTLSize(width: (count + tw - 1) / tw, height: 1, depth: 1)
            enc.dispatchThreadgroups(numGroups, threadsPerThreadgroup: tg)
        }
    }
}

// MARK: - Touch-Forwarding Wrapper
// This wrapper allows both UI interaction AND particle spawning
struct FluidBackgroundView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FluidBackgroundViewController {
        let vc = FluidBackgroundViewController()
        // Don't set forwarder here - metalView doesn't exist yet!
        // It will be set in viewDidLoad
        return vc
    }
    
    func updateUIViewController(_ uiViewController: FluidBackgroundViewController, context: Context) {}
}

// Singleton to forward touches from SwiftUI overlay to fluid coordinator
class FluidTouchForwarder {
    static let shared = FluidTouchForwarder()
    weak var coordinator: FluidView.Coordinator?
    weak var metalView: MTKView?
    private var lastForwardTime = Date.distantPast
    
    func handleTouch(at globalLocation: CGPoint) {
        // Throttle to ~30fps to prevent UI lag
        let now = Date()
        guard now.timeIntervalSince(lastForwardTime) > 0.033 else { return }
        lastForwardTime = now
        
        guard let view = metalView else { return }
        
        // Convert global screen coordinates to metalView's local coordinates
        let localLocation = view.convert(globalLocation, from: nil)
        
        coordinator?.handleTouch(at: localLocation, in: view.bounds, isMoving: true)
    }
    
    func endDrag() {
        coordinator?.dragging = false
    }
}

class FluidBackgroundViewController: UIViewController {
    var fluidCoordinator: FluidView.Coordinator?
    var metalView: MTKView?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // CRITICAL: Make the view controller's view NOT block touches!
        view.isUserInteractionEnabled = false
        
        // Create the coordinator and Metal view
        let coordinator = FluidView.Coordinator()
        fluidCoordinator = coordinator
        
        let metalView = MTKView()
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.framebufferOnly = false
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 120
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColorMake(0.95, 0.95, 0.95, 1)
        metalView.delegate = coordinator
        metalView.isUserInteractionEnabled = false  // Don't intercept touches
        
        coordinator.view = metalView
        coordinator.setup()
        
        self.metalView = metalView
        metalView.frame = view.bounds
        metalView.autoresizingMask = [UIView.AutoresizingMask.flexibleWidth, UIView.AutoresizingMask.flexibleHeight]
        view.addSubview(metalView)
        
        // Set up the touch forwarder (metalView exists now!)
        // Touches are forwarded from SwiftUI's simultaneousGesture in ConversationListView
        FluidTouchForwarder.shared.coordinator = coordinator
        FluidTouchForwarder.shared.metalView = metalView
    }
}

