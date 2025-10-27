//
//  RSVPListView.swift
//  Concord
//
//  Created by Remy Ochei on 10/26/25.
//

import SwiftUI
import FirebaseAuth

struct RSVPListView: View {
    @Environment(\.dismiss) var dismiss
    let conversationId: String
    let messageId: String
    
    @State private var rsvpResponses: [RSVPResponse] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    private let firestoreService = FirestoreService()
    
    init(conversationId: String, messageId: String) {
        self.conversationId = conversationId
        self.messageId = messageId
        print("🟣🟣🟣 RSVPListView INIT - conversationId: \(conversationId), messageId: \(messageId)")
    }
    
    var body: some View {
        print("🟣 RSVPListView body rendering - isLoading: \(isLoading), responses: \(rsvpResponses.count), error: \(errorMessage ?? "none")")
        return NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading RSVPs...")
                        .onAppear {
                            print("🟣 Showing loading spinner")
                        }
                } else if let errorMessage {
                    ContentUnavailableView("Error", systemImage: "xmark.octagon.fill", description: Text(errorMessage))
                        .onAppear {
                            print("🟣 Showing error: \(errorMessage)")
                        }
                } else if rsvpResponses.isEmpty {
                    ContentUnavailableView(
                        "No RSVPs yet",
                        systemImage: "person.3.fill",
                        description: Text("No one has responded to this event yet.")
                    )
                    .onAppear {
                        print("🟣 Showing empty state")
                    }
                } else {
                    List {
                        Section("Yes (\(rsvps(for: .yes).count))") {
                            ForEach(rsvps(for: .yes)) { response in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(response.displayName)
                                }
                            }
                        }
                        
                        Section("Maybe (\(rsvps(for: .maybe).count))") {
                            ForEach(rsvps(for: .maybe)) { response in
                                HStack {
                                    Image(systemName: "questionmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text(response.displayName)
                                }
                            }
                        }
                        
                        Section("No (\(rsvps(for: .no).count))") {
                            ForEach(rsvps(for: .no)) { response in
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(response.displayName)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("RSVP Responses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await fetchRSVPs()
            }
        }
    }
    
    private func fetchRSVPs() async {
        print("🔵 RSVPListView: Loading RSVPs for conversation: \(conversationId), message: \(messageId)")
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await firestoreService.fetchRSVPs(conversationId: conversationId, messageId: messageId)
            print("🔵 RSVPListView: Fetched \(fetched.count) RSVPs")
            for rsvp in fetched {
                print("  - \(rsvp.displayName): \(rsvp.status.rawValue)")
            }
            await MainActor.run {
                self.rsvpResponses = fetched
                self.isLoading = false
            }
        } catch {
            print("❌ RSVPListView: Error loading RSVPs: \(error)")
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    private func rsvps(for status: RSVPStatus) -> [RSVPResponse] {
        rsvpResponses.filter { $0.status == status }
    }
}

