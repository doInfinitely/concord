//
//  GroupChatView.swift
//  Concord
//
//  Created by Remy Ochei on 10/21/25.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// MARK: - Create Group Chat View
struct CreateGroupChatView: View {
    @Environment(\.dismiss) private var dismiss
    let myUid: String
    let onCreate: (String) async throws -> Void
    
    @State private var groupName = ""
    @State private var selectedMembers: Set<String> = []
    @State private var memberUidInput = ""
    @State private var errorText: String?
    @State private var isCreating = false
    
    private let store = FirestoreService()
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Group Details") {
                    TextField("Group Name", text: $groupName)
                        .autocapitalization(.words)
                }
                
                Section("Add Members") {
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
                                Text(shortUid(uid))
                                    .font(.system(.body, design: .monospaced))
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
