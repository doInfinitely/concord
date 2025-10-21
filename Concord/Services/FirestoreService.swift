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
        let convRef = db.collection("conversations").document(conversationId)
        let msgRef  = convRef.collection("messages").document()

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
                    createdAt: (d["createdAt"] as? Timestamp)?.dateValue(),
                    status: d["status"] as? String
                )
            }
            onChange(msgs)
        }
    }

    // MARK: - Explicit async wrappers (no generic-parameter ambiguity)

    private func setDataAsync(ref: DocumentReference, data: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ref.setData(data) { err in
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
}

