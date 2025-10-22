//
//  ContentView.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import SwiftUI
import FirebaseAuth

struct ContentView: View {
    enum Route: Hashable {
        case inbox
        case chat(id: String)
    }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var auth = AuthService()
    private let store = FirestoreService()
    private let presence = PresenceService()

    // keep start-page state
    @State private var selfConversationId: String?
    @State private var conversationId: String?   // still used to open from “Test Chat”
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var showUID = false
    @State private var showStartDM = false

    // NEW: single navigation path for the whole app
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            // ----- Home page content (unchanged UI) -----
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
                        // push Chat on the same stack
                        path.append(.chat(id: selfId))
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

                Button("Open Inbox") {
                    path.append(.inbox)   // push the list
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .toolbar {
                if auth.uid != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("UID") { showUID = true }
                    }
                }
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
            // If you still want the “Start DM” from Home, open and then push Chat:
            .sheet(isPresented: $showStartDM) {
                if let uid = auth.uid {
                    StartDMView(myUid: uid) { other in
                        Task {
                            do {
                                let convId = try await store.openOrCreateDM(me: uid, other: other)
                                path.append(.chat(id: convId))
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    }
                }
            }
            // ----- The only navigationDestination in the app -----
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .inbox:
                    ConversationListView { convId in
                        path.append(.chat(id: convId)) // push chat from list
                    }

                case .chat(let id):
                    ChatView(conversationId: id)
                }
            }
        }
    }

    @MainActor
    private func createOrLoadTestConversation() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let convId = try await store.createSelfConversationIfNeeded(uid: uid)
            selfConversationId = convId
        } catch { errorText = error.localizedDescription }
        isLoading = false
    }
}

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
        }
    }
}
