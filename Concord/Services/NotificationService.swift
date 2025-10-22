//
//  NotificationService.swift
//  Concord
//
//  Created by Remy Ochei on 10/21/25.
//

import Foundation
import Combine  // <- ADD THIS
import UserNotifications
import FirebaseMessaging
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class NotificationService: NSObject, ObservableObject {
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var fcmToken: String?
    
    private let db = Firestore.firestore()
    
    override init() {
        super.init()
        Messaging.messaging().delegate = self
    }
    
    // MARK: - Request Permission
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            
            await checkAuthorizationStatus()
        } catch {
            print("Error requesting notification permission: \(error.localizedDescription)")
        }
    }
    
    func checkAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }
    
    // MARK: - Save FCM Token
    func saveFCMToken(for uid: String) async {
        guard let token = fcmToken else { return }
        
        do {
            try await db.collection("users").document(uid).setData([
                "fcmToken": token,
                "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
            ], merge: true)
            print("FCM token saved: \(token)")
        } catch {
            print("Error saving FCM token: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Handle Notifications
    func handleNotification(userInfo: [AnyHashable: Any]) {
        // Extract conversation ID from notification
        if let conversationId = userInfo["conversationId"] as? String {
            // Navigate to conversation
            NotificationCenter.default.post(
                name: .openConversation,
                object: nil,
                userInfo: ["conversationId": conversationId]
            )
        }
    }
}

// MARK: - MessagingDelegate
extension NotificationService: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task { @MainActor in
            self.fcmToken = fcmToken
            print("FCM Token: \(fcmToken ?? "nil")")
            
            // Save token for current user
            if let uid = Auth.auth().currentUser?.uid {
                await saveFCMToken(for: uid)
            }
        }
    }
}

// MARK: - Notification Names (REMOVE from here, already in AppDelegate)
// DELETE THIS SECTION - it's causing the redeclaration error
