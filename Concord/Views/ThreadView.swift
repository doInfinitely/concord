//
//  ThreadView.swift
//  Concord
//
//  Thread view for message replies
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct ThreadOverlayView: View {
    let conversationId: String
    let threadId: String
    let rootMessage: Message
    @Binding var isPresented: Bool
    let conversation: Conversation?
    let readReceiptsMap: [String: Date]
    
    @State private var threadMessages: [Message] = []
    @State private var replyText: String = ""
    @State private var isLoading = true
    @State private var threadListener: ListenerRegistration?
    
    private let store = FirestoreService()
    
    var body: some View {
        ZStack {
            // iMessage-style translucent white overlay covering whole screen
            Color.white.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }
            
            VStack(spacing: 0) {
                // Header with close button
                HStack {
                    Spacer()
                    
                    Text("Thread")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.gray)
                    }
                }
                .padding()
                .background(Color(.systemBackground))
                
                // Thread messages
                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            // Always show the root message first
                            ThreadMessageBubble(
                                message: rootMessage,
                                isMe: rootMessage.senderId == Auth.auth().currentUser?.uid,
                                isRootMessage: true,
                                conversation: conversation,
                                readReceiptsMap: readReceiptsMap,
                                isLastMessage: threadMessages.count == 1
                            )
                            
                            // Show replies if any
                            if threadMessages.count > 1 {
                                ForEach(Array(threadMessages.dropFirst().enumerated()), id: \.element.id) { index, message in
                                    let isLast = index == threadMessages.count - 2 // -2 because we dropped first
                                    ThreadMessageBubble(
                                        message: message,
                                        isMe: message.senderId == Auth.auth().currentUser?.uid,
                                        isRootMessage: false,
                                        conversation: conversation,
                                        readReceiptsMap: readReceiptsMap,
                                        isLastMessage: isLast && message.senderId == Auth.auth().currentUser?.uid
                                    )
                                }
                            }
                        }
                        .padding()
                    }
                }
                
                // Reply input
                HStack(spacing: 12) {
                    TextField("Reply to thread...", text: $replyText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                    
                    Button {
                        sendReply()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .black)
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
                .background(Color(.systemBackground))
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
            .padding(40)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .task {
            // Attach real-time listener for thread messages
            isLoading = true
            threadListener = store.listenThreadMessages(conversationId: conversationId, threadId: threadId) { messages in
                DispatchQueue.main.async {
                    self.threadMessages = messages
                    self.isLoading = false
                }
            }
        }
        .onDisappear {
            // Clean up listener when view disappears
            threadListener?.remove()
            threadListener = nil
        }
    }
    
    private func sendReply() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let messageToSend = trimmed
        
        // Clear the text field immediately for better UX
        replyText = ""
        
        Task {
            do {
                // Send as a reply to the root message
                try await store.sendMessage(
                    conversationId: conversationId,
                    senderId: uid,
                    text: messageToSend,
                    parentMessageId: threadId
                )
                
                print("✅ Reply sent successfully - real-time listener will update automatically")
                // No need to manually reload - the real-time listener will automatically update!
            } catch {
                print("❌ Error sending reply: \(error)")
                // Restore text on error
                await MainActor.run {
                    replyText = messageToSend
                }
            }
        }
    }
}

private struct ThreadMessageBubble: View {
    let message: Message
    let isMe: Bool
    let isRootMessage: Bool
    let conversation: Conversation?
    let readReceiptsMap: [String: Date]
    let isLastMessage: Bool
    
    @State private var senderName: String?
    
    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            // Show "Replying to" label for root message
            if isRootMessage {
                Text("Replying to:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            
            HStack {
                if isMe { Spacer(minLength: 40) }
                
                VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                    if !isMe {
                        Text(senderName ?? "Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.text)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        if let createdAt = message.createdAt {
                            Text(createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .opacity(0.6)
                        }
                    }
                    .padding(10)
                    .background(
                        isMe ? Color.clear : Color.gray.opacity(0.15)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isMe ? Color.black : Color.clear, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    // Read/Delivered indicator for my messages
                    if isMe, isLastMessage {
                        Text(readStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                
                if !isMe { Spacer(minLength: 40) }
            }
        }
        .task {
            if !isMe {
                await loadSenderName()
            }
        }
    }
    
    private var readStatus: String {
        guard let messageTime = message.createdAt else {
            return "Delivered"
        }
        
        let isGroupChat = (conversation?.memberCount ?? 0) > 2
        
        if isGroupChat {
            guard let convo = conversation else { return "Delivered" }
            let others = Set(convo.members).subtracting([message.senderId])
            let totalOthers = others.count
            let readCount = readReceiptsMap.reduce(0) { acc, kv in
                let (uid, lastRead) = kv
                let isRead = others.contains(uid) && lastRead.timeIntervalSince(messageTime) >= -0.1
                return acc + (isRead ? 1 : 0)
            }
            return readCount == 0 ? "Delivered" : "Read \(readCount)/\(totalOthers)"
        } else {
            // DM - get the other user's last read time
            if let convo = conversation,
               let me = Auth.auth().currentUser?.uid,
               let other = convo.members.first(where: { $0 != me }),
               let lastRead = readReceiptsMap[other] {
                let timeDiff = lastRead.timeIntervalSince(messageTime)
                let isRead = timeDiff >= -0.1
                return isRead ? "Read" : "Delivered"
            }
            return "Delivered"
        }
    }
    
    private func loadSenderName() async {
        do {
            let userSnap = try await Firestore.firestore()
                .collection("users")
                .document(message.senderId)
                .getDocument()
            
            if let data = userSnap.data() {
                await MainActor.run {
                    senderName = data["displayName"] as? String ?? data["email"] as? String ?? "Unknown"
                }
            }
        } catch {
            print("Error loading sender name: \(error)")
        }
    }
}

