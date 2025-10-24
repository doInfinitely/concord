//
//  NetSimulationView.swift
//  Concord
//
//  Physics-based net simulation for chat header
//

import SwiftUI
import Combine

// MARK: - Net Physics State Manager
@MainActor
class NetPhysicsState: ObservableObject {
    @Published var particles: [NetParticle] = []
    @Published var updateTrigger: Bool = false
    
    private var lastUpdateTime: Date = Date()
    private var lastExcitationTime: Date = Date()
    private var nextExcitationInterval: TimeInterval = 1.5
    private var timer: Timer?
    
    private let gridRows = 25
    private let gridCols = 40
    private let spacing: Double = 12.0  // Much tighter spacing
    private let rotation: Double = -30.0 * .pi / 180.0  // 30 degrees clockwise (negative)
    private let springConstant: Double = 50.0
    private let damping: Double = 0.992  // Higher = less damping, water-like propagation
    
    func initialize(width: CGFloat, height: CGFloat) {
        particles = []
        
        let centerX = Double(width) / 2.0
        let centerY = Double(height) / 2.0
        
        // Create grid of particles
        for row in 0..<gridRows {
            for col in 0..<gridCols {
                // Calculate position in grid space
                let gridX = Double(col) * spacing - (Double(gridCols - 1) * spacing / 2.0)
                let gridY = Double(row) * spacing - (Double(gridRows - 1) * spacing / 2.0)
                
                // Rotate by 30 degrees clockwise
                let rotatedX = gridX * cos(rotation) - gridY * sin(rotation)
                let rotatedY = gridX * sin(rotation) + gridY * cos(rotation)
                
                // Translate to screen center
                let x = centerX + rotatedX
                let y = centerY + rotatedY
                
                particles.append(NetParticle(
                    id: "\(row)-\(col)",
                    row: row,
                    col: col,
                    x: x,
                    y: y,
                    z: 0.0,
                    vz: 0.0
                ))
            }
        }
        
        startAnimation()
    }
    
    func startAnimation() {
        timer?.invalidate()
        lastUpdateTime = Date()
        lastExcitationTime = Date()
        
        // Set initial random interval (very frequent)
        nextExcitationInterval = Double.random(in: 0.2...0.8)
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.update()
            }
        }
    }
    
    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
    
    private func update() {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdateTime)
        lastUpdateTime = now
        
        // Update physics
        updatePhysics(deltaTime: dt)
        
        // Check if we should apply excitation
        if now.timeIntervalSince(lastExcitationTime) >= nextExcitationInterval {
            applyRandomExcitation()
            lastExcitationTime = now
            
            // Set next random interval between 0.2-0.8 seconds (very frequent)
            nextExcitationInterval = Double.random(in: 0.2...0.8)
        }
        
        // Toggle trigger to force SwiftUI to redraw
        updateTrigger.toggle()
    }
    
    private func updatePhysics(deltaTime: Double) {
        guard !particles.isEmpty else { return }
        
        let dt = min(deltaTime, 1.0 / 120.0) // Cap dt for stability at 120fps
        
        // Calculate forces on each particle (Z-axis only)
        for i in 0..<particles.count {
            let row = particles[i].row
            let col = particles[i].col
            
            var force: Double = 0
            
            // Spring forces to 4 neighbors (up, down, left, right)
            let neighbors = [
                (row - 1, col),  // Up
                (row + 1, col),  // Down
                (row, col - 1),  // Left
                (row, col + 1)   // Right
            ]
            
            for (nRow, nCol) in neighbors {
                if let neighborIndex = getParticleIndex(row: nRow, col: nCol) {
                    let zDiff = particles[i].z - particles[neighborIndex].z
                    let springForce = -springConstant * zDiff
                    force += springForce
                }
            }
            
            // Restoring force to z=0
            let restoringForce = -springConstant * particles[i].z
            force += restoringForce
            
            // Update velocity and position using Euler integration
            particles[i].vz += force * dt
            particles[i].vz *= damping // Apply damping
            particles[i].z += particles[i].vz * dt
            
            // Clamp Z displacement
            particles[i].z = max(-15, min(15, particles[i].z))
        }
    }
    
    private func getParticleIndex(row: Int, col: Int) -> Int? {
        guard row >= 0 && row < gridRows && col >= 0 && col < gridCols else {
            return nil
        }
        return row * gridCols + col
    }
    
    private func applyRandomExcitation() {
        // Pick a random particle
        let randomIndex = Int.random(in: 0..<particles.count)
        
        // Apply much stronger Z displacement (into/out of screen)
        let displacement = Double.random(in: 800...1200) * (Bool.random() ? 1 : -1)
        particles[randomIndex].vz += displacement
        
        print("🕸️ Net excitation at particle \(particles[randomIndex].id) with velocity: \(displacement)")
    }
    
    deinit {
        timer?.invalidate()
    }
}

// MARK: - Net Simulation View
struct NetSimulationView: View {
    let width: CGFloat
    let height: CGFloat
    @StateObject private var state = NetPhysicsState()
    
    var body: some View {
        let _ = state.updateTrigger // Force view update when trigger changes
        
        return Canvas { context, size in
            // Draw particles as circles with size based on Z displacement
            for particle in state.particles {
                // Calculate base radius that decreases down the grid (by row)
                let maxRow: CGFloat = 24  // gridRows - 1 (zero-indexed)
                let rowFactor = CGFloat(particle.row) / maxRow  // 0.0 at top to 1.0 at bottom
                let baseRadius: CGFloat = 6.0 - (rowFactor * 5.0)  // 6.0 at top to 1.0 at bottom
                
                // Map Z displacement to radius variation
                let zFactor = CGFloat(particle.z) / 15.0  // Normalize to -1...1
                let radius = baseRadius + (zFactor * 3.0)  // Add Z displacement effect
                let clampedRadius = max(1.0, radius)
                
                // Also use Z for opacity (closer = more opaque)
                let opacity = 0.4 + (Double(zFactor + 1.0) / 2.0) * 0.4  // 0.4 to 0.8 opacity
                
                let rect = CGRect(
                    x: CGFloat(particle.x) - clampedRadius,
                    y: CGFloat(particle.y) - clampedRadius,
                    width: clampedRadius * 2,
                    height: clampedRadius * 2
                )
                
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(.gray.opacity(opacity))
                )
            }
        }
        .frame(width: width, height: height)
        .onAppear {
            state.initialize(width: width, height: height)
        }
        .onDisappear {
            state.stopAnimation()
        }
    }
}

// MARK: - Net Particle Model
struct NetParticle {
    let id: String
    let row: Int
    let col: Int
    let x: Double        // Screen X position (fixed)
    let y: Double        // Screen Y position (fixed)
    var z: Double        // Z displacement (into/out of screen)
    var vz: Double       // Z velocity
}

