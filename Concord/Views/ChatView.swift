//
//  ChatView.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

func waitForUID(timeoutSeconds: Double = 5.0) async -> String? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Auth.auth().currentUser?.uid == nil && Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
    return Auth.auth().currentUser?.uid
}

struct ChatView: View {
    let conversationId: String

    @State private var messages: [Message] = []
    @State private var text: String = ""

    // Pagination
    @State private var cursor: QueryDocumentSnapshot? = nil
    @State private var loadingOlder = false

    // Read receipts debounce
    @State private var receiptTask: Task<Void, Never>? = nil

    // Typing indicator
    @State private var othersTyping = false
    @State private var typingTask: Task<Void, Never>?

    private let store = FirestoreService()

    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        
                        // Show the button only when there's a next page
                        if cursor != nil && !messages.isEmpty {
                            if loadingOlder {
                                ProgressView().padding(.vertical, 8)
                            } else {
                                if !messages.isEmpty {
                                    Button("Load older messages") {
                                        Task {
                                            loadingOlder = true
                                            defer { loadingOlder = false }
                                            do {
                                                let (older, nextCursor) = try await store.loadOlderMessages(
                                                    conversationId: conversationId,
                                                    before: cursor,
                                                    pageSize: 30
                                                )
                                                messages = older + messages   // prepend
                                                cursor = nextCursor           // advance cursor
                                            } catch { /* ignore for MVP */ }
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                            Divider()
                        }
                        
                        ForEach(messages, id: \.id) { m in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(m.text)
                                if let t = m.createdAt {
                                    Text(t.formatted()).font(.caption).opacity(0.6)
                                }
                            }
                            .padding(10)
                            .background(.gray.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(m.id) // ← add this
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, newCount in
                    guard newCount > 0, let id = messages.last?.id else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }

            }
            if othersTyping {
                Text("Typing…").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Message…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text) { _, newValue in
                        guard let uid = Auth.auth().currentUser?.uid else { return }
                        // debounce typing writes
                        typingTask?.cancel()
                        // send "isTyping: true" immediately
                        Task { await store.setTyping(conversationId: conversationId, uid: uid, isTyping: true) }
                        typingTask = Task {
                            // if no edits for 800ms, send "false"
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            await store.setTyping(conversationId: conversationId, uid: uid, isTyping: false)
                        }
                    }

                Button("Send") {
                    Task {
                        guard let uid = Auth.auth().currentUser?.uid,
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        let t = text; text = ""
                        try? await store.sendMessage(conversationId: conversationId, senderId: uid, text: t)
                        // end typing after send
                        await store.setTyping(conversationId: conversationId, uid: uid, isTyping: false)
                    }
                }
            }
            .padding(.horizontal)

        }
        .task {
            // 1) Wait for auth
            guard let uid = await waitForUID() else {
                print("ChatView: no UID yet; aborting listeners")
                return
            }

            // 2) Verify I'm a member of this conversation (optional but helpful for clear errors)
            let convRef = Firestore.firestore().collection("conversations").document(conversationId)
            do {
                let convSnap = try await convRef.getDocument()
                if let members = convSnap.data()?["members"] as? [String], !members.contains(uid) {
                    print("ChatView: not a member of this conversation")
                    return
                }
            } catch {
                // If this fails because the doc doesn't exist yet, you can choose to continue.
                // For MVP we'll just continue; the subcollection listeners will attach once readable.
            }

            // 3) Attach messages listener
            _ = store.listenMessages(conversationId: conversationId) { msgs in
                DispatchQueue.main.async {
                    messages = msgs

                    // Debounced read receipt
                    if let last = msgs.last?.createdAt {
                        receiptTask?.cancel()
                        receiptTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            await store.updateReadReceipt(conversationId: conversationId, uid: uid, lastReadAt: last)
                        }
                    }
                }
            }

            // 4) Attach typing listener
            _ = store.listenTyping(conversationId: conversationId) { map in
                DispatchQueue.main.async {
                    othersTyping = map.contains { who, val in who != uid && val }
                }
            }
        }
        .onDisappear {
            typingTask?.cancel()
            if let uid = Auth.auth().currentUser?.uid {
                Task { await store.setTyping(conversationId: conversationId, uid: uid, isTyping: false) }
            }
        }
    }
}
