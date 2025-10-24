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

    // Send a message and update lastMessage fields atomically.
    func sendMessage(conversationId: String, senderId: String, text: String) async throws {
        let convRef = db.collection("conversations").document(conversationId)   // ← declare once
        let msgRef  = convRef.collection("messages").document()

        // Batch: create message + update lastMessage
        let batch = db.batch()
        batch.setData([
            "senderId": senderId,
            "text": text,
            "createdAt": FieldValue.serverTimestamp(),
            "status": "sent"
        ], forDocument: msgRef)

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
                    status: d["status"] as? String
                )
            }
            onChange(msgs)
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
                let name = d["name"] as? String
                print("📱 Conversation \(doc.documentID): name = \(name ?? "nil")")
                return Conversation(
                    id: doc.documentID,
                    members: (d["members"] as? [String]) ?? [],
                    memberCount: (d["memberCount"] as? Int) ?? 0,
                    name: name,
                    lastMessageText: d["lastMessageText"] as? String,
                    lastMessageAt: (d["lastMessageAt"] as? Timestamp)?.dateValue()
                )
            }
            print("📱 Conversations list updated: \(items.count) conversations")
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
                status: d["status"] as? String
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

}

private func dmKey(_ a: String, _ b: String) -> String {
    let (x, y) = a < b ? (a, b) : (b, a)
    return "\(x)__\(y)"
}

