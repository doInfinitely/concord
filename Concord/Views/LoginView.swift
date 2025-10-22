//
//  LoginView.swift
//  Concord
//
//  Created by Remy Ochei on 10/21/25.
//

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject var auth: AuthService
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var isSignUp = false
    @State private var showError = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Logo/Header
                VStack(spacing: 8) {
                    Text("Concord")
                        .font(.system(size: 48, weight: .bold))
                    Text("Connect and communicate")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)
                
                Spacer()
                
                // Social Sign In Buttons
                VStack(spacing: 16) {
                    // Apple Sign In
                    SignInWithAppleButton(
                        onRequest: { request in
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = auth.startAppleSignIn()
                        },
                        onCompletion: { result in
                            Task {
                                switch result {
                                case .success(let authorization):
                                    await auth.signInWithApple(authorization: authorization)
                                case .failure(let error):
                                    auth.authError = error.localizedDescription
                                    showError = true
                                }
                            }
                        }
                    )
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .cornerRadius(8)
                    
                    // Google Sign In
                    Button {
                        Task {
                            await auth.signInWithGoogle()
                            if auth.authError != nil {
                                showError = true
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("Continue with Google")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white)
                        .foregroundColor(.black)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal)
                
                // Divider
                HStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 1)
                    Text("or")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 1)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                // Email/Password Form
                VStack(spacing: 16) {
                    if isSignUp {
                        TextField("Display Name", text: $displayName)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.name)
                            .autocapitalization(.words)
                    }
                    
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                    
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(isSignUp ? .newPassword : .password)
                    
                    Button {
                        Task {
                            if isSignUp {
                                await auth.signUpWithEmail(
                                    email: email,
                                    password: password,
                                    displayName: displayName.isEmpty ? nil : displayName
                                )
                            } else {
                                await auth.signInWithEmail(email: email, password: password)
                            }
                            if auth.authError != nil {
                                showError = true
                            }
                        }
                    } label: {
                        Text(isSignUp ? "Sign Up" : "Sign In")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .disabled(email.isEmpty || password.isEmpty || (isSignUp && password.count < 6))
                    
                    Button {
                        withAnimation {
                            isSignUp.toggle()
                        }
                    } label: {
                        Text(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Anonymous Sign In (for testing)
                Button {
                    Task {
                        await auth.signInAnonymouslyIfNeeded()
                        if auth.authError != nil {
                            showError = true
                        }
                    }
                } label: {
                    Text("Continue as Guest")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 32)
            }
            .alert("Authentication Error", isPresented: $showError) {
                Button("OK", role: .cancel) {
                    auth.authError = nil
                }
            } message: {
                Text(auth.authError ?? "An unknown error occurred")
            }
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthService())
}
