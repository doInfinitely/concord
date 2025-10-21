//
//  AuthService.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import Foundation
import Combine
import FirebaseAuth

@MainActor
final class AuthService: ObservableObject {
    @Published var uid: String?

    func signInAnonymouslyIfNeeded() async {
        if let current = Auth.auth().currentUser { uid = current.uid; return }
        do {
            let result = try await Auth.auth().signInAnonymously()
            uid = result.user.uid
        } catch {
            let ns = error as NSError
            print("Anon sign-in failed:")
            print("  domain=\(ns.domain) code=\(ns.code)")
            print("  desc=\(ns.localizedDescription)")
            print("  userInfo=\(ns.userInfo)")
        }
    }
}
