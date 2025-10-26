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
    private let aiService = AIService()
    
    override init() {
        super.init()
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
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
    
    // MARK: - Local Notifications (Foreground)
    
    /// Show a local notification for a new message with automatic priority detection
    func showNotificationForMessage(
        messageId: String,
        messageText: String,
        senderName: String,
        conversationId: String,
        conversationName: String,
        isGroupChat: Bool
    ) async {
        // Check if notification permission is granted
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        
        print("🔔 Checking priority for message: \(messageText.prefix(50))...")
        
        // Automatically check priority
        let isHighPriority = await detectPriority(for: messageText)
        
        // Create notification content
        let content = UNMutableNotificationContent()
        
        if isGroupChat {
            content.title = conversationName
            content.subtitle = senderName
        } else {
            content.title = senderName
        }
        
        content.body = messageText
        content.sound = isHighPriority ? .defaultCritical : .default
        // Don't set badge here - let iOS increment it automatically
        content.interruptionLevel = isHighPriority ? .timeSensitive : .active
        
        // Add conversation ID for handling taps
        content.userInfo = [
            "conversationId": conversationId,
            "messageId": messageId,
            "isHighPriority": isHighPriority
        ]
        
        // Add priority indicator to notification
        if isHighPriority {
            content.categoryIdentifier = "HIGH_PRIORITY_MESSAGE"
            // Add visual indicator
            content.subtitle = (content.subtitle.isEmpty ? "" : content.subtitle + " · ") + "!!! HIGH PRIORITY"
        }
        
        // Create trigger (deliver immediately)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        
        // Create request
        let request = UNNotificationRequest(
            identifier: messageId,
            content: content,
            trigger: trigger
        )
        
        // Schedule notification
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("🔔 Local notification scheduled for message \(messageId) (priority: \(isHighPriority ? "HIGH" : "normal"))")
        } catch {
            print("❌ Error scheduling notification: \(error)")
        }
    }
    
    /// Automatically detect if a message is high priority using AI
    private func detectPriority(for messageText: String) async -> Bool {
        do {
            let result = try await aiService.checkPriority(messageText: messageText)
            print("🔔 Priority detection result: \(result)")
            return result.contains("high priority") || result.contains("urgent")
        } catch {
            print("❌ Priority detection failed: \(error)")
            return false
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

// MARK: - UNUserNotificationCenterDelegate (Foreground Notifications)
extension NotificationService: UNUserNotificationCenterDelegate {
    /// This method is called when a notification is about to be presented while the app is in the foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    /// This method is called when the user taps on a notification
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        
        Task { @MainActor in
            // Handle notification tap
            handleNotification(userInfo: userInfo)
        }
        
        completionHandler()
    }
}
