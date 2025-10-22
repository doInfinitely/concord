// functions/index.js
const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
admin.initializeApp();

// Trigger when a new message is created
exports.sendMessageNotification = onDocumentCreated(
    "conversations/{conversationId}/messages/{messageId}",
    async (event) => {
        const message = event.data.data();
        const conversationId = event.params.conversationId;
        const senderId = message.senderId;
        
        try {
            // Get conversation details
            const conversationRef = admin.firestore()
                .collection('conversations')
                .doc(conversationId);
            const conversationSnap = await conversationRef.get();
            
            if (!conversationSnap.exists) {
                console.log('Conversation not found');
                return null;
            }
            
            const conversation = conversationSnap.data();
            const members = conversation.members || [];
            
            // Get sender's profile
            const senderSnap = await admin.firestore()
                .collection('users')
                .doc(senderId)
                .get();
            const senderData = senderSnap.data() || {};
            const senderName = senderData.displayName || senderData.email || 'Someone';
            
            // Get FCM tokens for all members except sender
            const recipients = members.filter(uid => uid !== senderId);
            
            if (recipients.length === 0) {
                console.log('No recipients to notify');
                return null;
            }
            
            // Fetch all recipient profiles
            const recipientTokens = [];
            for (const uid of recipients) {
                const userSnap = await admin.firestore()
                    .collection('users')
                    .doc(uid)
                    .get();
                const userData = userSnap.data();
                if (userData && userData.fcmToken) {
                    recipientTokens.push(userData.fcmToken);
                }
            }
            
            if (recipientTokens.length === 0) {
                console.log('No FCM tokens found for recipients');
                return null;
            }
            
            // Prepare notification
            const notificationTitle = conversation.name 
                ? `${senderName} in ${conversation.name}`
                : senderName;
            
            const messageText = message.text || '';
            const payload = {
                notification: {
                    title: notificationTitle,
                    body: messageText.length > 100 
                        ? messageText.substring(0, 97) + '...'
                        : messageText,
                },
                data: {
                    conversationId: conversationId,
                    senderId: senderId,
                    messageId: event.data.id,
                    type: 'new_message',
                },
                apns: {
                    payload: {
                        aps: {
                            sound: 'default',
                            badge: 1,
                        },
                    },
                },
            };
            
            // Send to all recipients
            const promises = recipientTokens.map(token => 
                admin.messaging().send({
                    token: token,
                    ...payload
                }).catch(error => {
                    console.error('Error sending to token:', token, error);
                    // Handle invalid tokens
                    if (error.code === 'messaging/invalid-registration-token' ||
                        error.code === 'messaging/registration-token-not-registered') {
                        // Remove invalid token
                        return admin.firestore()
                            .collection('users')
                            .where('fcmToken', '==', token)
                            .get()
                            .then(snapshot => {
                                snapshot.forEach(doc => {
                                    doc.ref.update({
                                        fcmToken: admin.firestore.FieldValue.delete()
                                    });
                                });
                            });
                    }
                    return null;
                })
            );
            
            const results = await Promise.allSettled(promises);
            const successCount = results.filter(r => r.status === 'fulfilled' && r.value !== null).length;
            console.log('Successfully sent notifications:', successCount);
            
            return null;
        } catch (error) {
            console.error('Error sending notification:', error);
            return null;
        }
    }
);

// Send notification when user is added to a group
exports.sendGroupAddedNotification = onDocumentUpdated(
    "conversations/{conversationId}",
    async (event) => {
        const before = event.data.before.data();
        const after = event.data.after.data();
        const conversationId = event.params.conversationId;
        
        // Check if members were added
        const beforeMembers = before.members || [];
        const afterMembers = after.members || [];
        const newMembers = afterMembers.filter(m => !beforeMembers.includes(m));
        
        if (newMembers.length === 0) {
            return null;
        }
        
        try {
            // Get FCM tokens for new members
            const tokens = [];
            for (const uid of newMembers) {
                const userSnap = await admin.firestore()
                    .collection('users')
                    .doc(uid)
                    .get();
                const userData = userSnap.data();
                if (userData && userData.fcmToken) {
                    tokens.push(userData.fcmToken);
                }
            }
            
            if (tokens.length === 0) {
                return null;
            }
            
            const groupName = after.name || 'a group chat';
            
            const payload = {
                notification: {
                    title: 'Added to Group',
                    body: `You've been added to ${groupName}`,
                },
                data: {
                    conversationId: conversationId,
                    type: 'group_added',
                },
                apns: {
                    payload: {
                        aps: {
                            sound: 'default',
                            badge: 1,
                        },
                    },
                },
            };
            
            const promises = tokens.map(token => 
                admin.messaging().send({
                    token: token,
                    ...payload
                }).catch(error => {
                    console.error('Error sending to token:', error);
                    return null;
                })
            );
            
            await Promise.allSettled(promises);
            return null;
        } catch (error) {
            console.error('Error sending group notification:', error);
            return null;
        }
    }
);
