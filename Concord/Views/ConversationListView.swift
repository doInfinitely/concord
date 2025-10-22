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
    let openChat: (String) -> Void   // NEW: parent will push Chat

    @State private var conversations: [Conversation] = []
    @State private var showStartDM = false
    @State private var errorText: String?
    private let store = FirestoreService()

    var body: some View {
        Group {
            if conversations.isEmpty {
                ContentUnavailableView("No conversations yet",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Start a DM to get chatting."))
            } else {
                List(conversations, id: \.id) { convo in
                    Button {
                        openChat(convo.id)                 // <- tell parent to push
                    } label: {
                        ConversationRow(convo: convo, myUid: Auth.auth().currentUser?.uid)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Concord")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showStartDM = true
                } label: {
                    Label("Start DM", systemImage: "plus.bubble")
                }
            }
        }
        .sheet(isPresented: $showStartDM) {
            if let uid = Auth.auth().currentUser?.uid {
                StartDMView(myUid: uid) { other in
                    Task {
                        do {
                            let convId = try await store.openOrCreateDM(me: uid, other: other)
                            openChat(convId)                 // <- open newly created chat
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                }
            }
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
        .task {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            _ = store.listenConversations(for: uid) { items in
                conversations = items
            }
        }
    }
}


// MARK: - Row

private struct ConversationRow: View {
    let convo: Conversation
    let myUid: String?

    @State private var unread: Int? = nil
    @State private var online = false
    @State private var presenceListener: ListenerRegistration?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle().frame(width: 40, height: 40).opacity(0.15)
                    .overlay(Text(avatarInitials).font(.subheadline).bold())
                if online {
                    Circle().fill(.green).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
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
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.blue).foregroundStyle(.white)
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
        if let name = convo.name, !name.isEmpty { return name }
        if convo.memberCount == 2, let me = myUid,
           let other = convo.members.first(where: { $0 != me }) {
            return "DM with \(shortUid(other))"
        }
        return "Group (\(convo.memberCount))"
    }

    private var avatarInitials: String {
        if convo.memberCount == 2, let me = myUid,
           let other = convo.members.first(where: { $0 != me }) {
            return String(shortUid(other).prefix(2)).uppercased()
        }
        return "C"
    }

    private func shortUid(_ uid: String) -> String {
        uid.count <= 8 ? uid : "\(uid.prefix(4))…\(uid.suffix(4))"
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Start DM sheet (paste if you don't already have it)

struct StartDMView: View {
    let myUid: String
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var otherUid: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Other user's UID")) {
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
