//
//  ChatView.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//
// FIX: Read receipt updates properly when receiver views messages

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// Preference key for measuring read receipt width
fileprivate struct ReadReceiptWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

fileprivate func waitForUID(timeoutSeconds: Double = 5.0) async -> String? {
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
    @State private var chatTitle: String = "Loading..."
    @State private var conversation: Conversation?
    @State private var isEditingTitle: Bool = false
    @State private var editableTitleText: String = ""
    @State private var selectedThread: Message? = nil
    @State private var showThreadView: Bool = false

    // Pagination
    @State private var cursor: QueryDocumentSnapshot? = nil
    @State private var loadingOlder = false

    // Read receipts debounce
    @State private var receiptTask: Task<Void, Never>? = nil
    @State private var readReceipts: [String: Date] = [:]
    @State private var rrListener: ListenerRegistration?
    @State private var conversationListener: ListenerRegistration?
    @State private var isViewActive = false // Track if view is actively being displayed

    // Typing indicator
    @State private var othersTyping = false
    @State private var typingTask: Task<Void, Never>?
    // Typing indicator control
    @State private var typingLastSeenAt: Date? = nil
    @State private var typingVisibleSince: Date? = nil
    @State private var typingHideTask: Task<Void, Never>? = nil
    
    // AI Service
    @State private var aiLoadingForMessage: String? = nil // Message ID currently processing AI
    private let aiService = AIService()
    
    // Calendar Event Creation
    @State private var showCreateEvent = false
    @State private var extractedEvent = ExtractedEventData()
    @StateObject private var calendarService = CalendarService()
    
    // Track processed messages to avoid duplicates
    @State private var processedMessageIds = Set<String>()

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
            let old = text
            text = ""
            do {
                try await store.sendMessage(conversationId: conversationId, senderId: uid, text: trimmed)
                await store.setTyping(conversationId: conversationId, uid: uid, isTyping: false)
            } catch {
                // restore text so it's not "eaten" on failure
                await MainActor.run { text = old }
                print("sendMessage failed:", error.localizedDescription)
            }
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
    
    private func attachConversationListener() {
        conversationListener?.remove()
        let db = Firestore.firestore()
        
        conversationListener = db.collection("conversations")
            .document(conversationId)
            .addSnapshotListener { snapshot, error in
                guard let data = snapshot?.data() else { return }
                
                let members = data["members"] as? [String] ?? []
                let name = data["name"] as? String
                let lastMessageText = data["lastMessageText"] as? String
                let lastMessageAt = (data["lastMessageAt"] as? Timestamp)?.dateValue()
                
                DispatchQueue.main.async {
                    self.conversation = Conversation(
                        id: self.conversationId,
                        members: members,
                        memberCount: members.count,
                        name: name,
                        lastMessageText: lastMessageText,
                        lastMessageAt: lastMessageAt
                    )
                    
                    // Update chat title if it changed (for group chats)
                    if let uid = Auth.auth().currentUser?.uid {
                        if members.count > 2 {
                            self.chatTitle = name ?? "Group Chat"
                        }
                    }
                }
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
    
    private func loadChatTitle(myUid: String) async {
        guard let convo = conversation else { return }
        
        // For group chats, use the group name
        if convo.memberCount > 2 {
            await MainActor.run {
                chatTitle = convo.name ?? "Group Chat"
            }
            return
        }
        
        // For DMs, load the other user's display name
        let db = Firestore.firestore()
        do {
            if let otherId = convo.members.first(where: { $0 != myUid }) {
                let userSnap = try await db.collection("users").document(otherId).getDocument()
                if let data = userSnap.data() {
                    let displayName = data["displayName"] as? String
                    let email = data["email"] as? String
                    await MainActor.run {
                        chatTitle = displayName ?? email ?? shortUid(otherId)
                    }
                } else {
                    await MainActor.run {
                        chatTitle = shortUid(otherId)
                    }
                }
            } else {
                await MainActor.run {
                    chatTitle = "Unknown"
                }
            }
        } catch {
            print("Error loading chat title: \(error)")
            await MainActor.run {
                chatTitle = shortUid(otherUserUID)
            }
        }
    }
    
    private func shortUid(_ uid: String) -> String {
        uid.count <= 8 ? uid : "\(uid.prefix(4))…\(uid.suffix(4))"
    }
    
    private func saveGroupName() {
        let trimmed = editableTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isEditingTitle = false
            return
        }
        
        Task {
            do {
                // Update Firestore conversation name
                // Also update lastMessageAt to trigger the query listener in ConversationListView
                let db = Firestore.firestore()
                try await db.collection("conversations")
                    .document(conversationId)
                    .setData([
                        "name": trimmed,
                        "lastMessageAt": FieldValue.serverTimestamp()
                    ], merge: true)
                
                print("✅ Group name updated to: \(trimmed)")
                
                await MainActor.run {
                    chatTitle = trimmed
                    isEditingTitle = false
                    // Update local conversation object
                    if var convo = conversation {
                        convo.name = trimmed
                        conversation = convo
                    }
                }
            } catch {
                print("❌ Error updating group name: \(error)")
                await MainActor.run {
                    isEditingTitle = false
                }
            }
        }
    }
    
    // MARK: - AI Action Handler
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
                
                // Determine threadId - if this message is in a thread, use its threadId
                // Otherwise, use the message ID as the root of a new thread
                let threadId = message.threadId ?? message.id
                
                print("🤖 Calling AI service: action=\(action.rawValue), threadId=\(threadId)")
                
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
                    print("📅 Parsing calendar event from AI response")
                    // Parse the AI response and show the event creation sheet
                    let parsedEvent = calendarService.parseEventData(from: response)
                    print("📅 Parsed event: title=\(parsedEvent.title), date=\(parsedEvent.date?.description ?? "nil")")
                    print("📅 Available calendars: \(calendarService.availableCalendars.count)")
                    
                    await MainActor.run {
                        extractedEvent = parsedEvent
                        showCreateEvent = true
                        print("📅 Showing create event sheet: \(showCreateEvent)")
                    }
                }
                // For other actions, the AI response is automatically added to Firestore
                // and will appear via the real-time listener
                
            } catch {
                print("❌ AI action error: \(error.localizedDescription)")
                await MainActor.run {
                    aiLoadingForMessage = nil
                }
            }
        }
    }
    
    private func attachReadReceiptsListener() {
        rrListener?.remove()
        let rrRef = Firestore.firestore()
            .collection("conversations").document(conversationId)
            .collection("readReceipts")

        rrListener = rrRef.addSnapshotListener { snap, _ in
            var map: [String: Date] = [:]
            snap?.documents.forEach { d in
                if let ts = d.data()["lastReadAt"] as? Timestamp {
                    map[d.documentID] = ts.dateValue()
                }
            }
            print("🔔 Read receipts updated: \(map.mapValues { $0.formatted() })")
            DispatchQueue.main.async { readReceipts = map }
        }
    }

    private func updateMyReadReceiptIfNeeded() {
        guard isViewActive,
              !messages.isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        receiptTask?.cancel()
        receiptTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000) // debounce
            guard isViewActive else { return } // Double check before updating
            // Use current time to represent when user viewed the messages
            await store.updateReadReceipt(conversationId: conversationId, uid: uid, lastReadAt: Date())
            print("🔄 Read receipt updated via onChange to: \(Date())")
        }
    }
    
    private func extractMeetingSubject(from text: String) async -> String {
        // Use AI to extract the meeting subject naturally
        do {
            let (subject, _) = try await aiService.performAIAction(
                conversationId: conversationId,
                threadId: nil,
                action: .extractMeetingSubject,
                userId: Auth.auth().currentUser?.uid ?? "",
                messageText: text
            )
            
            let cleaned = subject.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            
            return cleaned.isEmpty ? "Meeting" : cleaned
        } catch {
            print("❌ Failed to extract meeting subject via AI: \(error)")
            // Simple fallback
            return "Meeting"
        }
    }
    
    private func checkForMeetingProposals(in newMessages: [Message]) async {
        guard let uid = Auth.auth().currentUser?.uid else {
            print("📅 Proactive: No uid")
            return
        }
        
        print("📅 Proactive: Checking \(newMessages.count) messages")
        
        for message in newMessages {
            // Skip if already processed
            if processedMessageIds.contains(message.id) {
                print("📅 Proactive: Skipping (already processed): \(message.id)")
                continue
            }
            
            print("📅 Proactive: Message from \(message.senderId): '\(message.text.prefix(50))...'")
            
            // Skip AI messages
            if message.isAI {
                print("📅 Proactive: Skipping (AI message)")
                continue
            }
            
            // Mark as processed
            processedMessageIds.insert(message.id)
            
            // Check MY calendar for conflicts with ANY meeting proposal
            // (doesn't matter who sent it - if there's a conflict, I should know)
            
            // Detect meeting proposal
            let detection = calendarService.detectMeetingProposal(in: message.text)
            print("📅 Proactive: Detection result: hasProposal=\(detection.hasProposal), date=\(detection.dateTime?.description ?? "nil")")
            
            guard detection.hasProposal, let proposedDate = detection.dateTime else {
                continue
            }
            
            print("📅 Detected meeting proposal at: \(proposedDate)")
            print("📅 Proactive: Checking calendar for conflicts...")
            
            // Check for conflicts
            do {
                let result = try await calendarService.checkConflictsAndSuggestAlternatives(
                    proposedDate: proposedDate,
                    duration: detection.duration
                )
                
                print("📅 Proactive: Conflict check complete. hasConflict=\(result.hasConflict), conflicts=\(result.conflicts.count)")
                
                if result.hasConflict {
                    print("⚠️ Conflict detected! \(result.conflicts.count) conflicting events")
                    
                    // Format conflict message
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateStyle = .medium
                    dateFormatter.timeStyle = .short
                    
                    let conflictList = result.conflicts.map { event in
                        "• \(event.title) (\(dateFormatter.string(from: event.startDate)))"
                    }.joined(separator: "\n")
                    
                    var suggestionText = ""
                    if !result.suggestions.isEmpty {
                        suggestionText = "\n\n**Suggested alternatives:**\n"
                        suggestionText += result.suggestions.enumerated().map { index, date in
                            "• Option \(index + 1): \(dateFormatter.string(from: date))"
                        }.joined(separator: "\n")
                    }
                    
                    // Extract meeting subject from original message using AI
                    let meetingSubject = await extractMeetingSubject(from: message.text)
                    
                    let aiMessage = """
                    **Calendar Conflict Detected**
                    
                    The proposed meeting time **\(dateFormatter.string(from: proposedDate))** conflicts with:
                    \(conflictList)\(suggestionText)
                    
                    [MEETING_SUBJECT:\(meetingSubject)]
                    """
                    
                    // Insert proactive AI message (visible only to current user)
                    let db = Firestore.firestore()
                    let aiMessageRef = db.collection("conversations").document(conversationId).collection("messages").document()
                    try await aiMessageRef.setData([
                        "senderId": "ai_assistant",
                        "text": aiMessage,
                        "createdAt": FieldValue.serverTimestamp(),
                        "status": "sent",
                        "isAI": true,
                        "visibleTo": [uid],
                        "aiAction": "proactive_conflict_detection",
                        "replyCount": 0
                    ])
                    
                    print("✅ Sent proactive conflict warning")
                }
            } catch {
                print("❌ Error checking calendar conflicts: \(error)")
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            // cap bubble width to ~72% of available width, up to 360pt
            let cap: CGFloat = min(geo.size.width * 0.72, 360)
            let rowWidth: CGFloat = geo.size.width
            VStack(spacing: 0) {
                // Header with chat title
                HStack {
                    Spacer()
                    
                    if isEditingTitle {
                        TextField("Group Name", text: $editableTitleText, onCommit: {
                            saveGroupName()
                        })
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                    } else {
                        Text(chatTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .onTapGesture {
                                if let convo = conversation, convo.memberCount > 2 {
                                    editableTitleText = chatTitle
                                    isEditingTitle = true
                                }
                            }
                    }
                    
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
                    readReceiptsMap: readReceipts,
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
                            } catch { /* ignore */ }
                        }
                    },
                    onOpenThread: { message in
                        // If message is a reply, find the root message
                        if let threadId = message.threadId {
                            // This is a reply - find the root message
                            if let rootMsg = messages.first(where: { $0.id == threadId }) {
                                selectedThread = rootMsg
                                showThreadView = true
                            } else {
                                // Root not found in current messages, fetch it
                                Task {
                                    do {
                                        let fetchedRoot = try await store.getMessage(
                                            conversationId: conversationId,
                                            messageId: threadId
                                        )
                                        await MainActor.run {
                                            selectedThread = fetchedRoot
                                            showThreadView = true
                                        }
                                    } catch {
                                        print("❌ Failed to fetch root message: \(error)")
                                        // Fallback: use the reply as root (not ideal but works)
                                        selectedThread = message
                                        showThreadView = true
                                    }
                                }
                            }
                        } else {
                            // This is a root message
                            selectedThread = message
                            showThreadView = true
                        }
                    },
                    aiLoadingForMessage: aiLoadingForMessage,
                    onAIAction: { message, action in
                        handleAIAction(message: message, action: action)
                    },
                    showCreateEvent: $showCreateEvent,
                    extractedEvent: $extractedEvent
                )
                
                // Typing indicator UI
                if othersTyping {
                    HStack(spacing: 4) {
                        Text("typing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TypingDotsView()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                
                HStack {
                    TextField("Message", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .onChange(of: text) { oldValue, newValue in
                            guard let uid = Auth.auth().currentUser?.uid else { return }
                            typingTask?.cancel()
                            if !newValue.isEmpty {
                                Task {
                                    await store.setTyping(conversationId: conversationId, uid: uid, isTyping: true)
                                }
                            }
                            typingTask = Task {
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
                // Set view as active
                isViewActive = true
                
                // 1) Wait for auth
                guard let uid = await waitForUID() else {
                    print("ChatView: no UID yet; aborting listeners")
                    return
                }
                
                // 2) Load conversation data (including member count)
                await loadConversation()
                
                // 3) Attach real-time listener for conversation updates (name changes, etc.)
                attachConversationListener()
                
                // 4) Load other user's UID
                await loadOtherUserUID(myUid: uid)
                
                // 5) Load chat title (name for groups, display name for DMs)
                await loadChatTitle(myUid: uid)
                
                // 6) Verify I'm a member of this conversation (optional but helpful for clear errors)
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
                
                // 7) Attach messages listener
                _ = store.listenMessages(conversationId: conversationId) { msgs in
                    DispatchQueue.main.async {
                        let previousCount = messages.count
                        messages = msgs
                        
                        print("📨 Messages updated: prev=\(previousCount), new=\(msgs.count)")
                        
                        // Check for new messages with meeting proposals (proactive assistant)
                        if msgs.count > previousCount {
                            let newMessages = Array(msgs.suffix(msgs.count - previousCount))
                            print("📨 Checking \(newMessages.count) new messages for meeting proposals")
                            Task {
                                await checkForMeetingProposals(in: newMessages)
                            }
                        }
                        
                        // Only update read receipt when view is active
                        guard isViewActive, !msgs.isEmpty else { return }
                        
                        // Debounced read receipt when new messages arrive
                        // Use current time to represent when user viewed the messages
                        receiptTask?.cancel()
                        receiptTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard isViewActive else { return } // Double check before updating
                            await store.updateReadReceipt(conversationId: conversationId, uid: uid, lastReadAt: Date())
                        }
                    }
                }
                
                // 8) Attach read receipts listener
                attachReadReceiptsListener()
                
                // FIX: Wait for initial messages to load, then immediately update read receipt
                // This ensures that when a receiver opens the chat, their read receipt updates
                // Use CURRENT TIME to represent when the user viewed the messages
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms to let messages load
                await MainActor.run {
                    guard isViewActive, !messages.isEmpty else { return }
                    Task {
                        // Use current time, not message timestamp
                        await store.updateReadReceipt(conversationId: conversationId, uid: uid, lastReadAt: Date())
                        print("✅ Initial read receipt updated to: \(Date())")
                    }
                }
                
                // 9) Load calendar status for event creation
                await calendarService.loadCalendarStatus()
                
                // 10) Attach typing listener (recency-aware to avoid stale 'true')
                let typingRef = Firestore.firestore()
                    .collection("conversations").document(conversationId)
                    .collection("typing")

                typingRef.addSnapshotListener { snap, _ in
                    DispatchQueue.main.async {
                        guard let me = Auth.auth().currentUser?.uid else { return }
                        let now = Date()
                        // consider "typing" only if updated within last 2 seconds
                        let freshness: TimeInterval = 2.0

                        var someoneElseTyping = false
                        snap?.documents.forEach { d in
                            let uid = d.documentID
                            guard uid != me else { return }
                            let data = d.data()
                            let isTyping = (data["isTyping"] as? Bool) ?? false
                            let ts = (data["updatedAt"] as? Timestamp)?.dateValue()
                            if isTyping, let ts, now.timeIntervalSince(ts) <= freshness {
                                someoneElseTyping = true
                            }
                        }

                        let nowDate = Date()
                        if someoneElseTyping {
                            // show immediately, same min-visible logic you already had
                            typingLastSeenAt = nowDate
                            if !othersTyping {
                                othersTyping = true
                                typingVisibleSince = nowDate
                            }
                        } else {
                            typingLastSeenAt = nowDate
                            if othersTyping {
                                typingHideTask?.cancel()
                                typingHideTask = nil
                                if let vis = typingVisibleSince {
                                    let shown = nowDate.timeIntervalSince(vis)
                                    if shown < typingMinVisible {
                                        let wait = typingMinVisible - shown
                                        Task { @MainActor in
                                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                                            guard let last2 = typingLastSeenAt,
                                                  Date().timeIntervalSince(last2) >= typingInactivityGrace else { return }
                                            othersTyping = false
                                            typingVisibleSince = nil
                                        }
                                        return
                                    }
                                    othersTyping = false
                                    typingVisibleSince = nil
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: messages.last?.id) { _ in
                updateMyReadReceiptIfNeeded()
            }
            .overlay {
                if showThreadView, let thread = selectedThread {
                    ThreadOverlayView(
                        conversationId: conversationId,
                        threadId: thread.threadId ?? thread.id, // Use thread's threadId if it's a reply, else use its own ID
                        rootMessage: thread,
                        isPresented: $showThreadView,
                        conversation: conversation,
                        readReceiptsMap: readReceipts
                    )
                }
            }
            .sheet(isPresented: $showCreateEvent) {
                CreateEventView(
                    calendarService: calendarService,
                    eventData: $extractedEvent
                )
            }
            .onDisappear {
                // Mark view as inactive
                isViewActive = false
                print("❌ View disappeared, marked inactive")
                
                // existing typing cleanup
                typingTask?.cancel()
                if let uid = Auth.auth().currentUser?.uid {
                    Task { await store.setTyping(conversationId: conversationId, uid: uid, isTyping: false) }
                }

                // read receipts cleanup
                rrListener?.remove()
                rrListener = nil
                receiptTask?.cancel()
                
                // conversation listener cleanup
                conversationListener?.remove()
                conversationListener = nil
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
    let readReceiptsMap: [String: Date]
    let loadOlder: () -> Void
    let onOpenThread: (Message) -> Void
    let aiLoadingForMessage: String?
    let onAIAction: (Message, AIAction) -> Void
    @Binding var showCreateEvent: Bool
    @Binding var extractedEvent: ExtractedEventData
    
    // Filter messages to only show those visible to current user
    var visibleMessages: [Message] {
        messages.filter { msg in
            // If not an AI message, always visible
            guard msg.isAI else { return true }
            
            // If no visibility restriction, visible to all
            guard let visibleTo = msg.visibleTo else { return true }
            
            // Check if current user is in visibility list
            guard let myUid = me else { return false }
            return visibleTo.contains(myUid)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // Load older control (flat, not deeply nested)
                    if cursor != nil, !visibleMessages.isEmpty {
                        if loadingOlder {
                            ProgressView().padding(.vertical, 8)
                        } else {
                            Button("Load older messages", action: loadOlder)
                                .padding(.vertical, 8)
                        }
                        Divider()
                    }

                    // In your ScrollView, update the MessageRow call:
                    ForEach(visibleMessages, id: \.id) { m in
                        let meUid = me
                        let isMine = (m.senderId == meUid)
                        let lastMyMessageId = messages.last(where: { $0.senderId == meUid })?.id

                        let otherUserLastRead: Date? = {
                            guard let convo = conversation,
                                  convo.memberCount == 2,
                                  let me = meUid,
                                  let other = convo.members.first(where: { $0 != me }) else { return nil }
                            return readReceiptsMap[other]
                        }()

                        MessageRow(
                            message: m,
                            isMe: isMine,
                            cap: cap,
                            rowWidth: rowWidth,
                            conversation: conversation,
                            otherUserLastRead: otherUserLastRead,
                            allReadReceipts: readReceiptsMap,
                            isLastMessage: (m.id == lastMyMessageId),
                            aiLoadingForMessage: aiLoadingForMessage,
                            onReply: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    onOpenThread(m)
                                }
                            },
                            onAIAction: onAIAction,
                            showCreateEvent: $showCreateEvent,
                            extractedEvent: $extractedEvent
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
    let otherUserLastRead: Date?
    let allReadReceipts: [String: Date]
    let isLastMessage: Bool
    let aiLoadingForMessage: String?
    let onReply: () -> Void
    let onAIAction: (Message, AIAction) -> Void
    @Binding var showCreateEvent: Bool
    @Binding var extractedEvent: ExtractedEventData
    
    @State private var bubbleWidth: CGFloat = 0
    @State private var senderName: String?
    @State private var readReceiptWidth: CGFloat = 0

    var body: some View {
        Group {
            // AI messages are rendered differently (centered, black bubble with white text)
            if message.isAI {
                AIMessageBubble(
                    message: message,
                    aiLoadingForMessage: aiLoadingForMessage,
                    showCreateEvent: $showCreateEvent,
                    extractedEvent: $extractedEvent
                )
            } else {
                regularMessageBody
            }
        }
    }
    
    @ViewBuilder
    private var regularMessageBody: some View {
        let paddingNeeded = isMe ? 12 - (cap - bubbleWidth) : 12
        let readReceiptTrailingInset = max(0, cap - bubbleWidth)
        let isGroupChat = (conversation?.memberCount ?? 0) > 2
        let isDM = (conversation?.memberCount ?? 0) == 2
        
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
                    Text(parseMarkdown(message.text))
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
                .contextMenu {
                    Button {
                        onReply()
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    
                    Divider()
                    
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
                
                // Reply count badge - shows total replies in thread
                if message.replyCount > 0 {
                    Button {
                        onReply()
                    } label: {
                        WaveText(text: message.replyCount == 1 ? "1 Reply" : "\(message.replyCount) Replies")
                            .font(.caption)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: cap, alignment: isMe ? .trailing : .leading)
                    .padding(.trailing, isMe ? readReceiptTrailingInset : 0)
                }
                
                if isMe, isLastMessage {
                    Text(readStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        // lay out inside the same cap-width rail as the bubble...
                        .frame(maxWidth: cap, alignment: .trailing)
                        // ...then nudge it left so its trailing edge matches the bubble's trailing edge
                        .padding(.trailing, readReceiptTrailingInset)
                }
            }
            
            if !isMe { Spacer(minLength: 0) }
        }
        .padding(.horizontal, paddingNeeded)
        .padding(.leading, isMe ? 0 : 12)  // Add 12pt padding for other person's messages
        .id(message.id)
        .task {
            // Load sender name for group chats
            if !isMe, isGroupChat {
                await loadSenderName()
            }
        }
    }
    
    private var readStatus: String {
        guard let messageTime = message.createdAt else {
            return "Delivered"
        }
        
        let isGroupChat = (conversation?.memberCount ?? 0) > 2
        
        // inside readStatus:
        if isGroupChat {
            guard let convo = conversation else { return "Delivered" }
            let others = Set(convo.members).subtracting([message.senderId])
            let totalOthers = others.count
            let readCount = allReadReceipts.reduce(0) { acc, kv in
                let (uid, lastRead) = kv
                // lastRead must be >= messageTime (with small tolerance for clock skew)
                let isRead = others.contains(uid) && lastRead.timeIntervalSince(messageTime) >= -0.1
                return acc + (isRead ? 1 : 0)
            }
            return readCount == 0 ? "Delivered" : "Read \(readCount)/\(totalOthers)"
        } else {
            if let lastRead = otherUserLastRead {
                // Debug logging
                print("📖 Read receipt check:")
                print("  Message time: \(messageTime)")
                print("  Last read: \(lastRead)")
                print("  Difference: \(lastRead.timeIntervalSince(messageTime)) seconds")
                
                // lastRead must be >= messageTime (only allow tiny tolerance for Firestore precision)
                // If lastRead is before messageTime (negative difference), message hasn't been read yet
                let timeDiff = lastRead.timeIntervalSince(messageTime)
                let isRead = timeDiff >= -0.1  // Allow 100ms tolerance for timestamp precision
                print("  Is read: \(isRead)")
                return isRead ? "Read" : "Delivered"
            }
            return "Delivered"
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

// Add this view for typing indicator dots animation
private struct TypingDotsView: View {
    @State private var animating = false
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(animating ? 0.3 : 1.0)
                    .animation(
                        Animation.easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
        }
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

// MARK: - Wave Text Animation
private struct WaveText: View {
    let text: String
    var color: Color = .black
    
    var body: some View {
        TimelineView(.animation) { timeline in
            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                    Text(String(character))
                        .offset(y: sin((timeline.date.timeIntervalSinceReferenceDate * 2) + Double(index) * 0.67) * 2)
                }
            }
            .foregroundStyle(color)
        }
    }
}

// MARK: - Walking Bumps Text Animation (for suggestions)
private struct WalkingBumpsText: View {
    let text: String
    var color: Color = .white
    
    var body: some View {
        TimelineView(.animation) { timeline in
            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                    Text(String(character))
                        .offset(y: bumpOffset(for: index, at: timeline.date, textLength: text.count))
                }
            }
            .foregroundStyle(color)
        }
    }
    
    private func bumpOffset(for index: Int, at date: Date, textLength: Int) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        
        // Cycle: 3.5s walking, 1s pause, repeat
        let walkingDuration = 3.5
        let totalCycle = 4.5
        let cycleTime = time.truncatingRemainder(dividingBy: totalCycle)
        let isWalking = cycleTime < walkingDuration
        
        guard isWalking else { return 0 }
        
        // Bump travels from -3 to textLength + 3 over 3.5 seconds
        let bumpCenter = (cycleTime / walkingDuration) * Double(textLength + 6) - 3.0
        
        // Distance from this character to the bump center
        let distanceFromCenter = Double(index) - bumpCenter
        
        // Positive bump (Gaussian-like)
        let positiveBump = exp(-pow(distanceFromCenter, 2) / 2.0)
        
        // Negative bump (shifted right by 2 characters)
        let distanceFromNegative = Double(index) - (bumpCenter + 2.5)
        let negativeBump = exp(-pow(distanceFromNegative, 2) / 2.0)
        
        // Combine: positive bump up, negative bump down
        let amplitude: CGFloat = 4.0
        return amplitude * (positiveBump - negativeBump)
    }
}

// MARK: - Oscillating Text Animation (for AI alerts)
private struct OscillatingText: View {
    let text: String
    
    var body: some View {
        TimelineView(.animation) { timeline in
            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                    Text(String(character))
                        .offset(x: oscillationOffset(for: index, at: timeline.date))
                }
            }
        }
    }
    
    private func oscillationOffset(for index: Int, at date: Date) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        
        // Pulsing pattern: 1.5s oscillate, 0.75s pause, repeat
        let cycleTime = time.truncatingRemainder(dividingBy: 2.25)
        let isOscillating = cycleTime < 1.5
        
        guard isOscillating else { return 0 }
        
        // Triangular wave function
        let phaseTime = cycleTime * 4.0 // Faster oscillation frequency
        let triangularWave = abs(2.0 * (phaseTime - floor(phaseTime + 0.5))) - 0.5
        
        // Alternate direction for each letter
        let direction: CGFloat = index % 2 == 0 ? 1.0 : -1.0
        
        // Amplitude of 1.5 points (subtle vibration)
        return direction * triangularWave * 1.5
    }
}

// MARK: - AI Message Bubble
private struct AIMessageBubble: View {
    let message: Message
    let aiLoadingForMessage: String?
    @Binding var showCreateEvent: Bool
    @Binding var extractedEvent: ExtractedEventData
    
    var isLoading: Bool {
        aiLoadingForMessage == message.id
    }
    
    private func handleSuggestionTap(date: Date, originalMessage: String) {
        // Extract event details from the original conflict message
        var eventData = ExtractedEventData()
        eventData.date = date
        eventData.duration = 3600 // Default 1 hour
        
        // Extract meeting subject from the metadata tag
        if let subjectRange = originalMessage.range(of: #"\[MEETING_SUBJECT:([^\]]+)\]"#, options: .regularExpression),
           let match = try? NSRegularExpression(pattern: #"\[MEETING_SUBJECT:([^\]]+)\]"#).firstMatch(
               in: originalMessage,
               range: NSRange(originalMessage.startIndex..., in: originalMessage)
           ),
           let titleRange = Range(match.range(at: 1), in: originalMessage) {
            eventData.title = String(originalMessage[titleRange])
        } else {
            eventData.title = "Meeting"
        }
        
        extractedEvent = eventData
        showCreateEvent = true
    }
    
    private func parseSuggestedTimes(from text: String) -> [(Int, String, Date)] {
        var results: [(Int, String, Date)] = []
        
        // Match patterns like "• Option 1: Oct 24, 2025 at 4:00 PM"
        let lines = text.components(separatedBy: "\n")
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        for (index, line) in lines.enumerated() {
            // Extract the date string after "Option X: "
            if let colonRange = line.range(of: ":") {
                let dateString = String(line[colonRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                
                // Try to parse the date
                if let parsedDate = dateFormatter.date(from: dateString) {
                    results.append((index, dateString, parsedDate))
                }
            }
        }
        
        return results
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
                VStack(alignment: .leading, spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .padding(8)
                    } else {
                        // Check if this is a conflict detection message
                        if message.aiAction == "proactive_conflict_detection" {
                            // Animated header
                            OscillatingText(text: "Calendar Conflict Detected")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                            
                            // Compute cleaned body text
                            let bodyText: String = {
                                var text = message.text
                                    .replacingOccurrences(of: "**Calendar Conflict Detected**", with: "")
                                
                                // Remove metadata tag using a more explicit pattern
                                if let metadataRange = text.range(of: #"\[MEETING_SUBJECT:[^\]]+\]"#, options: .regularExpression) {
                                    text.removeSubrange(metadataRange)
                                }
                                
                                return text.trimmingCharacters(in: .whitespacesAndNewlines)
                            }()
                            
                            // Split text around "Suggested alternatives:"
                            if let range = bodyText.range(of: "**Suggested alternatives:**") {
                                // Text before suggestions
                                let beforeText = String(bodyText[..<range.lowerBound])
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                if !beforeText.isEmpty {
                                    Text(parseMarkdown(beforeText))
                                        .foregroundStyle(.white)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                
                                // Animated "Suggested alternatives:"
                                WalkingBumpsText(text: "Suggested alternatives:", color: .white)
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .padding(.top, 4)
                                
                                // Parse and display interactive suggestions
                                let afterText = String(bodyText[range.upperBound...])
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                ForEach(parseSuggestedTimes(from: afterText), id: \.0) { index, dateString, parsedDate in
                                    Button {
                                        handleSuggestionTap(date: parsedDate, originalMessage: message.text)
                                    } label: {
                                        Text("• Option \(index + 1): \(dateString)")
                                            .foregroundStyle(.white)
                                            .underline()
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                // No suggestions, just show the body text
                                Text(parseMarkdown(bodyText))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            // Regular AI message
                            Text(parseMarkdown(message.text))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
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
        .padding(.leading, 6)  // Add 6pt padding for AI messages
    }
}
