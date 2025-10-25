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
    @StateObject private var notifications = NotificationService()
    
    private let store = FirestoreService()
    private let presence = PresenceService()
    
    @State private var selectedConversationId: String?
    
    var body: some View {
        Group {
            if auth.isSignedIn {
                ConversationListView(selectedConversationId: $selectedConversationId)
                    .task {
                        // Request notification permission
                        await notifications.requestAuthorization()
                        
                        // Save FCM token when signed in
                        if let uid = auth.uid {
                            await notifications.saveFCMToken(for: uid)
                        }
                    }
                    .onAppear {
                        // Start presence service when user is signed in (runs once on initial load)
                        if let uid = auth.uid {
                            print("🟢 Starting presence service on appear (uid: \(uid))")
                            presence.start(uid: uid)
                            presence.pingOnce(uid: uid)
                        }
                    }
            } else {
                LoginView()
            }
        }
        .environmentObject(auth)
        .environmentObject(notifications)
        .onChange(of: scenePhase) { _, newPhase in
            guard let uid = auth.uid else { return }
            switch newPhase {
            case .active:
                print("🟢 App became active, starting presence")
                presence.start(uid: uid)
                presence.pingOnce(uid: uid)
            case .inactive, .background:
                print("⏸️ App became \(newPhase), keeping presence running")
                break
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConversation)) { notification in
            if let conversationId = notification.userInfo?["conversationId"] as? String {
                selectedConversationId = conversationId
            }
        }
    }
}

#Preview {
    ContentView()
}
