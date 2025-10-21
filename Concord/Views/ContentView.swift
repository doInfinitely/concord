//
//  ContentView.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @StateObject private var auth = AuthService()
    private let store = FirestoreService()

    @State private var conversationId: String?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Hello, Concord 👋").font(.largeTitle).bold()

                if let uid = auth.uid {
                    Text("UID: \(uid)").font(.footnote).opacity(0.6)
                }

                if let err = errorText {
                    Text(err).foregroundStyle(.red)
                }

                if let convId = conversationId {
                    NavigationLink("Open Test Chat", value: convId)
                        .buttonStyle(.borderedProminent)
                } else if isLoading {
                    ProgressView()
                } else {
                    Button("Create Test Conversation") {
                        Task { await createOrLoadTestConversation() }
                    }
                }
            }
            .padding()
            .navigationDestination(item: $conversationId) { convId in
                ChatView(conversationId: convId)
            }
            .task {
                await auth.signInAnonymouslyIfNeeded()
                await createOrLoadTestConversation()
            }
        }
    }

    @MainActor
    private func createOrLoadTestConversation() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let convId = try await store.createSelfConversationIfNeeded(uid: uid)
            conversationId = convId
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview { ContentView() }
