//
//  FirestoreService.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import Foundation
import FirebaseFirestore

final class FirestoreService {
    private let db = Firestore.firestore()

    // Create a new conversation, return its id.
    func createConversation(members: [String], name: String? = nil) async throws -> String {
        let ref = db.collection("conversations").document()

        var data: [String: Any] = [
            "members": members,
            "memberCount": members.count,
            "createdAt": FieldValue.serverTimestamp()
        ]
        if let name { data["name"] = name }

        try await setDataAsync(ref: ref, data: data) // no deletes here
        return ref.documentID
    }

    // Create (or reuse) a self “Saved” conversation.
    func createSelfConversationIfNeeded(uid: String) async throws -> String {
        let q = db.collection("conversations")
            .whereField("members", arrayContains: uid)
            .whereField("memberCount", isEqualTo: 1)
            .limit(to: 1)

        let snap = try await getDocumentsAsync(query: q)
        if let existing = snap.documents.first {
            return existing.documentID
        }
        return try await createConversation(members: [uid], name: "Saved")
    }

    // Get a single message by ID
    func getMessage(conversationId: String, messageId: String) async throws -> Message {
        let doc = try await db.collection("conversations")
            .document(conversationId)
            .collection("messages")
            .document(messageId)
            .getDocument()
        
        guard let data = doc.data() else {
            throw NSError(domain: "FirestoreService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Message not found"])
        }
        
        return Message(
            id: doc.documentID,
            senderId: data["senderId"] as? String ?? "",
            text: data["text"] as? String ?? "",
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue(),
            status: data["status"] as? String,
            threadId: data["threadId"] as? String,
            parentMessageId: data["parentMessageId"] as? String,
            replyCount: data["replyCount"] as? Int ?? 0,
            isAI: data["isAI"] as? Bool ?? false,
            visibleTo: data["visibleTo"] as? [String],
            aiAction: data["aiAction"] as? String
        )
    }
    
    // Send a message and update lastMessage fields atomically.
    func sendMessage(conversationId: String, senderId: String, text: String, parentMessageId: String? = nil) async throws {
        let convRef = db.collection("conversations").document(conversationId)   // ← declare once
        let msgRef  = convRef.collection("messages").document()

        // Determine threadId: if replying, use parent's threadId or parentId as threadId
        var threadId: String? = nil
        if let parentId = parentMessageId {
            // Get parent message to check if it has a threadId
            let parentRef = convRef.collection("messages").document(parentId)
            let parentSnap = try await parentRef.getDocument()
            if let parentData = parentSnap.data() {
                // If parent has a threadId, use it; otherwise the parent IS the thread root
                threadId = (parentData["threadId"] as? String) ?? parentId
                print("🧵 Replying to thread: parentId=\(parentId), resolved threadId=\(threadId ?? "nil")")
            }
        }

        // Batch: create message + update lastMessage
        let batch = db.batch()
        var messageData: [String: Any] = [
            "senderId": senderId,
            "text": text,
            "createdAt": FieldValue.serverTimestamp(),
            "status": "sent",
            "replyCount": 0
        ]
        
        if let parentId = parentMessageId {
            let resolvedThreadId = threadId ?? parentId
            messageData["parentMessageId"] = parentId
            messageData["threadId"] = resolvedThreadId
            
            // Increment reply count on ALL messages in the thread (root + all replies)
            // First, get all messages in this thread
            let threadMessagesQuery = convRef.collection("messages")
                .whereField("threadId", isEqualTo: resolvedThreadId)
            
            do {
                let threadSnapshot = try await threadMessagesQuery.getDocuments()
                
                // Calculate new reply count
                let currentCount = threadSnapshot.documents.count + 1 // +1 for the reply we're adding
                
                // Set the new message's replyCount to match the thread
                messageData["replyCount"] = currentCount
                
                // Increment replyCount on the root message
                let rootRef = convRef.collection("messages").document(resolvedThreadId)
                batch.updateData(["replyCount": FieldValue.increment(Int64(1))], forDocument: rootRef)
                
                // Increment replyCount on all existing replies in the thread
                for doc in threadSnapshot.documents {
                    batch.updateData(["replyCount": FieldValue.increment(Int64(1))], forDocument: doc.reference)
                }
                
                print("🧵 Set new reply count to \(currentCount), incremented root + \(threadSnapshot.documents.count) existing replies")
            } catch {
                print("⚠️ Failed to update reply counts for thread: \(error)")
                // Still increment on root at minimum
                let rootRef = convRef.collection("messages").document(resolvedThreadId)
                batch.updateData(["replyCount": FieldValue.increment(Int64(1))], forDocument: rootRef)
                // Set new message to have count of 1
                messageData["replyCount"] = 1
            }
        }
        
        batch.setData(messageData, forDocument: msgRef)

        batch.updateData([
            "lastMessageText": text,
            "lastMessageAt": FieldValue.serverTimestamp()
        ], forDocument: convRef)

        // (Optional MVP) increment unreads for other members
        do {
            let convSnap = try await convRef.getDocument()
            let members = (convSnap.data()?["members"] as? [String]) ?? []
            for uid in members where uid != senderId {
                let unreadRef = convRef.collection("unreads").document(uid)
                batch.setData(["count": FieldValue.increment(Int64(1))], forDocument: unreadRef, merge: true)
            }
        } catch {
            // ignore unread bump failures for MVP
        }

        try await commitBatchAsync(batch)
    }


    // Real-time messages listener (chronological)
    @discardableResult
    func listenMessages(conversationId: String,
                        limit: Int = 50,
                        onChange: @escaping ([Message]) -> Void) -> ListenerRegistration {
        let q = db.collection("conversations").document(conversationId)
            .collection("messages")
            .order(by: "createdAt", descending: false)
            .limit(to: limit)

        return q.addSnapshotListener { snap, _ in
            let docs = snap?.documents ?? []
            let msgs: [Message] = docs.compactMap { doc in
                let d = doc.data()
                return Message(
                    id: doc.documentID,
                    senderId: (d["senderId"] as? String) ?? "",
                    text: (d["text"] as? String) ?? "",
                    createdAt: (d["createdAt"] as? Timestamp)?.dateValue() ?? Date.distantPast,
                    status: d["status"] as? String,
                    threadId: d["threadId"] as? String,
                    parentMessageId: d["parentMessageId"] as? String,
                    replyCount: (d["replyCount"] as? Int) ?? 0,
                    isAI: (d["isAI"] as? Bool) ?? false,
                    visibleTo: d["visibleTo"] as? [String],
                    aiAction: d["aiAction"] as? String
                )
            }
            onChange(msgs)
        }
    }
    
    // Get messages in a thread (including the root message) - one-time fetch
    func getThreadMessages(conversationId: String, threadId: String) async throws -> [Message] {
        let convRef = db.collection("conversations").document(conversationId)
        
        // Get all messages where threadId matches OR id matches (for the root message)
        let messagesRef = convRef.collection("messages")
        
        // Get the root message
        let rootSnap = try await messagesRef.document(threadId).getDocument()
        var messages: [Message] = []
        
        if let rootData = rootSnap.data() {
            messages.append(Message(
                id: rootSnap.documentID,
                senderId: (rootData["senderId"] as? String) ?? "",
                text: (rootData["text"] as? String) ?? "",
                createdAt: (rootData["createdAt"] as? Timestamp)?.dateValue() ?? Date.distantPast,
                status: rootData["status"] as? String,
                threadId: rootData["threadId"] as? String,
                parentMessageId: rootData["parentMessageId"] as? String,
                replyCount: (rootData["replyCount"] as? Int) ?? 0,
                isAI: (rootData["isAI"] as? Bool) ?? false,
                visibleTo: rootData["visibleTo"] as? [String],
                aiAction: rootData["aiAction"] as? String
            ))
        }
        
        // Get all replies in the thread
        let repliesSnap = try await messagesRef
            .whereField("threadId", isEqualTo: threadId)
            .order(by: "createdAt", descending: false)
            .getDocuments()
        
        for doc in repliesSnap.documents {
            let d = doc.data()
            messages.append(Message(
                id: doc.documentID,
                senderId: (d["senderId"] as? String) ?? "",
                text: (d["text"] as? String) ?? "",
                createdAt: (d["createdAt"] as? Timestamp)?.dateValue() ?? Date.distantPast,
                status: d["status"] as? String,
                threadId: d["threadId"] as? String,
                parentMessageId: d["parentMessageId"] as? String,
                replyCount: (d["replyCount"] as? Int) ?? 0,
                isAI: (d["isAI"] as? Bool) ?? false,
                visibleTo: d["visibleTo"] as? [String],
                aiAction: d["aiAction"] as? String
            ))
        }
        
        // Sort by createdAt
        return messages.sorted { ($0.createdAt ?? Date.distantPast) < ($1.createdAt ?? Date.distantPast) }
    }
    
    // Real-time listener for thread messages
    @discardableResult
    func listenThreadMessages(conversationId: String, threadId: String, onChange: @escaping ([Message]) -> Void) -> ListenerRegistration {
        let convRef = db.collection("conversations").document(conversationId)
        let messagesRef = convRef.collection("messages")
        
        // Listen to all messages where threadId matches
        let query = messagesRef
            .whereField("threadId", isEqualTo: threadId)
            .order(by: "createdAt", descending: false)
        
        return query.addSnapshotListener { snapshot, error in
            if let error = error {
                print("❌ Thread listener error: \(error.localizedDescription)")
                return
            }
            
            guard let docs = snapshot?.documents else { 
                print("⚠️ Thread listener: no documents")
                return 
            }
            
            print("🧵 Thread listener received \(docs.count) messages for thread \(threadId)")
            
            var messages: [Message] = []
            
            // Include all replies
            for doc in docs {
                let d = doc.data()
                let msg = Message(
                    id: doc.documentID,
                    senderId: (d["senderId"] as? String) ?? "",
                    text: (d["text"] as? String) ?? "",
                    createdAt: (d["createdAt"] as? Timestamp)?.dateValue() ?? Date.distantPast,
                    status: d["status"] as? String,
                    threadId: d["threadId"] as? String,
                    parentMessageId: d["parentMessageId"] as? String,
                    replyCount: (d["replyCount"] as? Int) ?? 0,
                    isAI: (d["isAI"] as? Bool) ?? false,
                    visibleTo: d["visibleTo"] as? [String],
                    aiAction: d["aiAction"] as? String
                )
                print("  - Message: \(msg.text.prefix(30))... threadId=\(msg.threadId ?? "nil")")
                messages.append(msg)
            }
            
            onChange(messages)
        }
    }

    // MARK: - Explicit async wrappers (no generic-parameter ambiguity)

    private func setDataAsync(ref: DocumentReference, data: [String: Any], merge: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ref.setData(data, merge: merge) { err in
                if let err = err { cont.resume(throwing: err) }
                else { cont.resume(returning: ()) }
            }
        }
    }


    private func commitBatchAsync(_ batch: WriteBatch) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            batch.commit { err in
                if let err = err { cont.resume(throwing: err) }
                else { cont.resume(returning: ()) }
            }
        }
    }

    private func getDocumentsAsync(query: Query) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<QuerySnapshot, Error>) in
            query.getDocuments { snap, err in
                if let err = err { cont.resume(throwing: err) }
                else { cont.resume(returning: snap!) }
            }
        }
    }
    
    func openOrCreateDM(me: String, other: String) async throws -> String {
        let key = dmKey(me, other)
        let docId = "dm_\(key)" // deterministic id: dm_<min>__<max>
        let ref = db.collection("conversations").document(docId)

        // Blind upsert — no read
        let data: [String: Any] = [
            "members": [me, other],
            "memberCount": 2,
            "dmKey": key,
            "createdAt": FieldValue.serverTimestamp()
        ]
        print("DM upsert data:", data, "docId:", docId)

        // Use merge:true so if it already exists, we don't clobber anything
        try await setDataAsync(ref: ref, data: data, merge: true)
        return ref.documentID
    }
    // Conversation inbox listener: newest first
    @discardableResult
    func listenConversations(for uid: String,
                             onChange: @escaping ([Conversation]) -> Void) -> ListenerRegistration {
        let q = db.collection("conversations")
            .whereField("members", arrayContains: uid)
            .order(by: "lastMessageAt", descending: true) // falls back to createdAt if lastMessageAt is nil
        return q.addSnapshotListener { snap, _ in
            guard let docs = snap?.documents else { return }
            let items: [Conversation] = docs.map { doc in
                let d = doc.data()
                return Conversation(
                    id: doc.documentID,
                    members: (d["members"] as? [String]) ?? [],
                    memberCount: (d["memberCount"] as? Int) ?? 0,
                    name: d["name"] as? String,
                    lastMessageText: d["lastMessageText"] as? String,
                    lastMessageAt: (d["lastMessageAt"] as? Timestamp)?.dateValue()
                )
            }
            onChange(items)
        }
    }
    func clearUnreads(conversationId: String, uid: String) async {
        let ref = db.collection("conversations")
            .document(conversationId)
            .collection("unreads")
            .document(uid)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                ref.setData(["count": 0], merge: true) { err in
                    err == nil ? cont.resume(returning: ()) : cont.resume(throwing: err!)
                }
            }
        } catch {
            // optional: print("clearUnreads error:", error.localizedDescription)
        }
    }
    func loadOlderMessages(conversationId: String,
                           before: QueryDocumentSnapshot?,           // ← use QueryDocumentSnapshot?
                           pageSize: Int = 30) async throws -> ([Message], QueryDocumentSnapshot?) {
        var q: Query = db.collection("conversations").document(conversationId)
            .collection("messages")
            .order(by: "createdAt", descending: true)
            .limit(to: pageSize)
        if let before { q = q.start(afterDocument: before) }

        let snap = try await getDocumentsAsync(query: q)
        let docs = snap.documents
        // make it a real Array in chronological order:
        let msgs = Array(docs.compactMap { doc -> Message? in
            let d = doc.data()
            return Message(
                id: doc.documentID,
                senderId: d["senderId"] as? String ?? "",
                text: d["text"] as? String ?? "",
                createdAt: (d["createdAt"] as? Timestamp)?.dateValue(),
                status: d["status"] as? String,
                threadId: d["threadId"] as? String,
                parentMessageId: d["parentMessageId"] as? String,
                replyCount: (d["replyCount"] as? Int) ?? 0,
                isAI: (d["isAI"] as? Bool) ?? false,
                visibleTo: d["visibleTo"] as? [String],
                aiAction: d["aiAction"] as? String
            )
        }.reversed())

        return (msgs, docs.last) // last doc becomes next cursor
    }
    func setTyping(conversationId: String, uid: String, isTyping: Bool) async {
        let ref = db.collection("conversations").document(conversationId)
            .collection("typing").document(uid)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                ref.setData(["isTyping": isTyping,
                             "updatedAt": FieldValue.serverTimestamp()], merge: true) { err in
                    err == nil ? cont.resume(returning: ()) : cont.resume(throwing: err!)
                }
            }
        } catch { /* ignore for MVP */ }
    }

    @discardableResult
    func listenTyping(conversationId: String,
                      onChange: @escaping ([String: Bool]) -> Void) -> ListenerRegistration {
        let ref = db.collection("conversations").document(conversationId)
            .collection("typing")
        return ref.addSnapshotListener { snap, _ in
            var map: [String: Bool] = [:]
            snap?.documents.forEach { d in map[d.documentID] = (d["isTyping"] as? Bool) ?? false }
            onChange(map)
        }
    }

    @discardableResult
    func listenReadReceipts(conversationId: String,
                            onChange: @escaping ([String: Date]) -> Void) -> ListenerRegistration {
        let ref = db.collection("conversations").document(conversationId)
            .collection("readReceipts")
        return ref.addSnapshotListener { snap, _ in
            var m: [String: Date] = [:]
            snap?.documents.forEach { d in
                if let ts = d.data()["lastReadAt"] as? Timestamp {
                    m[d.documentID] = ts.dateValue()
                }
            }
            onChange(m)
        }
    }
    func updateReadReceipt(conversationId: String, uid: String, lastReadAt: Date) async {
        // 🔒 Clamp to a safe range before creating FIRTimestamp
        // Firestore supports roughly year 0001..9999, but iOS SDK will throw on extreme values.
        let minOK = Date(timeIntervalSince1970: 0)                 // 1970-01-01 (safe baseline)
        let maxOK = Date(timeIntervalSinceNow: 60 * 60 * 24 * 365 * 5) // now + 5 years
        let safeDate = min(max(lastReadAt, minOK), maxOK)

        // Optional sanity log (remove if noisy)
        // if safeDate != lastReadAt { print("⚠️ Clamped read receipt from \(lastReadAt) to \(safeDate)") }

        let ref = db.collection("conversations").document(conversationId)
            .collection("readReceipts").document(uid)

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                ref.setData(["lastReadAt": Timestamp(date: safeDate)], merge: true) { err in
                    if let err = err { cont.resume(throwing: err) }
                    else { cont.resume(returning: ()) }
                }
            }
        } catch {
            // optional: print("updateReadReceipt error:", error.localizedDescription)
        }
    }
    
    // MARK: - Search Methods
    
    /// Search messages across all conversations the user is a member of
    func searchMessages(
        userId: String,
        keywords: String?,
        senderIds: [String]?,
        dateRange: (Date, Date)?,
        limit: Int = 100
    ) async throws -> [SearchResult] {
        print("🔍 Searching messages for user \(userId)")
        print("   Keywords: \(keywords ?? "none")")
        print("   Senders: \(senderIds?.joined(separator: ", ") ?? "none")")
        print("   Date range: \(dateRange?.0 ?? Date.distantPast) to \(dateRange?.1 ?? Date.distantFuture)")
        
        // First, get all conversations the user is in
        let conversationsQuery = db.collection("conversations")
            .whereField("members", arrayContains: userId)
        
        let conversationsSnapshot = try await getDocumentsAsync(query: conversationsQuery)
        var allResults: [SearchResult] = []
        
        // For each conversation, search messages
        for convDoc in conversationsSnapshot.documents {
            let conversationId = convDoc.documentID
            let convData = convDoc.data()
            let conversationName = convData["name"] as? String
            
            // Build query for messages in this conversation
            var messagesQuery: Query = db.collection("conversations")
                .document(conversationId)
                .collection("messages")
            
            // Apply date range filter if provided
            if let dateRange = dateRange {
                messagesQuery = messagesQuery
                    .whereField("createdAt", isGreaterThanOrEqualTo: Timestamp(date: dateRange.0))
                    .whereField("createdAt", isLessThanOrEqualTo: Timestamp(date: dateRange.1))
            }
            
            // Order by createdAt and limit
            messagesQuery = messagesQuery
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
            
            let messagesSnapshot = try await getDocumentsAsync(query: messagesQuery)
            let messages = messagesSnapshot.documents
            
            // Filter messages in memory (Firestore doesn't support text search)
            for (index, doc) in messages.enumerated() {
                let data = doc.data()
                let text = (data["text"] as? String) ?? ""
                let senderId = (data["senderId"] as? String) ?? ""
                
                // Apply sender filter
                if let senderIds = senderIds, !senderIds.isEmpty, !senderIds.contains(senderId) {
                    continue
                }
                
                // Apply keyword filter (case-insensitive)
                if let keywords = keywords, !keywords.isEmpty {
                    let keywordLower = keywords.lowercased()
                    let textLower = text.lowercased()
                    if !textLower.contains(keywordLower) {
                        continue
                    }
                }
                
                // Create message object
                let message = Message(
                    id: doc.documentID,
                    senderId: senderId,
                    text: text,
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue(),
                    status: data["status"] as? String,
                    threadId: data["threadId"] as? String,
                    parentMessageId: data["parentMessageId"] as? String,
                    replyCount: (data["replyCount"] as? Int) ?? 0,
                    isAI: (data["isAI"] as? Bool) ?? false,
                    visibleTo: data["visibleTo"] as? [String],
                    aiAction: data["aiAction"] as? String
                )
                
                // Get context messages (previous and next)
                var previousMessage: Message? = nil
                var nextMessage: Message? = nil
                
                if index < messages.count - 1 {
                    let prevDoc = messages[index + 1] // reversed order (descending)
                    let prevData = prevDoc.data()
                    previousMessage = Message(
                        id: prevDoc.documentID,
                        senderId: (prevData["senderId"] as? String) ?? "",
                        text: (prevData["text"] as? String) ?? "",
                        createdAt: (prevData["createdAt"] as? Timestamp)?.dateValue(),
                        status: prevData["status"] as? String,
                        threadId: prevData["threadId"] as? String,
                        parentMessageId: prevData["parentMessageId"] as? String,
                        replyCount: (prevData["replyCount"] as? Int) ?? 0,
                        isAI: (prevData["isAI"] as? Bool) ?? false,
                        visibleTo: prevData["visibleTo"] as? [String],
                        aiAction: prevData["aiAction"] as? String
                    )
                }
                
                if index > 0 {
                    let nextDoc = messages[index - 1] // reversed order (descending)
                    let nextData = nextDoc.data()
                    nextMessage = Message(
                        id: nextDoc.documentID,
                        senderId: (nextData["senderId"] as? String) ?? "",
                        text: (nextData["text"] as? String) ?? "",
                        createdAt: (nextData["createdAt"] as? Timestamp)?.dateValue(),
                        status: nextData["status"] as? String,
                        threadId: nextData["threadId"] as? String,
                        parentMessageId: nextData["parentMessageId"] as? String,
                        replyCount: (nextData["replyCount"] as? Int) ?? 0,
                        isAI: (nextData["isAI"] as? Bool) ?? false,
                        visibleTo: nextData["visibleTo"] as? [String],
                        aiAction: nextData["aiAction"] as? String
                    )
                }
                
                // Get sender display name
                var senderDisplayName: String? = nil
                if senderId != "ai_assistant" {
                    do {
                        let userDoc = try await db.collection("users").document(senderId).getDocument()
                        if let userData = userDoc.data() {
                            senderDisplayName = (userData["displayName"] as? String) ?? (userData["email"] as? String)
                        }
                    } catch {
                        print("⚠️ Failed to get sender name for \(senderId): \(error)")
                    }
                }
                
                let searchResult = SearchResult(
                    id: doc.documentID,
                    message: message,
                    conversationId: conversationId,
                    conversationName: conversationName,
                    senderDisplayName: senderDisplayName,
                    relevanceScore: nil,
                    previousMessage: previousMessage,
                    nextMessage: nextMessage
                )
                
                allResults.append(searchResult)
            }
        }
        
        print("🔍 Found \(allResults.count) matching messages")
        
        // Sort by date descending (most recent first)
        return allResults.sorted { ($0.message.createdAt ?? Date.distantPast) > ($1.message.createdAt ?? Date.distantPast) }
    }
    
    /// Get all users the current user has chatted with (for sender filter UI)
    func getAllChatPartners(userId: String) async throws -> [(id: String, displayName: String)] {
        // Get all conversations the user is in
        let conversationsQuery = db.collection("conversations")
            .whereField("members", arrayContains: userId)
        
        let conversationsSnapshot = try await getDocumentsAsync(query: conversationsQuery)
        var userIds = Set<String>()
        
        // Collect all unique member IDs (except the current user)
        for doc in conversationsSnapshot.documents {
            let data = doc.data()
            let members = (data["members"] as? [String]) ?? []
            for memberId in members where memberId != userId {
                userIds.insert(memberId)
            }
        }
        
        // Fetch display names for all users
        var users: [(id: String, displayName: String)] = []
        for uid in userIds {
            do {
                let userDoc = try await db.collection("users").document(uid).getDocument()
                if let userData = userDoc.data() {
                    let displayName = (userData["displayName"] as? String) ?? (userData["email"] as? String) ?? uid
                    users.append((id: uid, displayName: displayName))
                }
            } catch {
                print("⚠️ Failed to get user \(uid): \(error)")
            }
        }
        
        // Sort alphabetically by display name
        return users.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

}

private func dmKey(_ a: String, _ b: String) -> String {
    let (x, y) = a < b ? (a, b) : (b, a)
    return "\(x)__\(y)"
}

