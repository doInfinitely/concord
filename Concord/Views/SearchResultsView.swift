//
//  SearchResultsView.swift
//  Concord
//
//  Dedicated view for displaying search results with context snippets
//

import SwiftUI

struct SearchResultsView: View {
    @Environment(\.dismiss) private var dismiss
    
    let results: [SearchResult]
    let keywords: String?
    let onResultTap: (SearchResult) -> Void
    let onRefresh: () async -> Void
    
    @State private var isRefreshing = false
    
    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
            }
            .navigationTitle("Search Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .refreshable {
                isRefreshing = true
                await onRefresh()
                isRefreshing = false
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 60))
                .foregroundStyle(.gray)
            
            Text("No Results Found")
                .font(.headline)
            
            Text("Try adjusting your search filters or keywords")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(results) { result in
                    SearchResultRow(result: result, keywords: keywords)
                        .onTapGesture {
                            onResultTap(result)
                            dismiss()
                        }
                }
            }
            .padding()
        }
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let result: SearchResult
    let keywords: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Metadata header
            HStack {
                // Sender name
                Text(result.senderDisplayName ?? "Unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                // Conversation name
                Text(result.conversationName ?? "Direct Message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                // Relevance score if available
                if let score = result.relevanceScore {
                    Text("\(Int(score * 100))% match")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            
            // Message text with context
            VStack(alignment: .leading, spacing: 4) {
                if let prevMsg = result.previousMessage {
                    HStack(spacing: 4) {
                        Text("...")
                            .foregroundStyle(.gray)
                        Text(prevMsg.text)
                            .lineLimit(1)
                            .foregroundStyle(.gray)
                            .font(.subheadline)
                    }
                }
                
                // Main message with highlighted keywords
                highlightedMessageText
                    .font(.body)
                    .lineLimit(3)
                
                if let nextMsg = result.nextMessage {
                    HStack(spacing: 4) {
                        Text(nextMsg.text)
                            .lineLimit(1)
                            .foregroundStyle(.gray)
                            .font(.subheadline)
                        Text("...")
                            .foregroundStyle(.gray)
                    }
                }
            }
            
            // Timestamp
            if let createdAt = result.message.createdAt {
                Text(formatDate(createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var highlightedMessageText: Text {
        let messageText = result.message.text
        
        guard let keywords = keywords, !keywords.isEmpty else {
            return Text(messageText)
        }
        
        // Simple highlighting: find keyword occurrences (case-insensitive)
        let lowercasedText = messageText.lowercased()
        let lowercasedKeyword = keywords.lowercased()
        
        var attributedText = Text("")
        var currentIndex = messageText.startIndex
        
        while currentIndex < messageText.endIndex {
            // Find next occurrence of keyword
            let remainingText = String(messageText[currentIndex...])
            let remainingLowercase = String(lowercasedText[currentIndex...])
            
            if let range = remainingLowercase.range(of: lowercasedKeyword) {
                // Add text before keyword
                let beforeKeywordEnd = messageText.index(currentIndex, offsetBy: remainingText.distance(from: remainingText.startIndex, to: range.lowerBound))
                if currentIndex < beforeKeywordEnd {
                    attributedText = attributedText + Text(String(messageText[currentIndex..<beforeKeywordEnd]))
                }
                
                // Add highlighted keyword (bold and colored to stand out)
                let keywordStart = messageText.index(currentIndex, offsetBy: remainingText.distance(from: remainingText.startIndex, to: range.lowerBound))
                let keywordEnd = messageText.index(keywordStart, offsetBy: keywords.count)
                attributedText = attributedText + Text(String(messageText[keywordStart..<keywordEnd]))
                    .bold()
                    .foregroundStyle(.blue)
                
                currentIndex = keywordEnd
            } else {
                // No more keywords, add remaining text
                attributedText = attributedText + Text(String(messageText[currentIndex...]))
                break
            }
        }
        
        return attributedText
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
            return "Today at \(formatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            formatter.timeStyle = .short
            return "Yesterday at \(formatter.string(from: date))"
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }
}

#Preview {
    SearchResultsView(
        results: [],
        keywords: "test",
        onResultTap: { _ in },
        onRefresh: { }
    )
}

