//
//  AIService.swift
//  Concord
//
//  AI service for calling Cloud Functions
//

import Foundation
import FirebaseFunctions

enum AIAction: String {
    case summarizeThread = "summarize_thread"
    case extractActions = "extract_actions"
    case checkPriority = "check_priority"
    case summarizeDecision = "summarize_decision"
    case extractEvent = "extract_event"
    case trackRSVPs = "track_rsvps"
    case extractMeetingSubject = "extract_meeting_subject"
}

class AIService {
    private let functions = Functions.functions()
    
    /// Call the AI service Cloud Function
    func performAIAction(
        conversationId: String,
        threadId: String?,
        action: AIAction,
        userId: String,
        messageText: String? = nil
    ) async throws -> (response: String, messageId: String) {
        let callable = functions.httpsCallable("aiService")
        
        var data: [String: Any] = [
            "conversationId": conversationId,
            "threadId": threadId as Any,
            "action": action.rawValue,
            "userId": userId
        ]
        
        if let messageText = messageText {
            data["messageText"] = messageText
        }
        
        do {
            let result = try await callable.call(data)
            
            print("🤖 AI Service raw response: \(result.data)")
            
            guard let resultData = result.data as? [String: Any],
                  let success = resultData["success"] as? Bool,
                  success,
                  let response = resultData["response"] as? String else {
                
                // Check if there's an error message in the response
                if let resultData = result.data as? [String: Any],
                   let errorMsg = resultData["error"] as? String {
                    print("❌ AI Service returned error: \(errorMsg)")
                    throw NSError(
                        domain: "AIService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: errorMsg]
                    )
                }
                
                throw NSError(
                    domain: "AIService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response from AI service: \(result.data)"]
                )
            }
            
            // messageId is optional (null for calendar events)
            let messageId = resultData["messageId"] as? String ?? ""
            
            return (response, messageId)
        } catch let error as NSError {
            print("❌ AI Service error: \(error)")
            print("❌ Error domain: \(error.domain), code: \(error.code)")
            print("❌ Error userInfo: \(error.userInfo)")
            throw error
        }
    }
}

