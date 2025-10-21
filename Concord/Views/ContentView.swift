//
//  ContentView.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var auth = AuthService()
    private let store = FirestoreService()
    private let presence = PresenceService()

    // NEW: keep the self convo without auto-opening it
    @State private var selfConversationId: String?
    @State private var conversationId: String?   // when set, we navigate
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var showUID = false
    @State private var showStartDM = false
    @State private var showInbox = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Hello, Concord 👋").font(.largeTitle).bold()

                if let uid = auth.uid {
                    Text("UID: \(uid)")
                        .font(.footnote.monospaced())
                        .opacity(0.7)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                if let err = errorText { Text(err).foregroundStyle(.red) }

                if let selfId = selfConversationId {
                    Button("Open Test Chat") {
                        conversationId = selfId    // navigate now, not earlier
                    }
                    .buttonStyle(.borderedProminent)
                } else if isLoading {
                    ProgressView()
                }

                if let uid = auth.uid {
                    Button("Show / Copy UID") { showUID = true }
                }
                
                if let uid = auth.uid {
                    Button("Start DM") { showStartDM = true }
                        .buttonStyle(.bordered)
                }

                Button("Open Inbox") { showInbox = true }
                    .buttonStyle(.borderedProminent)

                .navigationDestination(isPresented: $showInbox) {
                    ConversationListView()
                }

            }
            .padding()
            .toolbar {
                if auth.uid != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("UID") { showUID = true }
                    }
                }
            }
            // Navigate only when user sets conversationId
            .navigationDestination(item: $conversationId) { convId in
                ChatView(conversationId: convId)
            }
            .task {
                await auth.signInAnonymouslyIfNeeded()
                if let uid = Auth.auth().currentUser?.uid {
                    presence.start(uid: uid)
                    presence.pingOnce(uid: uid)
                }
                await createOrLoadTestConversation()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard let uid = Auth.auth().currentUser?.uid else { return }
                switch newPhase {
                case .active: presence.start(uid: uid); presence.pingOnce(uid: uid)
                default: presence.stop()
                }
            }
            .sheet(isPresented: $showUID) {
                if let uid = auth.uid {
                    UIDSheet(uid: uid)
                }
            }
        }.sheet(isPresented: $showStartDM) {
            if let uid = auth.uid {
                StartDMView(myUid: uid) { other in
                    Task {
                        do {
                            let convId = try await store.openOrCreateDM(me: uid, other: other)
                            conversationId = convId
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func createOrLoadTestConversation() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let convId = try await store.createSelfConversationIfNeeded(uid: uid)
            selfConversationId = convId     // <-- don't set conversationId here
        } catch { errorText = error.localizedDescription }
        isLoading = false
    }
}

// Simple sheet to copy the UID
struct UIDSheet: View {
    let uid: String
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Your UID").font(.headline)
                Text(uid).font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Copy to Clipboard") {
                    UIPasteboard.general.string = uid
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .navigationTitle("My UID")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
        }
    }
}
