//
//  PresenceService.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import Foundation
import FirebaseFirestore

final class PresenceService {
    static let onlineWindow: TimeInterval = 45 // seconds
    private let db = Firestore.firestore()
    private var loopTask: Task<Void, Never>?

    func start(uid: String, intervalSeconds: UInt64 = 25) {
        stop() // in case it was already running
        loopTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.db.collection("users").document(uid)
                        .setData(["lastSeen": FieldValue.serverTimestamp()], merge: true)
                } catch {
                    // optional: print(error.localizedDescription)
                }
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Handy when app becomes active: send one immediate ping.
    func pingOnce(uid: String) {
        Task { [db] in
            try? await db.collection("users").document(uid)
                .setData(["lastSeen": FieldValue.serverTimestamp()], merge: true)
        }
    }
}

