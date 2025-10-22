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

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .frame(width: 50, height: 50)
                    .opacity(0.15)
                    .overlay(
                        Text(avatarInitials)
                            .font(.headline)
                            .bold()
                    )
                if online && convo.memberCount == 2 {
                    Circle()
                        .fill(.green)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    
                    if convo.memberCount > 2 {
                        Text("(\(convo.memberCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Text(convo.lastMessageText ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let t = convo.lastMessageAt {
                    Text(relativeDate(t))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let u = unread, u > 0 {
                    Text("\(u)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.blue)
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
        if convo.memberCount == 2, let me = myUid,
           let other = convo.members.first(where: { $0 != me }) {
            return "DM with \(shortUid(other))"
        }
        return "Group Chat"
    }

    private var avatarInitials: String {
        if let name = convo.name, !name.isEmpty {
            return String(name.prefix(2)).uppercased()
        }
        if convo.memberCount == 2, let me = myUid,
           let other = convo.members.first(where: { $0 != me }) {
            return String(shortUid(other).prefix(2)).uppercased()
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
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let user = auth.user {
                        if let displayName = user.displayName {
                            LabeledContent("Name", value: displayName)
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
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("UID Copied!", isPresented: $showCopiedAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your UID has been copied to the clipboard")
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

#Preview {
    ConversationListView(selectedConversationId: .constant(nil))
        .environmentObject(AuthService())
}
