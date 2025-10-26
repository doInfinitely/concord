//
//  Models.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import Foundation
import FirebaseFirestore


struct Conversation: Identifiable, Hashable {
    let id: String
    var members: [String]
    var memberCount: Int
    var name: String?
    var lastMessageText: String?
    var lastMessageAt: Date?

    // Use automatic Hashable/Equatable synthesis
    // This compares all fields, not just id, so SwiftUI detects changes properly
}

struct Message: Identifiable {
    let id: String
    let senderId: String
    let text: String
    let createdAt: Date?
    let status: String?
    let threadId: String?       // ID of the thread this message belongs to (nil if not a reply)
    let parentMessageId: String? // ID of the message being replied to (nil if not a reply)
    var replyCount: Int          // Number of replies to this message
    let isAI: Bool               // True if this is an AI-generated message
    let visibleTo: [String]?     // User IDs who can see this AI message (nil = visible to all)
    let aiAction: String?        // Type of AI action (summarize_thread, extract_actions, etc.)
    
    // RSVP tracking for calendar events
    let rsvpData: [String: String]? // userId -> "yes"/"no"/"maybe"
    let eventTitle: String?      // Title of associated calendar event
    let eventDate: Date?         // Date/time of associated event
    
    var rsvpCount: Int {
        return rsvpData?.count ?? 0
    }
}

enum FS {
    static func date(from value: Any?) -> Date? {
        switch value {
        case let ts as Timestamp: return ts.dateValue()
        case let d as Date:       return d
        case let s as String:     return ISO8601DateFormatter().date(from: s)
        case let t as TimeInterval: return Date(timeIntervalSince1970: t)
        default: return nil
        }
    }

    static func string(_ dict: [String:Any], _ key: String) -> String? {
        dict[key] as? String
    }

    static func array<T>(_ dict: [String:Any], _ key: String) -> [T] {
        dict[key] as? [T] ?? []
    }

    static func int(_ dict: [String:Any], _ key: String) -> Int {
        dict[key] as? Int ?? 0
    }
}

// MARK: - Search Models

struct SearchResult: Identifiable {
    let id: String
    let message: Message
    let conversationId: String
    let conversationName: String?
    let senderDisplayName: String?
    var relevanceScore: Double? // Set by AI if NL query used
    
    // Context messages for snippet display
    let previousMessage: Message?
    let nextMessage: Message?
}

struct SearchFilters {
    var keywords: String
    var senderIds: [String]
    var dateRange: (Date, Date)?
}

// MARK: - RSVP Models

enum RSVPStatus: String, CaseIterable {
    case yes = "yes"
    case no = "no"
    case maybe = "maybe"
    
    var displayText: String {
        switch self {
        case .yes: return "Yes"
        case .no: return "No"
        case .maybe: return "Maybe"
        }
    }
}

struct RSVPResponse: Identifiable {
    let id: String // userId
    let userId: String
    let displayName: String
    let status: RSVPStatus
}
