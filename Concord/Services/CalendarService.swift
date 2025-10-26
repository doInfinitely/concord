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
import FirebaseCore
import GoogleSignIn
import GoogleSignInSwift
import UIKit

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
                color: nil // Could extract color from calendar.cgColor if needed
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
    
    /// Check for conflicts across ALL connected calendars
    func checkConflictsAcrossAllCalendars(date: Date, duration: TimeInterval) async throws -> [CalendarEvent] {
        var allConflicts: [CalendarEvent] = []
        
        print("📅 Conflict Check: isAppleConnected=\(isAppleCalendarConnected), date=\(date), duration=\(duration)s")
        
        // Check Apple Calendars
        if isAppleCalendarConnected {
            let calendars = eventStore.calendars(for: .event)
            print("📅 Conflict Check: Found \(calendars.count) Apple calendars to check")
            
            let endDate = date.addingTimeInterval(duration)
            let predicate = eventStore.predicateForEvents(
                withStart: date,
                end: endDate,
                calendars: calendars
            )
            
            let events = eventStore.events(matching: predicate)
            print("📅 Conflict Check: Found \(events.count) events in time range")
            
            for event in events {
                print("📅   - Event: '\(event.title)' at \(event.startDate)")
            }
            
            let conflicts = events.map { event in
                CalendarEvent(
                    id: event.eventIdentifier,
                    title: event.title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    location: event.location,
                    notes: event.notes,
                    calendar: CalendarInfo(
                        id: "apple_\(event.calendar.calendarIdentifier)",
                        title: event.calendar.title,
                        type: .apple,
                        color: nil
                    )
                )
            }
            allConflicts.append(contentsOf: conflicts)
        } else {
            print("📅 Conflict Check: Apple Calendar not connected, skipping")
        }
        
        // Check Google Calendars
        if isGoogleCalendarConnected {
            print("📅 Conflict Check: Checking Google Calendar...")
            
            guard let accessToken = GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString else {
                print("📅 Conflict Check: No Google access token, skipping")
                return allConflicts
            }
            
            // Fetch events from all Google calendars
            let googleCalendars = availableCalendars.filter { $0.type == .google }
            print("📅 Conflict Check: Found \(googleCalendars.count) Google calendars to check")
            
            for calendar in googleCalendars {
                let calendarId = String(calendar.id.dropFirst(7)) // Remove "google_" prefix
                
                do {
                    let events = try await fetchGoogleCalendarEvents(
                        calendarId: calendarId,
                        accessToken: accessToken,
                        startDate: date,
                        endDate: date.addingTimeInterval(duration)
                    )
                    
                    print("📅 Conflict Check: Calendar '\(calendar.title)' has \(events.count) events in range")
                    
                    for event in events {
                        print("📅   - Event: '\(event.title)' at \(event.startDate)")
                    }
                    
                    allConflicts.append(contentsOf: events)
                } catch {
                    print("❌ Failed to fetch Google Calendar events for \(calendar.title): \(error)")
                }
            }
        } else {
            print("📅 Conflict Check: Google Calendar not connected, skipping")
        }
        
        print("📅 Conflict Check: Total conflicts found: \(allConflicts.count)")
        return allConflicts
    }
    
    /// Find available time slots on a given day
    func findAvailableSlots(
        on date: Date,
        duration: TimeInterval = 3600, // 1 hour default
        workingHoursStart: Int = 9,    // 9 AM
        workingHoursEnd: Int = 17,     // 5 PM
        slotCount: Int = 3             // Return up to 3 suggestions
    ) async throws -> [Date] {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        
        // Get start of the day
        let startOfDay = calendar.startOfDay(for: date)
        
        // Define working hours range
        guard let workStart = calendar.date(bySettingHour: workingHoursStart, minute: 0, second: 0, of: startOfDay),
              let workEnd = calendar.date(bySettingHour: workingHoursEnd, minute: 0, second: 0, of: startOfDay) else {
            return []
        }
        
        // Get all events for the day
        let allEvents = try await checkConflictsAcrossAllCalendars(
            date: workStart,
            duration: workEnd.timeIntervalSince(workStart)
        )
        
        // Sort events by start time
        let sortedEvents = allEvents.sorted { $0.startDate < $1.startDate }
        
        print("📅 Finding available slots: \(sortedEvents.count) events on this day")
        for event in sortedEvents {
            print("📅   Busy: \(event.startDate) - \(event.endDate) (\(event.title))")
        }
        
        var availableSlots: [Date] = []
        var currentTime = workStart
        
        // Check each 30-minute slot
        let slotIncrement: TimeInterval = 1800 // 30 minutes
        
        while currentTime < workEnd && availableSlots.count < slotCount {
            let slotEnd = currentTime.addingTimeInterval(duration)
            
            // Check if this slot conflicts with any existing event
            let hasConflict = sortedEvents.contains { event in
                // Check if the proposed slot overlaps with this event
                return (currentTime < event.endDate && slotEnd > event.startDate)
            }
            
            if !hasConflict && slotEnd <= workEnd {
                availableSlots.append(currentTime)
                print("📅   ✅ Free slot found: \(currentTime)")
            }
            
            currentTime = currentTime.addingTimeInterval(slotIncrement)
        }
        
        print("📅 Total free slots found: \(availableSlots.count)")
        
        return availableSlots
    }
    
    /// Detect if a message contains a meeting proposal with time
    func detectMeetingProposal(in text: String) -> (hasProposal: Bool, dateTime: Date?, duration: TimeInterval) {
        let lowercased = text.lowercased()
        
        // Simple pattern matching for common meeting phrases
        let meetingKeywords = ["meet", "meeting", "call", "lunch", "dinner", "coffee"]
        let hasMeetingKeyword = meetingKeywords.contains { lowercased.contains($0) }
        
        if !hasMeetingKeyword {
            return (false, nil, 3600)
        }
        
        // Try to extract time using simple patterns
        // This is a basic implementation - a full solution would use NLP
        var detectedDate: Date?
        
        // Pattern: "at 3pm", "at 3:30pm", "at 15:00"
        let timePatterns = [
            #"at (\d{1,2}):?(\d{2})?\s*(am|pm)?"#,
            #"(\d{1,2}):(\d{2})\s*(am|pm)?"#
        ]
        
        for pattern in timePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                
                let hourRange = match.range(at: 1)
                if let hourString = Range(hourRange, in: text).map({ String(text[$0]) }),
                   var hour = Int(hourString) {
                    
                    var minute = 0
                    let minuteRange = match.range(at: 2)
                    if minuteRange.location != NSNotFound,
                       let minuteString = Range(minuteRange, in: text).map({ String(text[$0]) }) {
                        minute = Int(minuteString) ?? 0
                    }
                    
                    let ampmRange = match.range(at: 3)
                    if ampmRange.location != NSNotFound,
                       let ampm = Range(ampmRange, in: text).map({ String(text[$0]) }) {
                        if ampm.lowercased() == "pm" && hour < 12 {
                            hour += 12
                        } else if ampm.lowercased() == "am" && hour == 12 {
                            hour = 0
                        }
                    }
                    
                    // Create date for today at the extracted time in LOCAL timezone
                    let calendar = Calendar.current
                    let now = Date()
                    
                    // Get components for today in local time
                    var components = calendar.dateComponents([.year, .month, .day], from: now)
                    components.hour = hour
                    components.minute = minute
                    components.second = 0
                    components.timeZone = TimeZone.current
                    
                    if let proposedDate = calendar.date(from: components) {
                        print("📅 Detection: Extracted time: \(hour):\(minute) -> \(proposedDate)")
                        // If the time has already passed today, assume tomorrow
                        if proposedDate < now {
                            detectedDate = calendar.date(byAdding: .day, value: 1, to: proposedDate)
                            print("📅 Detection: Time passed, using tomorrow: \(detectedDate?.description ?? "nil")")
                        } else {
                            detectedDate = proposedDate
                        }
                        break
                    }
                }
            }
        }
        
        return (detectedDate != nil, detectedDate, 3600) // Default 1 hour duration
    }
    
    /// Check for conflicts and suggest alternatives
    func checkConflictsAndSuggestAlternatives(
        proposedDate: Date,
        duration: TimeInterval
    ) async throws -> (hasConflict: Bool, conflicts: [CalendarEvent], suggestions: [Date]) {
        // Check for conflicts across all calendars
        let conflicts = try await checkConflictsAcrossAllCalendars(
            date: proposedDate,
            duration: duration
        )
        
        if conflicts.isEmpty {
            return (false, [], [])
        }
        
        // Find alternative time slots on the same day
        let suggestions = try await findAvailableSlots(
            on: proposedDate,
            duration: duration,
            workingHoursStart: 9,
            workingHoursEnd: 17,
            slotCount: 3
        )
        
        return (true, conflicts, suggestions)
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
    
    /// Initiate Google Calendar OAuth
    func connectGoogleCalendar() async throws {
        print("🔵 Starting Google Calendar OAuth flow")
        
        // Get the client ID from GoogleService-Info.plist
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No client ID found"])
        }
        
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config
        
        // Request calendar scope
        let calendarScope = "https://www.googleapis.com/auth/calendar"
        
        // Get the root view controller
        guard let windowScene = await UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = await windowScene.windows.first?.rootViewController else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No root view controller"])
        }
        
        // Sign in with calendar scope
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: rootViewController,
            hint: nil,
            additionalScopes: [calendarScope]
        )
        
        let accessToken = result.user.accessToken.tokenString
        
        print("✅ Google Calendar OAuth successful")
        
        // Store the refresh token in Firestore (for server-side access)
        let refreshToken = result.user.refreshToken.tokenString
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Firebase user"])
        }
        
        try await db.collection("users").document(uid).setData([
            "googleCalendarRefreshToken": refreshToken,
            "googleCalendarConnected": true
        ], merge: true)
        
        // Fetch calendars
        let calendars = try await fetchGoogleCalendars(accessToken: accessToken)
        
        await MainActor.run {
            isGoogleCalendarConnected = true
            
            // Filter and add Google calendars to availableCalendars
            // Only include writable calendars (not read-only like Holidays)
            let writableCalendars = calendars.filter { calendar in
                let accessRole = calendar.accessRole ?? ""
                return accessRole == "owner" || accessRole == "writer"
            }
            
            // Sort so primary calendar comes first
            let sortedCalendars = writableCalendars.sorted { lhs, rhs in
                if lhs.primary == true { return true }
                if rhs.primary == true { return false }
                return lhs.summary < rhs.summary
            }
            
            let googleCalendarInfos = sortedCalendars.map { calendar in
                CalendarInfo(
                    id: "google_\(calendar.id)",
                    title: calendar.summary,
                    type: .google,
                    color: nil
                )
            }
            
            // Remove old Google calendars and add new ones
            availableCalendars.removeAll { $0.type == .google }
            availableCalendars.append(contentsOf: googleCalendarInfos)
            
            print("✅ Loaded \(googleCalendarInfos.count) writable Google calendars (filtered from \(calendars.count) total)")
        }
        
        try await saveCalendarStatus(apple: nil, google: true)
    }
    
    /// Fetch Google Calendar events in a time range
    private func fetchGoogleCalendarEvents(
        calendarId: String,
        accessToken: String,
        startDate: Date,
        endDate: Date
    ) async throws -> [CalendarEvent] {
        // Format dates for Google Calendar API (RFC3339)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        let timeMin = formatter.string(from: startDate)
        let timeMax = formatter.string(from: endDate)
        
        // Build URL with query parameters
        let urlString = "https://www.googleapis.com/calendar/v3/calendars/\(calendarId)/events?timeMin=\(timeMin)&timeMax=\(timeMax)&singleEvents=true&orderBy=startTime"
        guard let encodedUrlString = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encodedUrlString) else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if httpResponse.statusCode != 200 {
            if let errorString = String(data: data, encoding: .utf8) {
                print("❌ Google Calendar API error: \(errorString)")
            }
            throw NSError(domain: "CalendarService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch events"])
        }
        
        let decoder = JSONDecoder()
        let eventsResponse = try decoder.decode(GoogleCalendarEventsResponse.self, from: data)
        
        // Convert to CalendarEvent objects
        let dateParser = ISO8601DateFormatter()
        return eventsResponse.items.compactMap { item in
            guard let startString = item.start.dateTime ?? item.start.date,
                  let startDate = dateParser.date(from: startString) else {
                return nil
            }
            
            let endString = item.end.dateTime ?? item.end.date
            let endDate = endString.flatMap { dateParser.date(from: $0) } ?? startDate.addingTimeInterval(3600)
            
            return CalendarEvent(
                id: item.id,
                title: item.summary ?? "(No title)",
                startDate: startDate,
                endDate: endDate,
                location: item.location,
                notes: item.description,
                calendar: CalendarInfo(
                    id: "google_\(calendarId)",
                    title: "", // We don't have the calendar title here
                    type: .google,
                    color: nil
                )
            )
        }
    }
    
    /// Fetch Google Calendar list
    private func fetchGoogleCalendars(accessToken: String) async throws -> [GoogleCalendarListItem] {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        print("🔵 Fetching Google calendars with token: \(accessToken.prefix(20))...")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        print("🔵 Google Calendar API response status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode != 200 {
            if let errorString = String(data: data, encoding: .utf8) {
                print("❌ Google Calendar API error response: \(errorString)")
            }
            throw NSError(domain: "CalendarService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch calendars (status \(httpResponse.statusCode))"])
        }
        
        let decoder = JSONDecoder()
        let calendarList = try decoder.decode(GoogleCalendarListResponse.self, from: data)
        
        print("✅ Successfully fetched \(calendarList.items.count) Google calendars")
        
        return calendarList.items
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
    
    /// Create event in Google Calendar
    func createGoogleCalendarEvent(
        calendarId: String,
        title: String,
        startDate: Date,
        duration: TimeInterval,
        location: String?,
        notes: String?,
        attendees: [String]?
    ) async throws -> String {
        let googleCalendarId = String(calendarId.dropFirst(7)) // Remove "google_" prefix
        
        // Get access token
        guard let accessToken = GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Google access token"])
        }
        
        // Format dates for Google Calendar API (ISO8601 with timezone)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        let startDateString = formatter.string(from: startDate)
        let endDate = startDate.addingTimeInterval(duration)
        let endDateString = formatter.string(from: endDate)
        
        // Separate valid emails from names
        let validEmails = attendees?.filter { $0.contains("@") && $0.contains(".") } ?? []
        let nonEmailAttendees = attendees?.filter { !($0.contains("@") && $0.contains(".")) } ?? []
        
        // Add non-email attendees to notes
        var finalNotes = notes ?? ""
        if !nonEmailAttendees.isEmpty {
            let attendeeText = "\n\nAttendees: " + nonEmailAttendees.joined(separator: ", ")
            finalNotes = finalNotes + attendeeText
        }
        
        // Build request
        var eventRequest = GoogleCalendarEventRequest(
            summary: title,
            start: GoogleCalendarEventTime(
                dateTime: startDateString,
                timeZone: TimeZone.current.identifier
            ),
            end: GoogleCalendarEventTime(
                dateTime: endDateString,
                timeZone: TimeZone.current.identifier
            ),
            location: location,
            description: finalNotes.isEmpty ? nil : finalNotes,
            attendees: validEmails.isEmpty ? nil : validEmails.map { GoogleCalendarAttendee(email: $0) }
        )
        
        // Make API request
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(googleCalendarId)/events")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(eventRequest)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let errorString = String(data: data, encoding: .utf8) {
                print("❌ Google Calendar API error: \(errorString)")
            }
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create Google Calendar event"])
        }
        
        let decoder = JSONDecoder()
        let eventResponse = try decoder.decode(GoogleCalendarEventResponse.self, from: data)
        
        print("✅ Created Google Calendar event: \(title)")
        return eventResponse.id
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
            var allCalendars: [CalendarInfo] = []
            
            if isAppleCalendarConnected {
                allCalendars.append(contentsOf: getAppleCalendars())
            }
            
            // Load Google calendars if connected
            if googleConnected {
                do {
                    if GIDSignIn.sharedInstance.hasPreviousSignIn() {
                        try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                        
                        if let accessToken = GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString {
                            let googleCalendars = try await fetchGoogleCalendars(accessToken: accessToken)
                            
                            // Filter for writable calendars only
                            let writableCalendars = googleCalendars.filter { calendar in
                                let accessRole = calendar.accessRole ?? ""
                                return accessRole == "owner" || accessRole == "writer"
                            }
                            
                            // Sort so primary calendar comes first
                            let sortedCalendars = writableCalendars.sorted { lhs, rhs in
                                if lhs.primary == true { return true }
                                if rhs.primary == true { return false }
                                return lhs.summary < rhs.summary
                            }
                            
                            let googleCalendarInfos = sortedCalendars.map { calendar in
                                CalendarInfo(
                                    id: "google_\(calendar.id)",
                                    title: calendar.summary,
                                    type: .google,
                                    color: nil
                                )
                            }
                            allCalendars.append(contentsOf: googleCalendarInfos)
                            print("✅ Loaded \(googleCalendarInfos.count) writable Google calendars (filtered from \(googleCalendars.count) total)")
                        }
                    }
                } catch {
                    print("⚠️ Failed to restore Google Sign-In: \(error)")
                }
            }
            
            await MainActor.run {
                availableCalendars = allCalendars
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

// MARK: - Google Calendar API Models

struct GoogleCalendarListResponse: Codable {
    let items: [GoogleCalendarListItem]
}

struct GoogleCalendarListItem: Codable {
    let id: String
    let summary: String
    let primary: Bool?
    let accessRole: String?
}

struct GoogleCalendarEventRequest: Codable {
    let summary: String
    let start: GoogleCalendarEventTime
    let end: GoogleCalendarEventTime
    let location: String?
    let description: String?
    let attendees: [GoogleCalendarAttendee]?
}

struct GoogleCalendarEventTime: Codable {
    let dateTime: String
    let timeZone: String?
}

struct GoogleCalendarAttendee: Codable {
    let email: String
}

struct GoogleCalendarEventResponse: Codable {
    let id: String
    let htmlLink: String
}

struct GoogleCalendarEventsResponse: Codable {
    let items: [GoogleCalendarEventItem]
}

struct GoogleCalendarEventItem: Codable {
    let id: String
    let summary: String?
    let description: String?
    let location: String?
    let start: GoogleCalendarEventDateTime
    let end: GoogleCalendarEventDateTime
}

struct GoogleCalendarEventDateTime: Codable {
    let dateTime: String?
    let date: String?
    let timeZone: String?
}

