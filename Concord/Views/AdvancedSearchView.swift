//
//  AdvancedSearchView.swift
//  Concord
//
//  Advanced search interface with filters and natural language query
//

import SwiftUI
import FirebaseAuth

struct AdvancedSearchView: View {
    @Environment(\.dismiss) private var dismiss
    
    @Binding var keywords: String
    @Binding var selectedSenders: Set<String>
    @Binding var dateRangeStart: Date?
    @Binding var dateRangeEnd: Date?
    @Binding var naturalLanguageQuery: String
    
    let onSearch: () -> Void
    
    @State private var chatPartners: [(id: String, displayName: String)] = []
    @State private var isLoadingPartners = false
    @State private var useDateRange = false
    @State private var showSenderPicker = false
    
    private let firestoreService = FirestoreService()
    
    var body: some View {
        NavigationStack {
            Form {
                // Keywords section
                Section {
                    TextField("Enter keywords", text: $keywords)
                } header: {
                    Text("Keywords")
                } footer: {
                    Text("Search for messages containing these words")
                }
                
                // Date range section
                Section {
                    Toggle("Use date range", isOn: $useDateRange)
                    
                    if useDateRange {
                        DatePicker(
                            "From",
                            selection: Binding(
                                get: { dateRangeStart ?? Date().addingTimeInterval(-30 * 24 * 60 * 60) }, // Default: 30 days ago
                                set: { dateRangeStart = $0 }
                            ),
                            displayedComponents: [.date]
                        )
                        
                        DatePicker(
                            "To",
                            selection: Binding(
                                get: { dateRangeEnd ?? Date() },
                                set: { dateRangeEnd = $0 }
                            ),
                            displayedComponents: [.date]
                        )
                    }
                } header: {
                    Text("Date Range")
                } footer: {
                    if useDateRange {
                        Text("Search messages within this date range")
                    }
                }
                
                // Sender filter section
                Section {
                    Button {
                        showSenderPicker = true
                    } label: {
                        HStack {
                            Text("Select Senders")
                            Spacer()
                            if !selectedSenders.isEmpty {
                                Text("\(selectedSenders.count) selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    
                    if !selectedSenders.isEmpty {
                        ForEach(Array(selectedSenders), id: \.self) { senderId in
                            if let partner = chatPartners.first(where: { $0.id == senderId }) {
                                HStack {
                                    Text(partner.displayName)
                                    Spacer()
                                    Button {
                                        selectedSenders.remove(senderId)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.gray)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Filter by Sender")
                } footer: {
                    Text("Only show messages from specific people")
                }
                
                // Natural language query section
                Section {
                    TextField("e.g., When did I talk about dinner with Dennis?", text: $naturalLanguageQuery, axis: .vertical)
                        .lineLimit(2...4)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text("AI will rank results by relevance. Can search all messages with just this query.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Natural Language Query")
                }
                
                // Search button
                Section {
                    Button {
                        // Clear date range if toggle is off
                        if !useDateRange {
                            dateRangeStart = nil
                            dateRangeEnd = nil
                        }
                        
                        onSearch()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Search")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(keywords.isEmpty && selectedSenders.isEmpty && !useDateRange && naturalLanguageQuery.isEmpty)
                } footer: {
                    if keywords.isEmpty && selectedSenders.isEmpty && !useDateRange && !naturalLanguageQuery.isEmpty {
                        Text("Searching all messages with AI query only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Advanced Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showSenderPicker) {
                SenderPickerView(
                    chatPartners: chatPartners,
                    selectedSenders: $selectedSenders
                )
            }
            .task {
                await loadChatPartners()
            }
        }
    }
    
    private func loadChatPartners() async {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        
        isLoadingPartners = true
        defer { isLoadingPartners = false }
        
        do {
            chatPartners = try await firestoreService.getAllChatPartners(userId: userId)
            print("📇 Loaded \(chatPartners.count) chat partners")
        } catch {
            print("❌ Failed to load chat partners: \(error)")
        }
    }
}

// MARK: - Sender Picker View

private struct SenderPickerView: View {
    @Environment(\.dismiss) private var dismiss
    
    let chatPartners: [(id: String, displayName: String)]
    @Binding var selectedSenders: Set<String>
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(chatPartners, id: \.id) { partner in
                    Button {
                        if selectedSenders.contains(partner.id) {
                            selectedSenders.remove(partner.id)
                        } else {
                            selectedSenders.insert(partner.id)
                        }
                    } label: {
                        HStack {
                            Text(partner.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedSenders.contains(partner.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Senders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    AdvancedSearchView(
        keywords: .constant(""),
        selectedSenders: .constant([]),
        dateRangeStart: .constant(nil),
        dateRangeEnd: .constant(nil),
        naturalLanguageQuery: .constant(""),
        onSearch: {}
    )
}

