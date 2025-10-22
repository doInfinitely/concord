//
//  AuthService.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore  // <- ADD THIS
import AuthenticationServices
import CryptoKit
import GoogleSignIn
import FirebaseCore

@MainActor
final class AuthService: ObservableObject {
    @Published var uid: String?
    @Published var user: User?
    @Published var isSignedIn: Bool = false
    @Published var authError: String?
    
    // For Apple Sign In
    private var currentNonce: String?
    private var authStateListener: AuthStateDidChangeListenerHandle?  // <- ADD THIS
    
    init() {
        // Listen to auth state changes and store the listener handle
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.uid = user?.uid
                self?.user = user
                self?.isSignedIn = user != nil
            }
        }
    }
    
    deinit {
        // Remove listener when service is deinitialized
        if let listener = authStateListener {
            Auth.auth().removeStateDidChangeListener(listener)
        }
    }
    
    // MARK: - Anonymous Sign In (for testing)
    func signInAnonymouslyIfNeeded() async {
        if let current = Auth.auth().currentUser {
            uid = current.uid
            user = current
            isSignedIn = true
            return
        }
        do {
            let result = try await Auth.auth().signInAnonymously()
            uid = result.user.uid
            user = result.user
            isSignedIn = true
        } catch {
            authError = error.localizedDescription
            print("Anon sign-in failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Email/Password Sign In
    func signInWithEmail(email: String, password: String) async {
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            uid = result.user.uid
            user = result.user
            isSignedIn = true
            authError = nil
        } catch {
            authError = error.localizedDescription
            print("Email sign-in failed: \(error.localizedDescription)")
        }
    }
    
    func signUpWithEmail(email: String, password: String, displayName: String?) async {
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            uid = result.user.uid
            user = result.user
            isSignedIn = true
            
            // Set display name if provided
            if let displayName = displayName {
                let changeRequest = result.user.createProfileChangeRequest()
                changeRequest.displayName = displayName
                try await changeRequest.commitChanges()
            }
            
            // Create user profile in Firestore
            try await createUserProfile(uid: result.user.uid, email: email, displayName: displayName)
            
            authError = nil
        } catch {
            authError = error.localizedDescription
            print("Email sign-up failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Google Sign In
    func signInWithGoogle() async {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            authError = "Firebase client ID not found"
            return
        }
        
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            authError = "No root view controller found"
            return
        }
        
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)
            let user = result.user
            guard let idToken = user.idToken?.tokenString else {
                authError = "Failed to get ID token"
                return
            }
            
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: user.accessToken.tokenString
            )
            
            let authResult = try await Auth.auth().signIn(with: credential)
            uid = authResult.user.uid
            self.user = authResult.user
            isSignedIn = true
            
            // Create user profile in Firestore
            try await createUserProfile(
                uid: authResult.user.uid,
                email: authResult.user.email,
                displayName: authResult.user.displayName
            )
            
            authError = nil
        } catch {
            authError = error.localizedDescription
            print("Google sign-in failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Apple Sign In
    func signInWithApple(authorization: ASAuthorization) async {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let nonce = currentNonce,
              let appleIDToken = appleIDCredential.identityToken,
              let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
            authError = "Failed to get Apple ID credential"
            return
        }
        
        // Create OAuth credential with proper parameter names
        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        )
        
        do {
            let result = try await Auth.auth().signIn(with: credential)
            uid = result.user.uid
            user = result.user
            isSignedIn = true
            
            // Create user profile in Firestore
            let displayName = [appleIDCredential.fullName?.givenName, appleIDCredential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            
            try await createUserProfile(
                uid: result.user.uid,
                email: appleIDCredential.email ?? result.user.email,
                displayName: displayName.isEmpty ? nil : displayName
            )
            
            authError = nil
        } catch {
            authError = error.localizedDescription
            print("Apple sign-in failed: \(error.localizedDescription)")
        }
    }
    
    func startAppleSignIn() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return sha256(nonce)
    }
    
    // MARK: - Sign Out
    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            uid = nil
            user = nil
            isSignedIn = false
            authError = nil
        } catch {
            authError = error.localizedDescription
            print("Sign out failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helper Methods
    private func createUserProfile(uid: String, email: String?, displayName: String?) async throws {
        let db = Firestore.firestore()
        let userRef = db.collection("users").document(uid)
        
        var data: [String: Any] = [
            "createdAt": FieldValue.serverTimestamp(),
            "lastSeen": FieldValue.serverTimestamp()
        ]
        
        if let email = email {
            data["email"] = email
        }
        if let displayName = displayName {
            data["displayName"] = displayName
        }
        
        try await userRef.setData(data, merge: true)
    }
    
    // MARK: - Apple Sign In Helpers
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = randomBytes.map { byte in
            charset[Int(byte) % charset.count]
        }
        return String(nonce)
    }
    
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap {
            String(format: "%02x", $0)
        }.joined()
        return hashString
    }
}

// MARK: - User Extension
extension User {
    var displayNameOrEmail: String {
        displayName ?? email ?? "User"
    }
}
