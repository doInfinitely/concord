//
//  ChatView.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import SwiftUI
import FirebaseAuth

struct ChatView: View {
    let conversationId: String
    @State private var messages: [Message] = []
    @State private var text: String = ""
    private let store = FirestoreService()

    var body: some View {
        VStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(messages, id: \.id) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.text)
                            if let t = m.createdAt { Text(t.formatted()).font(.caption).opacity(0.6) }
                        }
                        .padding(10)
                        .background(.gray.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding()
            }

            HStack {
                TextField("Message…", text: $text)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    Task {
                        guard let uid = Auth.auth().currentUser?.uid, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        let t = text; text = ""
                        try? await store.sendMessage(conversationId: conversationId, senderId: uid, text: t)
                    }
                }
            }.padding()
        }
        .onAppear {
            _ = store.listenMessages(conversationId: conversationId, onChange: { msgs in
                messages = msgs
            })
        }
    }
}
