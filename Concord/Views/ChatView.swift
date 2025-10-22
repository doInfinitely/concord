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
    @State private var otherUserUID: String = "Loading..."
    @State private var conversation: Conversation?

    // Pagination
    @State private var cursor: QueryDocumentSnapshot? = nil
    @State private var loadingOlder = false

    // Read receipts debounce
    @State private var receiptTask: Task<Void, Never>? = nil

    // Typing indicator
    @State private var othersTyping = false
    @State private var typingTask: Task<Void, Never>?
    // Typing indicator control
    @State private var typingLastSeenAt: Date? = nil
    @State private var typingVisibleSince: Date? = nil
    @State private var typingHideTask: Task<Void, Never>? = nil

    private let typingInactivityGrace: TimeInterval = 0.05  // wait this long after last event
    private let typingMinVisible: TimeInterval = 0.9       // ensure UI stays visible at least this long

    private let store = FirestoreService()
    
    @ViewBuilder
    private func LoadOlderControl(cap: CGFloat) -> some View {
        if cursor != nil && !messages.isEmpty {
            if loadingOlder {
                ProgressView().padding(.vertical, 8)
            } else {
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
                            messages = older + messages
                            cursor = nextCursor
                        } catch { /* ignore */ }
                    }
                }
                .padding(.vertical, 8)
            }
            Divider()
        }
    }

    private func send(trimmed: String, uid: String) {
        Task {
            text = ""
            try? await store.sendMessage(conversationId: conversationId, senderId: uid, text: trimmed)
            await store.setTyping(conversationId: conversationId, uid: uid, isTyping: false)
        }
    }
    
    private func loadConversation() async {
        let db = Firestore.firestore()
        do {
            let convSnap = try await db.collection("conversations").document(conversationId).getDocument()
            guard let data = convSnap.data() else { return }
            
            let members = data["members"] as? [String] ?? []
            let name = data["name"] as? String
            let lastMessageText = data["lastMessageText"] as? String
            let lastMessageAt = (data["lastMessageAt"] as? Timestamp)?.dateValue()
            
            await MainActor.run {
                conversation = Conversation(
                    id: conversationId,
                    members: members,
                    memberCount: members.count,
                    name: name,
                    lastMessageText: lastMessageText,
                    lastMessageAt: lastMessageAt
                )
            }
        } catch {
            print("Error loading conversation: \(error)")
        }
    }
    
    private func loadOtherUserUID(myUid: String) async {
        let db = Firestore.firestore()
        do {
            let convSnap = try await db.collection("conversations").document(conversationId).getDocument()
            guard let members = convSnap.data()?["members"] as? [String] else { return }
            
            // Find the other user (not me)
            if let otherId = members.first(where: { $0 != myUid }) {
                await MainActor.run {
                    otherUserUID = otherId
                }
            } else {
                await MainActor.run {
                    otherUserUID = "Unknown"
                }
            }
        } catch {
            print("Error loading other user: \(error)")
            await MainActor.run {
                otherUserUID = "Error"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            // cap bubble width to ~72% of available width, up to 360pt
            let cap: CGFloat = min(geo.size.width * 0.72, 360)
            let rowWidth: CGFloat = geo.size.width
            VStack(spacing: 0) {
                // Header with other user's UID
                HStack {
                    Spacer()
                    Text(otherUserUID)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding()
                .background(Color(.systemBackground))
                .overlay(
                    Divider().frame(maxWidth: .infinity, maxHeight: 1),
                    alignment: .bottom
                )
                
                MessagesListView(
                    messages: messages,
                    cap: cap,
                    me: Auth.auth().currentUser?.uid,
                    cursor: cursor,
                    loadingOlder: loadingOlder,
                    rowWidth: rowWidth,
                    conversation: conversation,
                    loadOlder: {
                        Task {
                            loadingOlder = true
                            defer { loadingOlder = false }
                            do {
                                let (older, nextCursor) = try await store.loadOlderMessages(
                                    conversationId: conversationId,
                                    before: cursor,
                                    pageSize: 30
                                )
                                messages = older + messages
                                cursor = nextCursor
                            } catch { /* ignore for MVP */ }
                        }
                    }
                )
                .frame(maxWidth: .infinity)
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
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                await store.setTyping(conversationId: conversationId, uid: uid, isTyping: false)
                            }
                        }
                    
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button("Send") {
                        if let uid = Auth.auth().currentUser?.uid, !trimmed.isEmpty {
                            send(trimmed: trimmed, uid: uid)
                        }
                    }
                    .disabled(trimmed.isEmpty)
                }
                .padding(.horizontal)
                
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                // 1) Wait for auth
                guard let uid = await waitForUID() else {
                    print("ChatView: no UID yet; aborting listeners")
                    return
                }
                
                // 2) Load conversation data (including member count)
                await loadConversation()
                
                // 3) Load other user's UID
                await loadOtherUserUID(myUid: uid)
                
                // 4) Verify I'm a member of this conversation (optional but helpful for clear errors)
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
                
                // 5) Attach messages listener
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
                
                // 6) Attach typing listener
                _ = store.listenTyping(conversationId: conversationId) { map in
                    DispatchQueue.main.async {
                        guard let me = Auth.auth().currentUser?.uid else { return }
                        let anyOtherTyping = map.contains { who, val in who != me && val }
                        let now = Date()

                        if anyOtherTyping {
                            // show immediately
                            typingLastSeenAt = now
                            if !othersTyping {
                                othersTyping = true
                                typingVisibleSince = now
                            }
                            // schedule hide after inactivity grace (resets on new events)
                            typingHideTask?.cancel()
                            typingHideTask = Task {
                                try? await Task.sleep(nanoseconds: UInt64(typingInactivityGrace * 1_000_000_000))
                                await MainActor.run {
                                    // if we've seen a newer typing event, this task is obsolete
                                    guard let last = typingLastSeenAt, Date().timeIntervalSince(last) >= typingInactivityGrace else { return }

                                    // honor the minimum visible time
                                    let shown = Date().timeIntervalSince(typingVisibleSince ?? now)
                                    if shown < typingMinVisible {
                                        let wait = typingMinVisible - shown
                                        Task { @MainActor in
                                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                                            // Double-check we didn't see new typing in the meantime
                                            guard let last2 = typingLastSeenAt, Date().timeIntervalSince(last2) >= typingInactivityGrace else { return }
                                            othersTyping = false
                                            typingVisibleSince = nil
                                        }
                                        return
                                    }
                                    othersTyping = false
                                    typingVisibleSince = nil
                                }
                            }
                        } else {
                            // Everyone explicitly false; still honor min visible
                            if othersTyping {
                                typingHideTask?.cancel()
                                typingHideTask = Task {
                                    let shown = Date().timeIntervalSince(typingVisibleSince ?? now)
                                    if shown < typingMinVisible {
                                        try? await Task.sleep(nanoseconds: UInt64((typingMinVisible - shown) * 1_000_000_000))
                                    }
                                    await MainActor.run {
                                        // If a new typing event arrived meanwhile, don't hide
                                        guard let last = typingLastSeenAt, Date().timeIntervalSince(last) >= typingInactivityGrace else { return }
                                        othersTyping = false
                                        typingVisibleSince = nil
                                    }
                                }
                            }
                        }
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
}

private struct MessagesListView: View {
    let messages: [Message]
    let cap: CGFloat
    let me: String?
    let cursor: QueryDocumentSnapshot?
    let loadingOlder: Bool
    let rowWidth: CGFloat
    let conversation: Conversation?
    let loadOlder: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // Load older control (flat, not deeply nested)
                    if cursor != nil, !messages.isEmpty {
                        if loadingOlder {
                            ProgressView().padding(.vertical, 8)
                        } else {
                            Button("Load older messages", action: loadOlder)
                                .padding(.vertical, 8)
                        }
                        Divider()
                    }

                    // In your ScrollView, update the MessageRow call:
                    ForEach(messages, id: \.id) { m in
                        MessageRow(
                            message: m,
                            isMe: (m.senderId == me),
                            cap: cap,
                            rowWidth: rowWidth,
                            conversation: conversation
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical)
            }
            // auto-scroll when a new message arrives
            .task(id: messages.last?.id) {
                if let id = messages.last?.id {
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    withAnimation {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message
    let isMe: Bool
    let cap: CGFloat
    let rowWidth: CGFloat
    let conversation: Conversation?
    
    @State private var bubbleWidth: CGFloat = 0
    @State private var senderName: String?

    var body: some View {
        let paddingNeeded = isMe ? 12 - (cap - bubbleWidth) : 12
        let isGroupChat = (conversation?.memberCount ?? 0) > 2
        
        HStack(spacing: 0) {
            if isMe { Spacer(minLength: 0) }
            
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                // Show sender name in group chats for other people's messages
                if !isMe, isGroupChat {
                    Text(senderName ?? shortUid(message.senderId))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let t = message.createdAt {
                        Text(t.formatted()).font(.caption).opacity(0.6)
                    }
                }
                .padding(10)
                .background(
                    GeometryReader { geo in
                        (isMe ? Color.clear : Color.gray.opacity(0.15))
                            .onAppear {
                                bubbleWidth = geo.size.width
                            }
                            .onChange(of: geo.size.width) { _, newWidth in
                                bubbleWidth = newWidth
                            }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isMe ? Color.black : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: cap, alignment: .leading)
            }
            
            if !isMe { Spacer(minLength: 0) }
        }
        .padding(.horizontal, paddingNeeded)
        .id(message.id)
        .task {
            // Load sender name for group chats
            if !isMe, isGroupChat {
                await loadSenderName()
            }
        }
    }
    
    private func loadSenderName() async {
        do {
            let db = Firestore.firestore()
            let doc = try await db.collection("users").document(message.senderId).getDocument()
            if let data = doc.data() {
                await MainActor.run {
                    senderName = data["displayName"] as? String ?? data["email"] as? String
                }
            }
        } catch {
            print("Error loading sender name: \(error)")
        }
    }
    
    private func shortUid(_ uid: String) -> String {
        uid.count <= 8 ? uid : "\(uid.prefix(4))…\(uid.suffix(4))"
    }
}
