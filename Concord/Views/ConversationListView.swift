//
//  ConversationListView.swift
//  Concord
//
//  Created by Remy Ochei on 10/21/25.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct ConversationListView: View {
    @EnvironmentObject var auth: AuthService
    @Binding var selectedConversationId: String?
    
    @State private var conversations: [Conversation] = []
    @State private var selection: Conversation?
    @State private var showStartDM = false
    @State private var showCreateGroup = false
    @State private var showProfile = false
    @State private var errorText: String?
    
    // Search state
    @State private var searchText = ""
    @State private var showAdvancedSearch = false
    @State private var showSearchResults = false
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching = false
    
    // Advanced search filters
    @State private var searchKeywords = ""
    @State private var selectedSenders: Set<String> = []
    @State private var dateRangeStart: Date?
    @State private var dateRangeEnd: Date?
    @State private var naturalLanguageQuery = ""
    
    private let store = FirestoreService()
    private let aiService = AIService()

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(red: 242/255, green: 242/255, blue: 242/255)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Main content
                    Group {
                        if conversations.isEmpty {
                            ContentUnavailableView(
                                "No conversations yet",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Start a DM or create a group to get chatting.")
                            )
                        } else {
                            List(conversations, id: \.id, selection: $selection) { convo in
                                Button {
                                    selection = convo
                                } label: {
                                    ConversationRow(convo: convo, myUid: auth.uid)
                                }
                            }
                            .listStyle(.insetGrouped)
                        }
                    }
                
                // Search bar at bottom
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        
                        TextField("Search messages...", text: $searchText)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                performSimpleSearch()
                            }
                        
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    
                    Button {
                        showAdvancedSearch = true
                    } label: {
                        Text("Advanced")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                    .overlay(
                        Divider(),
                        alignment: .top
                    )
                }
            }
            .navigationTitle("Concord")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showProfile = true
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showStartDM = true
                        } label: {
                            Label("Start DM", systemImage: "person.badge.plus")
                        }
                        
                        Button {
                            showCreateGroup = true
                        } label: {
                            Label("Create Group", systemImage: "person.3")
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                }
            }
            .navigationDestination(item: $selection) { convo in
                ChatView(conversationId: convo.id)
            }
            .sheet(isPresented: $showStartDM) {
                if let uid = auth.uid {
                    StartDMView(myUid: uid) { other in
                        Task {
                            do {
                                let convId = try await store.openOrCreateDM(me: uid, other: other)
                                selection = Conversation(
                                    id: convId,
                                    members: [uid, other],
                                    memberCount: 2,
                                    name: nil,
                                    lastMessageText: nil,
                                    lastMessageAt: nil
                                )
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showCreateGroup) {
                if let uid = auth.uid {
                    CreateGroupChatView(myUid: uid) { conversationId in
                        // Fetch the created conversation
                        let convSnap = try await Firestore.firestore()
                            .collection("conversations")
                            .document(conversationId)
                            .getDocument()
                        
                        if let data = convSnap.data() {
                            let convo = Conversation(
                                id: conversationId,
                                members: data["members"] as? [String] ?? [],
                                memberCount: data["memberCount"] as? Int ?? 0,
                                name: data["name"] as? String,
                                lastMessageText: nil,
                                lastMessageAt: nil
                            )
                            selection = convo
                        }
                    }
                }
            }
            .sheet(isPresented: $showProfile) {
                ProfileView()
            }
            .sheet(isPresented: $showAdvancedSearch) {
                AdvancedSearchView(
                    keywords: $searchKeywords,
                    selectedSenders: $selectedSenders,
                    dateRangeStart: $dateRangeStart,
                    dateRangeEnd: $dateRangeEnd,
                    naturalLanguageQuery: $naturalLanguageQuery,
                    onSearch: performAdvancedSearch
                )
            }
            .sheet(isPresented: $showSearchResults) {
                SearchResultsView(
                    results: searchResults,
                    keywords: searchKeywords.isEmpty ? searchText : searchKeywords,
                    onResultTap: handleSearchResultTap,
                    onRefresh: {
                        await performSearchRefresh()
                    }
                )
            }
            .overlay {
                if let err = errorText {
                    VStack {
                        Spacer()
                        Text(err)
                            .font(.footnote)
                            .padding(8)
                            .background(.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, 8)
                    }
                }
                
                if isSearching {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    VStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .padding()
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        Text("Searching...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            guard let uid = auth.uid else { return }
            _ = store.listenConversations(for: uid) { items in
                conversations = items
            }
        }
        .onChange(of: selectedConversationId) { _, newValue in
            if let id = newValue,
               let convo = conversations.first(where: { $0.id == id }) {
                selection = convo
                selectedConversationId = nil // Reset after navigation
            }
        }
    }
    
    // MARK: - Search Methods
    
    private func performSimpleSearch() {
        guard !searchText.isEmpty, let userId = auth.uid else { return }
        
        Task {
            isSearching = true
            defer { isSearching = false }
            
            do {
                searchKeywords = searchText
                selectedSenders = []
                dateRangeStart = nil
                dateRangeEnd = nil
                naturalLanguageQuery = ""
                
                let results = try await store.searchMessages(
                    userId: userId,
                    keywords: searchText,
                    senderIds: nil,
                    dateRange: nil,
                    limit: 100
                )
                
                searchResults = results
                showSearchResults = true
            } catch {
                errorText = "Search failed: \(error.localizedDescription)"
            }
        }
    }
    
    private func performAdvancedSearch() {
        guard let userId = auth.uid else { return }
        
        Task {
            isSearching = true
            defer { isSearching = false }
            
            do {
                // Check if only natural language query is provided (no filters)
                let hasFilters = !searchKeywords.isEmpty || !selectedSenders.isEmpty || (dateRangeStart != nil && dateRangeEnd != nil)
                
                // Stage 1: Firestore query with filters
                let senderIds = selectedSenders.isEmpty ? nil : Array(selectedSenders)
                let dateRange = (dateRangeStart != nil && dateRangeEnd != nil) ? (dateRangeStart!, dateRangeEnd!) : nil
                
                // If only NL query provided, fetch more messages for AI to rank
                let limit = (!hasFilters && !naturalLanguageQuery.isEmpty) ? 300 : 100
                
                var results = try await store.searchMessages(
                    userId: userId,
                    keywords: searchKeywords.isEmpty ? nil : searchKeywords,
                    senderIds: senderIds,
                    dateRange: dateRange,
                    limit: limit
                )
                
                // Stage 2: AI ranking if natural language query provided
                if !naturalLanguageQuery.isEmpty && !results.isEmpty {
                    print("🤖 Applying AI ranking with query: \(naturalLanguageQuery)")
                    results = try await aiService.intelligentSearch(
                        results: results,
                        naturalLanguageQuery: naturalLanguageQuery
                    )
                }
                
                searchResults = results
                showSearchResults = true
            } catch {
                errorText = "Search failed: \(error.localizedDescription)"
            }
        }
    }
    
    private func performSearchRefresh() async {
        guard let userId = auth.uid else { return }
        
        do {
            // Re-run the last search
            let senderIds = selectedSenders.isEmpty ? nil : Array(selectedSenders)
            let dateRange = (dateRangeStart != nil && dateRangeEnd != nil) ? (dateRangeStart!, dateRangeEnd!) : nil
            let keywords = searchKeywords.isEmpty ? (searchText.isEmpty ? nil : searchText) : searchKeywords
            
            // Check if only natural language query is provided (no filters)
            let hasFilters = keywords != nil || !selectedSenders.isEmpty || dateRange != nil
            
            // If only NL query provided, fetch more messages for AI to rank
            let limit = (!hasFilters && !naturalLanguageQuery.isEmpty) ? 300 : 100
            
            var results = try await store.searchMessages(
                userId: userId,
                keywords: keywords,
                senderIds: senderIds,
                dateRange: dateRange,
                limit: limit
            )
            
            // Apply AI ranking if needed
            if !naturalLanguageQuery.isEmpty && !results.isEmpty {
                results = try await aiService.intelligentSearch(
                    results: results,
                    naturalLanguageQuery: naturalLanguageQuery
                )
            }
            
            searchResults = results
        } catch {
            errorText = "Search refresh failed: \(error.localizedDescription)"
        }
    }
    
    private func handleSearchResultTap(_ result: SearchResult) {
        // Navigate to the conversation and scroll to the message
        if let convo = conversations.first(where: { $0.id == result.conversationId }) {
            selection = convo
            // Store the message ID to highlight in ChatView
            // We'll need to pass this through somehow - for now just navigate
        }
    }
}

// MARK: - Conversation Row
private struct ConversationRow: View {
    let convo: Conversation
    let myUid: String?

    @State private var unread: Int? = nil
    @State private var online = false
    @State private var presenceListener: ListenerRegistration?
    @State private var otherUserDisplayName: String?

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(.gray.opacity(0.15))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Text(avatarInitials)
                            .font(.headline)
                            .bold()
                            .foregroundStyle(.black)
                    )
                
                let _ = print("🎨 Rendering avatar for \(convo.id): online=\(online), memberCount=\(convo.memberCount), showing indicator=\(online && convo.memberCount == 2)")
                
                if online && convo.memberCount == 2 {
                    AnimatedPresenceDot()
                        .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    
                    if convo.memberCount > 2 {
                        Text("(\(convo.memberCount))")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
                
                Text(convo.lastMessageText ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let t = convo.lastMessageAt {
                    Text(relativeDate(t))
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                if let u = unread, u > 0 {
                    Text("\(u)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .onAppear {
            print("👁️ ConversationRow onAppear for \(convo.id)")
            if convo.memberCount == 2, let me = myUid,
               let other = convo.members.first(where: { $0 != me }) {
                print("🔍 Setting up presence listener for DM with \(other)")
                
                // Load other user's display name
                Task {
                    do {
                        let userSnap = try await Firestore.firestore()
                            .collection("users")
                            .document(other)
                            .getDocument()
                        
                        if let data = userSnap.data() {
                            let displayName = data["displayName"] as? String
                            let email = data["email"] as? String
                            await MainActor.run {
                                otherUserDisplayName = displayName ?? email ?? shortUid(other)
                            }
                        }
                    } catch {
                        print("Error loading user display name: \(error)")
                    }
                }
                
                // Set up presence listener
                print("📡 Creating presence listener for \(other)")
                presenceListener = Firestore.firestore()
                    .collection("users").document(other)
                    .addSnapshotListener { snap, error in
                        if let error = error {
                            print("❌ Presence listener error for \(other): \(error)")
                            return
                        }
                        
                        print("👀 Presence snapshot for \(other): exists=\(snap?.exists ?? false)")
                        if let data = snap?.data() {
                            print("   Data keys: \(data.keys.joined(separator: ", "))")
                            if let ts = data["lastSeen"] as? Timestamp {
                                let date = ts.dateValue()
                                let age = Date().timeIntervalSince(date)
                                print("   lastSeen: \(date) (age: \(age)s)")
                                DispatchQueue.main.async {
                                    let window = PresenceService.onlineWindow
                                    let isOnline = age < window
                                    print("   Setting online=\(isOnline) (window=\(window)s)")
                                    online = isOnline
                                }
                            } else {
                                print("   No lastSeen timestamp found")
                                DispatchQueue.main.async { online = false }
                            }
                        } else {
                            print("   No data in snapshot")
                            DispatchQueue.main.async { online = false }
                        }
                    }
                print("✅ Presence listener created for \(other)")
            } else {
                print("⏭️ Skipping presence for conversation \(convo.id) (memberCount=\(convo.memberCount))")
            }
        }
        .onDisappear {
            print("👋 ConversationRow onDisappear for \(convo.id)")
            presenceListener?.remove()
            presenceListener = nil
        }
    }

    private var title: String {
        if let name = convo.name, !name.isEmpty {
            return name
        }
        if convo.memberCount == 2 {
            // Use loaded display name if available, otherwise show loading or UID
            if let displayName = otherUserDisplayName {
                return displayName
            }
            // Still loading or no display name found
            if let me = myUid, let other = convo.members.first(where: { $0 != me }) {
                return shortUid(other)
            }
        }
        return "Group Chat"
    }

    private var avatarInitials: String {
        if let name = convo.name, !name.isEmpty {
            return String(name.prefix(2)).uppercased()
        }
        if convo.memberCount == 2 {
            // Use loaded display name if available
            if let displayName = otherUserDisplayName {
                let components = displayName.components(separatedBy: " ")
                if components.count >= 2 {
                    return "\(components[0].prefix(1))\(components[1].prefix(1))".uppercased()
                }
                return String(displayName.prefix(2)).uppercased()
            }
            // Still loading or no display name
            if let me = myUid, let other = convo.members.first(where: { $0 != me }) {
                return String(shortUid(other).prefix(2)).uppercased()
            }
        }
        return "G"
    }

    private func shortUid(_ uid: String) -> String {
        uid.count <= 8 ? uid : "\(uid.prefix(4))…\(uid.suffix(4))"
    }

    private func relativeDate(_ date: Date) -> String {
        let now = Date()
        let seconds = now.timeIntervalSince(date)
        
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        if seconds < 604800 { return "\(Int(seconds / 86400))d" }
        return "\(Int(seconds / 604800))w"
    }
}

// MARK: - Profile View
private struct ProfileView: View {
    @EnvironmentObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var showCopiedAlert = false
    @State private var isEditingName = false
    @State private var displayName = ""
    @State private var isSavingName = false
    @State private var saveError: String?
    @StateObject private var calendarService = CalendarService()
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let user = auth.user {
                        // Editable Display Name
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Name")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                
                                if isEditingName {
                                    TextField("Display Name", text: $displayName)
                                        .textInputAutocapitalization(.words)
                                } else {
                                    Text(user.displayName ?? "Not set")
                                        .font(.body)
                                }
                            }
                            
                            Spacer()
                            
                            if isEditingName {
                                if isSavingName {
                                    ProgressView()
                                } else {
                                    Button("Save") {
                                        saveName()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            } else {
                                Button {
                                    displayName = user.displayName ?? ""
                                    isEditingName = true
                                } label: {
                                    Text("Edit")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        
                        if let email = user.email {
                            LabeledContent("Email", value: email)
                        }
                        
                        // UID with Copy Button
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("UID")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(user.uid)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            
                            Spacer()
                            
                            Button {
                                UIPasteboard.general.string = user.uid
                                showCopiedAlert = true
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                
                Section("Calendars") {
                    // Apple Calendar
                    HStack {
                        Label("Apple Calendar", systemImage: "calendar")
                        Spacer()
                        if calendarService.isAppleCalendarConnected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Disconnect") {
                                Task {
                                    do {
                                        try await calendarService.disconnectAppleCalendar()
                                    } catch {
                                        print("❌ Error disconnecting Apple Calendar: \(error)")
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Connect") {
                                Task {
                                    do {
                                        let granted = try await calendarService.requestAppleCalendarAccess()
                                        if !granted {
                                            print("⚠️ Calendar access denied")
                                        }
                                    } catch {
                                        print("❌ Error requesting calendar access: \(error)")
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    
                    // Google Calendar
                    HStack {
                        Label("Google Calendar", systemImage: "calendar.badge.clock")
                        Spacer()
                        if calendarService.isGoogleCalendarConnected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Disconnect") {
                                Task {
                                    do {
                                        try await calendarService.disconnectGoogleCalendar()
                                    } catch {
                                        print("❌ Error disconnecting Google Calendar: \(error)")
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Connect") {
                                Task {
                                    do {
                                        try await calendarService.connectGoogleCalendar()
                                    } catch {
                                        print("❌ Error connecting Google Calendar: \(error)")
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .task {
                    await calendarService.loadCalendarStatus()
                }
                
                Section {
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditingName ? "Cancel" : "Done") {
                        if isEditingName {
                            isEditingName = false
                            saveError = nil
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .alert("UID Copied!", isPresented: $showCopiedAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your UID has been copied to the clipboard")
            }
            .alert("Error", isPresented: .constant(saveError != nil)) {
                Button("OK") { saveError = nil }
            } message: {
                if let error = saveError {
                    Text(error)
                }
            }
        }
    }
    
    private func saveName() {
        guard let user = auth.user else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        isSavingName = true
        Task {
            do {
                // Update Firebase Auth profile
                let changeRequest = user.createProfileChangeRequest()
                changeRequest.displayName = trimmed
                try await changeRequest.commitChanges()
                
                // Update Firestore user document
                try await Firestore.firestore()
                    .collection("users")
                    .document(user.uid)
                    .setData(["displayName": trimmed], merge: true)
                
                await MainActor.run {
                    isSavingName = false
                    isEditingName = false
                    // Trigger auth refresh to update UI
                    auth.user = Auth.auth().currentUser
                }
            } catch {
                await MainActor.run {
                    isSavingName = false
                    saveError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Start DM View (keep existing one)
private struct StartDMView: View {
    @Environment(\.dismiss) private var dismiss
    let myUid: String
    let onOpen: (String) -> Void
    @State private var otherUid = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste UID here", text: $otherUid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
                Section {
                    Button("Open or Create DM") {
                        let trimmed = otherUid.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, trimmed != myUid else { return }
                        onOpen(trimmed)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(otherUid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || otherUid == myUid)
                }
            }
            .navigationTitle("Start DM")
        }
    }
}

// MARK: - Create Event View
struct CreateEventView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var calendarService: CalendarService
    @Binding var eventData: ExtractedEventData
    
    @State private var selectedCalendar: CalendarInfo?
    @State private var conflicts: [CalendarEvent] = []
    @State private var isCheckingConflicts = false
    @State private var isCreatingEvent = false
    @State private var showSuccess = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Event Details") {
                    TextField("Title", text: $eventData.title)
                    
                    DatePicker("Date & Time", selection: Binding(
                        get: { eventData.date ?? Date() },
                        set: { eventData.date = $0 }
                    ))
                    
                    HStack {
                        Text("Duration")
                        Spacer()
                        Picker("Duration", selection: $eventData.duration) {
                            Text("15 min").tag(TimeInterval(900))
                            Text("30 min").tag(TimeInterval(1800))
                            Text("1 hour").tag(TimeInterval(3600))
                            Text("2 hours").tag(TimeInterval(7200))
                            Text("3 hours").tag(TimeInterval(10800))
                        }
                        .pickerStyle(.menu)
                    }
                    
                    TextField("Location", text: Binding(
                        get: { eventData.location ?? "" },
                        set: { eventData.location = $0.isEmpty ? nil : $0 }
                    ))
                    
                    TextField("Notes", text: Binding(
                        get: { eventData.notes ?? "" },
                        set: { eventData.notes = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .lineLimit(3...6)
                }
                
                Section("Calendar") {
                    Picker("Select Calendar", selection: $selectedCalendar) {
                        Text("Choose...").tag(nil as CalendarInfo?)
                        ForEach(calendarService.availableCalendars) { calendar in
                            HStack {
                                Image(systemName: calendar.type == .apple ? "calendar" : "calendar.badge.clock")
                                Text(calendar.title)
                            }
                            .tag(calendar as CalendarInfo?)
                        }
                    }
                }
                
                if isCheckingConflicts {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Checking for conflicts...")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !conflicts.isEmpty {
                    Section {
                        Label("Scheduling Conflicts", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        
                        ForEach(conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conflict.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("\(conflict.startDate.formatted(date: .omitted, time: .shortened)) - \(conflict.endDate.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Create Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createEvent()
                    }
                    .disabled(eventData.title.isEmpty || eventData.date == nil || selectedCalendar == nil || isCreatingEvent)
                }
            }
            .task {
                // Select first available calendar by default
                if selectedCalendar == nil, let first = calendarService.availableCalendars.first {
                    selectedCalendar = first
                }
                
                // Check for conflicts
                await checkConflicts()
            }
            .onChange(of: eventData.date) { _, _ in
                Task {
                    await checkConflicts()
                }
            }
            .onChange(of: selectedCalendar) { _, _ in
                Task {
                    await checkConflicts()
                }
            }
            .alert("Event Created", isPresented: $showSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Your event has been added to your calendar.")
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
        }
    }
    
    private func checkConflicts() async {
        guard let date = eventData.date,
              let calendar = selectedCalendar else {
            return
        }
        
        isCheckingConflicts = true
        
        do {
            conflicts = try await calendarService.checkConflicts(
                date: date,
                duration: eventData.duration,
                calendarId: calendar.id
            )
        } catch {
            print("❌ Error checking conflicts: \(error)")
        }
        
        await MainActor.run {
            isCheckingConflicts = false
        }
    }
    
    private func createEvent() {
        guard let date = eventData.date,
              let calendar = selectedCalendar else {
            return
        }
        
        isCreatingEvent = true
        
        Task {
            do {
                if calendar.type == .apple {
                    _ = try await calendarService.createAppleCalendarEvent(
                        calendarId: calendar.id,
                        title: eventData.title,
                        startDate: date,
                        duration: eventData.duration,
                        location: eventData.location,
                        notes: eventData.notes,
                        attendees: eventData.attendees ?? []
                    )
                } else {
                    _ = try await calendarService.createGoogleCalendarEvent(
                        calendarId: calendar.id,
                        title: eventData.title,
                        startDate: date,
                        duration: eventData.duration,
                        location: eventData.location,
                        notes: eventData.notes,
                        attendees: eventData.attendees
                    )
                }
                
                await MainActor.run {
                    isCreatingEvent = false
                    showSuccess = true
                }
            } catch {
                await MainActor.run {
                    isCreatingEvent = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Animated Presence Dot
private struct AnimatedPresenceDot: View {
    @State private var rayLengths: [Double] = Array(repeating: 1.0, count: 8)
    
    var body: some View {
        TimelineView(.animation) { timeline in
            ZStack {
                // Radiating lines that oscillate in and out
                ForEach(0..<8) { i in
                    let lengthScale = rayLengths[i]
                    let baseHeight = 8.0
                    let currentHeight = baseHeight * lengthScale
                    let baseOffset = 10.0
                    let currentOffset = baseOffset * lengthScale
                    
                    // Black ray with gradient to white at tip
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.5),
                            .init(color: .white, location: 1.0)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: 2, height: currentHeight)
                    .offset(y: -currentOffset)
                    .rotationEffect(.degrees(Double(i) * 45))
                }
                
                // White circle with black border
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                
                Circle()
                    .stroke(.black, lineWidth: 2)
                    .frame(width: 12, height: 12)
            }
            .onAppear {
                // Initialize with random phases
                rayLengths = (0..<8).map { _ in Double.random(in: 0.8...1.2) }
                startRadialAnimations()
            }
        }
    }
    
    private func startRadialAnimations() {
        // Animate each ray independently with random delays
        for i in 0..<8 {
            let randomDelay = Double.random(in: 0...1)
            
            Task {
                try? await Task.sleep(nanoseconds: UInt64(randomDelay * 1_000_000_000))
                await animateRay(index: i)
            }
        }
    }
    
    @MainActor
    private func animateRay(index: Int) async {
        while true {
            // Oscillate between 0.7 and 1.3 (70% to 130% of base length)
            let minLength = 0.7
            let maxLength = 1.3
            let currentLength = rayLengths[index]
            
            // Determine next target (alternate between extending and contracting)
            let targetLength = currentLength < 1.0 ? maxLength : minLength
            
            let startTime = Date()
            let duration: TimeInterval = Double.random(in: 0.6...1.0)
            
            // Smoothly interpolate to target length (30fps)
            while Date().timeIntervalSince(startTime) < duration {
                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(elapsed / duration, 1.0)
                // Use ease-in-out for smoother oscillation
                let easedProgress = (1 - cos(progress * .pi)) / 2
                rayLengths[index] = currentLength + (targetLength - currentLength) * easedProgress
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30fps
            }
            
            rayLengths[index] = targetLength
            
            // Brief pause at each extreme
            try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.1...0.3) * 1_000_000_000))
        }
    }
}

#Preview {
    ConversationListView(selectedConversationId: .constant(nil))
        .environmentObject(AuthService())
}
