//
//  GroupChatView.swift
//  Concord
//
//  Created by Remy Ochei on 10/21/25.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// MARK: - DM Contact Model
struct DMContact: Identifiable {
    let id: String // UID
    let displayName: String
    let email: String?
    let lastMessageAt: Date?
    
    var initials: String {
        if !displayName.isEmpty {
            let components = displayName.components(separatedBy: " ")
            if components.count >= 2 {
                return "\(components[0].prefix(1))\(components[1].prefix(1))".uppercased()
            }
            return String(displayName.prefix(2)).uppercased()
        }
        if let email = email {
            return String(email.prefix(2)).uppercased()
        }
        return "??"
    }
}

// MARK: - Create Group Chat View
struct CreateGroupChatView: View {
    @Environment(\.dismiss) private var dismiss
    let myUid: String
    let conversations: [Conversation] // NEW: pass conversations to extract DM partners
    let onCreate: (String) async throws -> Void
    
    @State private var groupName = ""
    @State private var selectedMembers: Set<String> = []
    @State private var memberUidInput = ""
    @State private var errorText: String?
    @State private var isCreating = false
    @State private var dmContacts: [DMContact] = [] // NEW: list of DM partners
    @State private var isLoadingContacts = true
    
    private let store = FirestoreService()
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Group Details") {
                    TextField("Group Name", text: $groupName)
                        .autocapitalization(.words)
                }
                
                // NEW: Add people from your DMs
                Section("Add from Your Chats") {
                    if isLoadingContacts {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .frame(height: 80)
                    } else if dmContacts.isEmpty {
                        Text("No DM contacts found")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .frame(height: 80)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(dmContacts) { contact in
                                    Button {
                                        toggleContact(contact.id)
                                    } label: {
                                        HStack {
                                            // Avatar
                                            Circle()
                                                .fill(Color.gray.opacity(0.2))
                                                .frame(width: 36, height: 36)
                                                .overlay(
                                                    Text(contact.initials)
                                                        .font(.caption)
                                                        .fontWeight(.semibold)
                                                        .foregroundStyle(.black)
                                                )
                                            
                                            // Name and email
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(contact.displayName)
                                                    .font(.body)
                                                    .foregroundStyle(.primary)
                                                
                                                if let email = contact.email {
                                                    Text(email)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            
                                            Spacer()
                                            
                                            // Checkmark if selected
                                            if selectedMembers.contains(contact.id) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.green)
                                            } else {
                                                Image(systemName: "circle")
                                                    .foregroundStyle(.gray)
                                            }
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 4)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    if contact.id != dmContacts.last?.id {
                                        Divider()
                                            .padding(.leading, 48)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 250)
                    }
                }
                
                Section("Or Add by UID") {
                    HStack {
                        TextField("Paste UID", text: $memberUidInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        
                        Button {
                            let trimmed = memberUidInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && trimmed != myUid && !selectedMembers.contains(trimmed) {
                                selectedMembers.insert(trimmed)
                                memberUidInput = ""
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(memberUidInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                
                if !selectedMembers.isEmpty {
                    Section("Selected Members (\(selectedMembers.count))") {
                        ForEach(Array(selectedMembers), id: \.self) { uid in
                            HStack {
                                // Show name if it's a DM contact, otherwise show UID
                                if let contact = dmContacts.first(where: { $0.id == uid }) {
                                    Circle()
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Text(contact.initials)
                                                .font(.caption2)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.black)
                                        )
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.displayName)
                                            .font(.body)
                                        
                                        if let email = contact.email {
                                            Text(email)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                } else {
                                    Text(shortUid(uid))
                                        .font(.system(.body, design: .monospaced))
                                }
                                
                                Spacer()
                                
                                Button {
                                    selectedMembers.remove(uid)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                
                Section {
                    Button {
                        createGroup()
                    } label: {
                        if isCreating {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Create Group")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(groupName.isEmpty || selectedMembers.isEmpty || isCreating)
                }
            }
            .navigationTitle("New Group Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: {
                if let error = errorText {
                    Text(error)
                }
            }
            .task {
                await loadDMContacts()
            }
        }
    }
    
    private func toggleContact(_ uid: String) {
        if selectedMembers.contains(uid) {
            selectedMembers.remove(uid)
        } else {
            selectedMembers.insert(uid)
        }
    }
    
    private func loadDMContacts() async {
        isLoadingContacts = true
        defer { isLoadingContacts = false }
        
        // Extract DM partners from conversations (ordered as in ConversationListView)
        let dmConversations = conversations.filter { convo in
            convo.memberCount == 2 && convo.members.contains(myUid)
        }
        
        // Get the other person's UID for each DM
        var contacts: [DMContact] = []
        
        for convo in dmConversations {
            guard let otherUid = convo.members.first(where: { $0 != myUid }) else { continue }
            
            // Fetch user profile
            do {
                let userDoc = try await Firestore.firestore()
                    .collection("users")
                    .document(otherUid)
                    .getDocument()
                
                if let data = userDoc.data() {
                    let displayName = (data["displayName"] as? String) ?? (data["email"] as? String) ?? "Unknown"
                    let email = data["email"] as? String
                    
                    contacts.append(DMContact(
                        id: otherUid,
                        displayName: displayName,
                        email: email,
                        lastMessageAt: convo.lastMessageAt
                    ))
                }
            } catch {
                print("⚠️ Failed to fetch user \(otherUid): \(error)")
            }
        }
        
        await MainActor.run {
            dmContacts = contacts
        }
    }
    
    private func createGroup() {
        guard !groupName.isEmpty, !selectedMembers.isEmpty else { return }
        
        isCreating = true
        Task {
            defer { isCreating = false }
            
            do {
                // Add self to members
                var allMembers = Array(selectedMembers)
                allMembers.append(myUid)
                
                let conversationId = try await store.createConversation(
                    members: allMembers,
                    name: groupName
                )
                
                try await onCreate(conversationId)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
    
    private func shortUid(_ uid: String) -> String {
        uid.count <= 12 ? uid : "\(uid.prefix(6))...\(uid.suffix(6))"
    }
}

// MARK: - Group Chat Info View
struct GroupChatInfoView: View {
    let conversationId: String
    let conversation: Conversation
    
    @State private var members: [UserProfile] = []
    @State private var isLoadingMembers = true
    
    private let store = FirestoreService()
    
    var body: some View {
        NavigationStack {
            List {
                Section("Group Details") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(conversation.name ?? "Unnamed Group")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("Members")
                        Spacer()
                        Text("\(conversation.memberCount)")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Members") {
                    if isLoadingMembers {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        ForEach(members, id: \.uid) { member in
                            HStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 40, height: 40)
                                    .overlay(
                                        Text(member.initials)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                    )
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(member.displayName ?? "Unknown")
                                        .font(.headline)
                                    if let email = member.email {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                if member.uid == Auth.auth().currentUser?.uid {
                                    Text("You")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadMembers()
            }
        }
    }
    
    private func loadMembers() async {
        isLoadingMembers = true
        defer { isLoadingMembers = false }
        
        do {
            members = try await store.fetchUserProfiles(uids: conversation.members)
        } catch {
            print("Error loading members: \(error.localizedDescription)")
        }
    }
}

// MARK: - User Profile Model
struct UserProfile: Identifiable {
    let id: String
    let uid: String
    let displayName: String?
    let email: String?
    
    var initials: String {
        if let name = displayName, !name.isEmpty {
            let components = name.components(separatedBy: " ")
            if components.count >= 2 {
                return "\(components[0].prefix(1))\(components[1].prefix(1))".uppercased()
            }
            return String(name.prefix(2)).uppercased()
        }
        if let email = email {
            return String(email.prefix(2)).uppercased()
        }
        return "??"
    }
}

// MARK: - FirestoreService Extension for Groups
extension FirestoreService {
    func fetchUserProfiles(uids: [String]) async throws -> [UserProfile] {
        var profiles: [UserProfile] = []
        
        // Use Firestore.firestore() directly instead of private db
        let db = Firestore.firestore()
        
        for uid in uids {
            let docSnap = try await db.collection("users").document(uid).getDocument()
            let data = docSnap.data() ?? [:]
            profiles.append(UserProfile(
                id: uid,
                uid: uid,
                displayName: data["displayName"] as? String,
                email: data["email"] as? String
            ))
        }
        
        return profiles
    }
}
