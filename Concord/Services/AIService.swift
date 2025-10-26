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
    case intelligentSearch = "intelligent_search"
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
    
    /// Rank search results using AI based on a natural language query
    func intelligentSearch(
        results: [SearchResult],
        naturalLanguageQuery: String
    ) async throws -> [SearchResult] {
        print("🤖 Running intelligent search with query: \(naturalLanguageQuery)")
        print("   Input results: \(results.count)")
        
        let callable = functions.httpsCallable("intelligentSearch")
        
        // Prepare messages data for the AI
        let messagesData = results.map { result in
            return [
                "id": result.id,
                "text": result.message.text,
                "senderId": result.message.senderId,
                "senderName": result.senderDisplayName ?? "Unknown",
                "conversationName": result.conversationName ?? "Direct Message",
                "createdAt": (result.message.createdAt ?? Date()).timeIntervalSince1970
            ] as [String: Any]
        }
        
        let data: [String: Any] = [
            "messages": messagesData,
            "query": naturalLanguageQuery
        ]
        
        do {
            let result = try await callable.call(data)
            
            guard let resultData = result.data as? [String: Any],
                  let success = resultData["success"] as? Bool,
                  success,
                  let rankings = resultData["rankings"] as? [[String: Any]] else {
                
                if let resultData = result.data as? [String: Any],
                   let errorMsg = resultData["error"] as? String {
                    print("❌ Intelligent search error: \(errorMsg)")
                    throw NSError(
                        domain: "AIService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: errorMsg]
                    )
                }
                
                throw NSError(
                    domain: "AIService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response from intelligent search"]
                )
            }
            
            // Create a map of message ID to relevance score
            var scoreMap: [String: Double] = [:]
            for ranking in rankings {
                if let messageId = ranking["messageId"] as? String,
                   let score = ranking["score"] as? Double {
                    scoreMap[messageId] = score
                }
            }
            
            // Update results with relevance scores and sort by score
            var rankedResults = results.map { result in
                var updatedResult = result
                updatedResult.relevanceScore = scoreMap[result.id]
                return updatedResult
            }
            
            // Sort by relevance score (highest first)
            rankedResults.sort { (a, b) in
                let scoreA = a.relevanceScore ?? 0
                let scoreB = b.relevanceScore ?? 0
                return scoreA > scoreB
            }
            
            print("🤖 Intelligent search complete. Results ranked by relevance.")
            return rankedResults
        } catch let error as NSError {
            print("❌ Intelligent search error: \(error)")
            throw error
        }
    }
}

