//
//  CalendarService.swift
//  Concord
//
//  Calendar integration service for Apple Calendar (EventKit) and Google Calendar
//

import Foundation
import Combine
import EventKit
import FirebaseAuth
import FirebaseFirestore

// MARK: - Calendar Models

struct CalendarInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let type: CalendarType
    let color: String?
    
    enum CalendarType: String {
        case apple
        case google
    }
}

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let calendar: CalendarInfo
}

struct ExtractedEventData {
    var title: String
    var date: Date?
    var duration: TimeInterval // in seconds
    var location: String?
    var attendees: [String]
    var notes: String?
    
    init(title: String = "", date: Date? = nil, duration: TimeInterval = 3600, location: String? = nil, attendees: [String] = [], notes: String? = nil) {
        self.title = title
        self.date = date
        self.duration = duration
        self.location = location
        self.attendees = attendees
        self.notes = notes
    }
}

// MARK: - Calendar Service

@MainActor
class CalendarService: ObservableObject {
    private let eventStore = EKEventStore()
    private let db = Firestore.firestore()
    
    @Published var isAppleCalendarConnected = false
    @Published var isGoogleCalendarConnected = false
    @Published var availableCalendars: [CalendarInfo] = []
    
    // MARK: - Apple Calendar (EventKit)
    
    /// Request access to Apple Calendar
    func requestAppleCalendarAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        
        switch status {
        case .authorized, .fullAccess:
            await MainActor.run {
                isAppleCalendarConnected = true
            }
            try await saveCalendarStatus(apple: true, google: nil)
            return true
            
        case .notDetermined, .restricted:
            let granted = try await eventStore.requestFullAccessToEvents()
            await MainActor.run {
                isAppleCalendarConnected = granted
            }
            if granted {
                try await saveCalendarStatus(apple: true, google: nil)
            }
            return granted
            
        case .denied, .writeOnly:
            return false
            
        @unknown default:
            return false
        }
    }
    
    /// Get list of Apple calendars
    func getAppleCalendars() -> [CalendarInfo] {
        guard isAppleCalendarConnected else { return [] }
        
        let calendars = eventStore.calendars(for: .event)
        return calendars.map { calendar in
            CalendarInfo(
                id: "apple_\(calendar.calendarIdentifier)",
                title: calendar.title,
                type: .apple,
                color: calendar.cgColor.map { "#\(String(format: "%02X%02X%02X", Int($0.components?[0] ?? 0 * 255), Int($0.components?[1] ?? 0 * 255), Int($0.components?[2] ?? 0 * 255)))" }
            )
        }
    }
    
    /// Check for scheduling conflicts in a specific calendar
    func checkConflicts(date: Date, duration: TimeInterval, calendarId: String) async throws -> [CalendarEvent] {
        guard calendarId.hasPrefix("apple_") else {
            // Google Calendar conflict checking would go here
            return []
        }
        
        let ekCalendarId = String(calendarId.dropFirst(6)) // Remove "apple_" prefix
        guard let calendar = eventStore.calendar(withIdentifier: ekCalendarId) else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Calendar not found"])
        }
        
        let endDate = date.addingTimeInterval(duration)
        let predicate = eventStore.predicateForEvents(withStart: date, end: endDate, calendars: [calendar])
        let events = eventStore.events(matching: predicate)
        
        return events.map { event in
            CalendarEvent(
                id: event.eventIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                location: event.location,
                notes: event.notes,
                calendar: CalendarInfo(
                    id: calendarId,
                    title: calendar.title,
                    type: .apple,
                    color: nil
                )
            )
        }
    }
    
    /// Create event in Apple Calendar
    func createAppleCalendarEvent(
        calendarId: String,
        title: String,
        startDate: Date,
        duration: TimeInterval,
        location: String?,
        notes: String?,
        attendees: [String]
    ) async throws -> String {
        let ekCalendarId = String(calendarId.dropFirst(6)) // Remove "apple_" prefix
        guard let calendar = eventStore.calendar(withIdentifier: ekCalendarId) else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Calendar not found"])
        }
        
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(duration)
        event.calendar = calendar
        event.location = location
        event.notes = notes
        
        // Add attendees (EventKit uses EKParticipant, which requires email addresses)
        // For now, we'll add them to notes if they're not email addresses
        if !attendees.isEmpty {
            let attendeeText = "\n\nAttendees: " + attendees.joined(separator: ", ")
            event.notes = (notes ?? "") + attendeeText
        }
        
        try eventStore.save(event, span: .thisEvent)
        
        print("✅ Created Apple Calendar event: \(title)")
        return event.eventIdentifier
    }
    
    /// Disconnect Apple Calendar
    func disconnectAppleCalendar() async throws {
        await MainActor.run {
            isAppleCalendarConnected = false
        }
        try await saveCalendarStatus(apple: false, google: nil)
    }
    
    // MARK: - Google Calendar
    
    /// Check if Google Calendar is connected
    func checkGoogleCalendarStatus() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
        do {
            let doc = try await db.collection("users").document(uid).getDocument()
            let isConnected = doc.data()?["googleCalendarConnected"] as? Bool ?? false
            
            await MainActor.run {
                isGoogleCalendarConnected = isConnected
            }
        } catch {
            print("❌ Error checking Google Calendar status: \(error)")
        }
    }
    
    /// Initiate Google Calendar OAuth (placeholder - requires GoogleSignIn SDK)
    func connectGoogleCalendar() async throws {
        // This would use GoogleSignIn SDK with calendar scope
        // For now, just mark as connected for UI purposes
        print("🔵 Google Calendar OAuth would start here")
        
        // TODO: Implement actual Google OAuth flow
        // 1. Configure GoogleSignIn with calendar scopes
        // 2. Present sign-in UI
        // 3. Exchange authorization code for tokens
        // 4. Store refresh token in Firestore (encrypted)
        
        // Placeholder:
        await MainActor.run {
            isGoogleCalendarConnected = true
        }
        try await saveCalendarStatus(apple: nil, google: true)
    }
    
    /// Disconnect Google Calendar
    func disconnectGoogleCalendar() async throws {
        await MainActor.run {
            isGoogleCalendarConnected = false
        }
        try await saveCalendarStatus(apple: nil, google: false)
        
        // Also clear stored tokens
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try await db.collection("users").document(uid).updateData([
            "googleCalendarRefreshToken": FieldValue.delete()
        ])
    }
    
    // MARK: - Helper Methods
    
    /// Load calendar connection status from Firestore
    func loadCalendarStatus() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
        do {
            let doc = try await db.collection("users").document(uid).getDocument()
            let data = doc.data() ?? [:]
            
            let appleConnected = data["appleCalendarConnected"] as? Bool ?? false
            let googleConnected = data["googleCalendarConnected"] as? Bool ?? false
            
            await MainActor.run {
                isAppleCalendarConnected = appleConnected
                isGoogleCalendarConnected = googleConnected
            }
            
            // Verify Apple Calendar access is still valid
            if appleConnected {
                let status = EKEventStore.authorizationStatus(for: .event)
                if status != .authorized && status != .fullAccess {
                    await MainActor.run {
                        isAppleCalendarConnected = false
                    }
                    try await saveCalendarStatus(apple: false, google: nil)
                }
            }
            
            // Load available calendars if connected
            if isAppleCalendarConnected {
                await MainActor.run {
                    availableCalendars = getAppleCalendars()
                }
            }
            
        } catch {
            print("❌ Error loading calendar status: \(error)")
        }
    }
    
    /// Save calendar connection status to Firestore
    private func saveCalendarStatus(apple: Bool?, google: Bool?) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
        var updates: [String: Any] = [:]
        if let apple = apple {
            updates["appleCalendarConnected"] = apple
        }
        if let google = google {
            updates["googleCalendarConnected"] = google
        }
        
        if !updates.isEmpty {
            try await db.collection("users").document(uid).setData(updates, merge: true)
        }
    }
    
    /// Parse AI-extracted event data from JSON string
    func parseEventData(from jsonString: String) -> ExtractedEventData {
        // Strip markdown code fences if present
        var cleanedJson = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedJson.hasPrefix("```json") {
            cleanedJson = cleanedJson.replacingOccurrences(of: "```json", with: "")
        }
        if cleanedJson.hasPrefix("```") {
            cleanedJson = cleanedJson.replacingOccurrences(of: "```", with: "", options: [], range: cleanedJson.startIndex..<cleanedJson.index(cleanedJson.startIndex, offsetBy: 3))
        }
        if cleanedJson.hasSuffix("```") {
            let endIndex = cleanedJson.index(cleanedJson.endIndex, offsetBy: -3)
            cleanedJson = String(cleanedJson[..<endIndex])
        }
        cleanedJson = cleanedJson.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let data = cleanedJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ Failed to parse JSON: \(cleanedJson)")
            return ExtractedEventData()
        }
        
        print("📅 Successfully parsed JSON: \(json)")
        
        var eventData = ExtractedEventData()
        eventData.title = json["title"] as? String ?? ""
        eventData.location = json["location"] as? String
        eventData.notes = json["notes"] as? String
        
        // Parse date
        if let dateString = json["date"] as? String {
            // Try ISO8601 with timezone first
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: dateString) {
                eventData.date = date
                print("📅 Parsed date (with timezone): \(dateString) -> \(eventData.date?.description ?? "nil")")
            } else {
                // If that fails, try without timezone (treat as local time)
                let localFormatter = DateFormatter()
                localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                localFormatter.timeZone = TimeZone.current
                if let localDate = localFormatter.date(from: dateString) {
                    eventData.date = localDate
                    print("📅 Parsed date (local time): \(dateString) -> \(eventData.date?.description ?? "nil")")
                } else {
                    print("❌ Failed to parse date: \(dateString)")
                }
            }
        }
        
        // Parse duration (default to 1 hour)
        if let durationMinutes = json["durationMinutes"] as? Int {
            eventData.duration = TimeInterval(durationMinutes * 60)
            print("📅 Parsed duration: \(durationMinutes) minutes")
        } else {
            eventData.duration = 3600 // 1 hour default
            print("📅 Using default duration: 1 hour")
        }
        
        // Parse attendees
        if let attendees = json["attendees"] as? [String] {
            eventData.attendees = attendees
            print("📅 Parsed attendees: \(attendees)")
        }
        
        print("📅 Final parsed event: title=\(eventData.title), date=\(eventData.date?.description ?? "nil"), duration=\(eventData.duration)s")
        
        return eventData
    }
}

