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
        GeometryReader { geometry in
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
                                },
                                showCreateEvent: $showCreateEvent,
                                extractedEvent: $extractedEvent
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
                                    },
                                    showCreateEvent: $showCreateEvent,
                                    extractedEvent: $extractedEvent
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
            .clipShape(RoundedRectangle(cornerRadius: 0))
            .shadow(radius: 0)
            .padding(.horizontal, 0)
            .padding(.vertical, 0)
                
                // Physics thread on the left side (on top of everything)
                HStack(spacing: 0) {
                    PhysicsThreadView(height: geometry.size.height)
                    Spacer()
                }
            }
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
    @Binding var showCreateEvent: Bool
    @Binding var extractedEvent: ExtractedEventData
    
    @State private var senderName: String?
    
    var body: some View {
        // AI messages render as black bubbles
        if message.isAI {
            return AnyView(AIThreadMessageBubble(
                message: message,
                aiLoadingForMessage: aiLoadingForMessage,
                showCreateEvent: $showCreateEvent,
                extractedEvent: $extractedEvent
            ))
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
            .padding(.leading, isMe ? 0 : 12)  // Add 12pt padding for other person's messages
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

