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
    @State private var aiLoadingForMessage: String? = nil
    @State private var showCreateEvent = false
    @State private var extractedEvent = ExtractedEventData()
    
    private let store = FirestoreService()
    private let aiService = AIService()
    @StateObject private var calendarService = CalendarService()
    
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
                            // Filter visible messages (AI messages might be user-specific)
                            let visibleMessages = threadMessages.filter { msg in
                                guard msg.isAI else { return true }
                                guard let visibleTo = msg.visibleTo else { return true }
                                guard let myUid = Auth.auth().currentUser?.uid else { return false }
                                return visibleTo.contains(myUid)
                            }
                            
                            // Always show the root message first
                            ThreadMessageBubble(
                                message: rootMessage,
                                isMe: rootMessage.senderId == Auth.auth().currentUser?.uid,
                                isRootMessage: true,
                                conversation: conversation,
                                readReceiptsMap: readReceiptsMap,
                                isLastMessage: visibleMessages.count == 1,
                                aiLoadingForMessage: aiLoadingForMessage,
                                onAIAction: { message, action in
                                    handleAIAction(message: message, action: action)
                                }
                            )
                            
                            // Show replies
                            ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                                let isLast = index == visibleMessages.count - 1
                                ThreadMessageBubble(
                                    message: message,
                                    isMe: message.senderId == Auth.auth().currentUser?.uid,
                                    isRootMessage: false,
                                    conversation: conversation,
                                    readReceiptsMap: readReceiptsMap,
                                    isLastMessage: isLast && message.senderId == Auth.auth().currentUser?.uid,
                                    aiLoadingForMessage: aiLoadingForMessage,
                                    onAIAction: { message, action in
                                        handleAIAction(message: message, action: action)
                                    }
                                )
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
            
            // Load calendar status for event creation
            await calendarService.loadCalendarStatus()
        }
        .onDisappear {
            // Clean up listener when view disappears
            threadListener?.remove()
            threadListener = nil
        }
        .sheet(isPresented: $showCreateEvent) {
            CreateEventView(
                calendarService: calendarService,
                eventData: $extractedEvent
            )
        }
    }
    
    private func handleAIAction(message: Message, action: AIAction) {
        guard let userId = Auth.auth().currentUser?.uid else {
            print("❌ No user ID for AI action")
            return
        }
        
        Task {
            do {
                // Set loading state
                await MainActor.run {
                    aiLoadingForMessage = message.id
                }
                
                print("🤖 Calling AI service from ThreadView: action=\(action.rawValue), threadId=\(threadId)")
                
                // Call AI service
                let (response, messageId) = try await aiService.performAIAction(
                    conversationId: conversationId,
                    threadId: threadId,
                    action: action,
                    userId: userId
                )
                
                print("✅ AI response received: \(response.prefix(50))...")
                
                // Clear loading state
                await MainActor.run {
                    aiLoadingForMessage = nil
                }
                
                // Special handling for calendar event extraction
                if action == .extractEvent {
                    print("📅 [ThreadView] Parsing calendar event from AI response")
                    // Parse the AI response and show the event creation sheet
                    let parsedEvent = calendarService.parseEventData(from: response)
                    print("📅 [ThreadView] Parsed event: title=\(parsedEvent.title), date=\(parsedEvent.date?.description ?? "nil")")
                    print("📅 [ThreadView] Available calendars: \(calendarService.availableCalendars.count)")
                    
                    await MainActor.run {
                        extractedEvent = parsedEvent
                        showCreateEvent = true
                        print("📅 [ThreadView] Showing create event sheet: \(showCreateEvent)")
                    }
                }
                // For other actions, the AI response will appear via the real-time listener
                
            } catch {
                print("❌ AI action error: \(error.localizedDescription)")
                await MainActor.run {
                    aiLoadingForMessage = nil
                }
            }
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
    let aiLoadingForMessage: String?
    let onAIAction: (Message, AIAction) -> Void
    
    @State private var senderName: String?
    
    var body: some View {
        // AI messages render as black bubbles
        if message.isAI {
            return AnyView(AIThreadMessageBubble(message: message, aiLoadingForMessage: aiLoadingForMessage))
        }
        
        return AnyView(regularThreadBubble)
    }
    
    @ViewBuilder
    private var regularThreadBubble: some View {
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
                        Text(parseMarkdown(message.text))
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
                    .contextMenu {
                        Button {
                            onAIAction(message, .summarizeThread)
                        } label: {
                            Label("Summarize Thread", systemImage: "doc.text.magnifyingglass")
                        }
                        
                        Button {
                            onAIAction(message, .extractActions)
                        } label: {
                            Label("Extract Action Items", systemImage: "checklist")
                        }
                        
                        Button {
                            onAIAction(message, .summarizeDecision)
                        } label: {
                            Label("Summarize Decision", systemImage: "checkmark.circle")
                        }
                        
                        Button {
                            onAIAction(message, .checkPriority)
                        } label: {
                            Label("Check Priority", systemImage: "exclamationmark.triangle")
                        }
                        
                        Button {
                            onAIAction(message, .extractEvent)
                        } label: {
                            Label("Extract Calendar Event", systemImage: "calendar.badge.plus")
                        }
                        
                        Button {
                            onAIAction(message, .trackRSVPs)
                        } label: {
                            Label("Track RSVPs", systemImage: "person.3")
                        }
                    }
                    
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

// MARK: - AI Thread Message Bubble
private struct AIThreadMessageBubble: View {
    let message: Message
    let aiLoadingForMessage: String?
    
    var isLoading: Bool {
        aiLoadingForMessage == message.id
    }
    
    var body: some View {
        HStack {
            Spacer()
            
            VStack(alignment: .center, spacing: 6) {
                // AI badge
                Text("AI Assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                // Message bubble
                VStack(alignment: .leading, spacing: 4) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .padding(8)
                    } else {
                        Text(parseMarkdown(message.text))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        if let createdAt = message.createdAt {
                            Text(createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .opacity(0.7)
                        }
                    }
                }
                .padding(12)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 280)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Markdown Parsing Helper
private func parseMarkdown(_ text: String) -> AttributedString {
    do {
        return try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    } catch {
        // If markdown parsing fails, return plain text
        return AttributedString(text)
    }
}

