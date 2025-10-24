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
    
    private let store = FirestoreService()

    var body: some View {
        NavigationStack {
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
            if convo.memberCount == 2, let me = myUid,
               let other = convo.members.first(where: { $0 != me }) {
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
                presenceListener = Firestore.firestore()
                    .collection("users").document(other)
                    .addSnapshotListener { snap, _ in
                        if let ts = (snap?.data()?["lastSeen"] as? Timestamp)?.dateValue() {
                            DispatchQueue.main.async {
                                let window = PresenceService.onlineWindow
                                online = Date().timeIntervalSince(ts) < window
                            }
                        } else {
                            DispatchQueue.main.async { online = false }
                        }
                    }
            }
        }
        .onDisappear {
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
    @State private var dashOffsets: [Double] = Array(repeating: 0.0, count: 8)
    @State private var angleWiggles: [Double] = Array(repeating: 0.0, count: 8)
    
    var body: some View {
        TimelineView(.animation) { timeline in
            ZStack {
                // Radiating lines with animated dashes
                ForEach(0..<8) { i in
                    let progress = dashOffsets[i]
                    let angleWiggle = angleWiggles[i]
                    
                    ZStack {
                        // Black background ray with gradient to white at tip
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: 0.5),
                                .init(color: .white, location: 1.0)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: 2, height: 8)
                        .offset(y: -10)
                        
                        // White dash traveling outward (always rendered, opacity controls visibility)
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2, height: 3)
                            .offset(y: -6 - (progress * 8))
                            .opacity(progress < 1.0 ? 1.0 : 0.0)
                    }
                    .rotationEffect(.degrees(Double(i) * 45 + angleWiggle))
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
                // Initialize with random offsets
                dashOffsets = (0..<8).map { _ in Double.random(in: 0...1) }
                angleWiggles = (0..<8).map { _ in Double.random(in: -5...5) }
                startAnimations()
                startWiggleAnimations()
            }
        }
    }
    
    private func startAnimations() {
        // Animate each dash independently with random delays
        for i in 0..<8 {
            let randomDelay = Double.random(in: 0...2)
            
            Task {
                try? await Task.sleep(nanoseconds: UInt64(randomDelay * 1_000_000_000))
                await animateDash(index: i)
            }
        }
    }
    
    private func startWiggleAnimations() {
        // Animate each ray's angle independently
        for i in 0..<8 {
            Task {
                await animateWiggle(index: i)
            }
        }
    }
    
    @MainActor
    private func animateDash(index: Int) async {
        while true {
            let startTime = Date()
            let duration: TimeInterval = 0.6
            
            // Smoothly increment progress over duration
            while Date().timeIntervalSince(startTime) < duration {
                let elapsed = Date().timeIntervalSince(startTime)
                dashOffsets[index] = min(elapsed / duration, 1.0)
                try? await Task.sleep(nanoseconds: 16_000_000) // ~60fps update
            }
            
            dashOffsets[index] = 1.0
            try? await Task.sleep(nanoseconds: 100_000_000) // Brief pause at end
            
            // Reset and wait random time before next dash
            dashOffsets[index] = 0.0
            let randomWait = Double.random(in: 0.5...2.0)
            try? await Task.sleep(nanoseconds: UInt64(randomWait * 1_000_000_000))
        }
    }
    
    @MainActor
    private func animateWiggle(index: Int) async {
        while true {
            // Random target angle wiggle between -5 and +5 degrees
            let targetWiggle = Double.random(in: -5...5)
            let startWiggle = angleWiggles[index]
            let startTime = Date()
            let duration: TimeInterval = Double.random(in: 0.3...0.8) // Random duration for organic motion
            
            // Smoothly interpolate to target angle
            while Date().timeIntervalSince(startTime) < duration {
                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(elapsed / duration, 1.0)
                angleWiggles[index] = startWiggle + (targetWiggle - startWiggle) * progress
                try? await Task.sleep(nanoseconds: 16_000_000) // ~60fps update
            }
            
            angleWiggles[index] = targetWiggle
            
            // Brief pause before next wiggle
            try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.1...0.3) * 1_000_000_000))
        }
    }
}

#Preview {
    ConversationListView(selectedConversationId: .constant(nil))
        .environmentObject(AuthService())
}
