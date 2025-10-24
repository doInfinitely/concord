//
//  PhysicsThreadView.swift
//  Concord
//
//  Physics-based thread animation for thread view
//

import SwiftUI
import Combine

// MARK: - Physics State Manager
@MainActor
class PhysicsThreadState: ObservableObject {
    @Published var particles: [Particle] = []
    @Published var updateTrigger: Bool = false
    
    private var lastUpdateTime: Date = Date()
    private var lastExcitationTime: Date = Date()
    private var nextExcitationInterval: TimeInterval = 3.0
    private var timer: Timer?
    
    private let particleCount = 200
    private let springConstant: Double = 80.0  // Lower = less stiff, more fluid motion
    private let damping: Double = 0.92  // Lower = more damping, energy dissipates faster
    
    func initialize(height: CGFloat) {
        particles = []
        let spacing = Double(height) / Double(particleCount - 1)
        let restX = 12.0  // Center X position
        
        for i in 0..<particleCount {
            let y = Double(i) * spacing
            let isFixed = (i == 0 || i == particleCount - 1)
            particles.append(Particle(
                y: y,
                x: restX,
                vx: 0,
                restX: restX,
                isFixed: isFixed
            ))
        }
        
        startAnimation(height: height)
    }
    
    func startAnimation(height: CGFloat) {
        timer?.invalidate()
        lastUpdateTime = Date()
        lastExcitationTime = Date()
        
        // Set initial random interval
        nextExcitationInterval = Double.random(in: 3.0...6.0)
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.update(height: height)
            }
        }
    }
    
    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
    
    private func update(height: CGFloat) {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdateTime)
        lastUpdateTime = now
        
        // Update physics
        updatePhysics(deltaTime: dt, height: height)
        
        // Check if we should apply excitation
        if now.timeIntervalSince(lastExcitationTime) >= nextExcitationInterval {
            applyRandomExcitation()
            lastExcitationTime = now
            
            // Set next random interval between 3-6 seconds
            nextExcitationInterval = Double.random(in: 3.0...6.0)
            
            // Debug: Print some particle positions after excitation
            if particles.count > 100 {
                print("🧵 Particle 100 position: x=\(particles[100].x), vx=\(particles[100].vx)")
                print("🧵 Next excitation in \(String(format: "%.1f", nextExcitationInterval))s")
            }
        }
        
        // Toggle trigger to force SwiftUI to redraw
        updateTrigger.toggle()
    }
    
    private func updatePhysics(deltaTime: Double, height: CGFloat) {
        guard !particles.isEmpty else { return }
        
        let dt = min(deltaTime, 1.0 / 60.0) // Cap dt for stability
        
        // Calculate forces on each particle (horizontal displacement)
        for i in 0..<particles.count {
            if particles[i].isFixed { continue }
            
            var force: Double = 0
            
            // Spring force to previous particle (horizontal)
            if i > 0 {
                let dist = particles[i].x - particles[i - 1].x
                let springForce = -springConstant * dist  // Springs want to align
                force += springForce
            }
            
            // Spring force to next particle (horizontal)
            if i < particles.count - 1 {
                let dist = particles[i].x - particles[i + 1].x
                let springForce = -springConstant * dist
                force += springForce
            }
            
            // Restoring force to center position
            let restoringForce = -springConstant * (particles[i].x - particles[i].restX)
            force += restoringForce
            
            // Update velocity and position using simple Euler integration
            particles[i].vx += force * dt
            particles[i].vx *= damping // Apply damping
            particles[i].x += particles[i].vx * dt
            
            // Clamp horizontal displacement (don't go too far left or right)
            particles[i].x = max(-10, min(34, particles[i].x))
        }
    }
    
    private func applyRandomExcitation() {
        // Pick a random particle (not fixed endpoints)
        let excitableRange = 1..<(particles.count - 1)
        guard !excitableRange.isEmpty else { return }
        
        let randomIndex = Int.random(in: excitableRange)
        
        // Apply horizontal displacement (push left or right)
        let displacement = Double.random(in: 200...400) * (Bool.random() ? 1 : -1)
        particles[randomIndex].vx += displacement
        
        print("🧵 Thread excitation at particle \(randomIndex) with velocity: \(displacement)")
    }
    
    deinit {
        timer?.invalidate()
    }
}

// MARK: - Physics Thread View
struct PhysicsThreadView: View {
    let height: CGFloat
    @StateObject private var state = PhysicsThreadState()
    
    private let particleSize: CGFloat = 2.5  // Smaller particles for denser thread
    private let threadX: CGFloat = 12
    
    var body: some View {
        let _ = state.updateTrigger // Force view update when trigger changes
        
        return Canvas { context, size in
            // Draw the thread (connecting particles at their current X positions)
            var path = Path()
            if let first = state.particles.first {
                path.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
                
                for particle in state.particles {
                    path.addLine(to: CGPoint(x: CGFloat(particle.x), y: CGFloat(particle.y)))
                }
            }
            
            context.stroke(path, with: .color(.gray.opacity(0.4)), lineWidth: 1.5)
            
            // Particles are invisible - only the connecting line is drawn
        }
        .frame(width: 50, height: height)  // Wider to accommodate horizontal displacement
        .onAppear {
            state.initialize(height: height)
        }
        .onDisappear {
            state.stopAnimation()
        }
    }
}

// MARK: - Particle Model
struct Particle {
    let y: Double        // Fixed Y position (vertical placement)
    var x: Double        // Current X position (horizontal displacement)
    var vx: Double       // Horizontal velocity
    let restX: Double    // Rest X position
    let isFixed: Bool    // Whether this particle is fixed in place
}

