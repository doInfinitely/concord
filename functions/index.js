// functions/index.js
const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {onCall} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");
const admin = require("firebase-admin");
const OpenAI = require("openai");

admin.initializeApp();

// Define the OpenAI API key as a secret
const openaiApiKey = defineSecret("OPENAI_API_KEY");

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

// AI Service - Thread Summarization and other AI features
exports.aiService = onCall(
    {secrets: [openaiApiKey]},
    async (request) => {
        const {conversationId, threadId, action, userId} = request.data;
        
        if (!userId) {
            throw new Error("User ID is required");
        }
        
        if (!conversationId) {
            throw new Error("Conversation ID is required");
        }
        
        try {
            const openai = new OpenAI({
                apiKey: openaiApiKey.value(),
            });
            
            // Fetch conversation messages (RAG pipeline)
            const conversationRef = admin.firestore()
                .collection('conversations')
                .doc(conversationId);
            
            let messagesQuery;
            if (threadId) {
                // Get thread messages
                messagesQuery = conversationRef
                    .collection('messages')
                    .where('threadId', '==', threadId)
                    .orderBy('createdAt', 'asc')
                    .limit(100);
            } else {
                // Get recent conversation messages
                messagesQuery = conversationRef
                    .collection('messages')
                    .orderBy('createdAt', 'desc')
                    .limit(50);
            }
            
            const messagesSnapshot = await messagesQuery.get();
            const messages = [];
            
            // Fetch sender names and build message context
            for (const doc of messagesSnapshot.docs) {
                const msgData = doc.data();
                const senderSnap = await admin.firestore()
                    .collection('users')
                    .doc(msgData.senderId)
                    .get();
                const senderData = senderSnap.data() || {};
                const senderName = senderData.displayName || senderData.email || 'Unknown';
                
                messages.push({
                    sender: senderName,
                    text: msgData.text,
                    timestamp: msgData.createdAt?.toDate?.()?.toISOString() || 'Unknown time'
                });
            }
            
            // Reverse if we got thread messages (they're in correct order already)
            if (!threadId) {
                messages.reverse();
            }
            
            // Build context string
            const conversationContext = messages.map(m => 
                `${m.sender} (${m.timestamp}): ${m.text}`
            ).join('\n');
            
            let systemPrompt = "";
            let userPrompt = "";
            
            // Handle different AI actions
            switch (action) {
                case "summarize_thread":
                    systemPrompt = "You are a helpful assistant that summarizes conversation threads concisely. Provide a clear, 3-5 sentence summary that captures the key points and decisions.";
                    userPrompt = `Please summarize this conversation thread:\n\n${conversationContext}`;
                    break;
                    
                case "extract_actions":
                    systemPrompt = "You are a helpful assistant that extracts action items from conversations. List all tasks, assignments, and deadlines mentioned. Format as bullet points with clear assignees if mentioned.";
                    userPrompt = `Extract action items from this conversation:\n\n${conversationContext}`;
                    break;
                    
                case "check_priority":
                    systemPrompt = "You are a helpful assistant that determines if messages are urgent or time-sensitive. Respond with 'URGENT' or 'NOT URGENT' followed by a brief explanation.";
                    userPrompt = `Is this message urgent or time-sensitive?\n\n${conversationContext}`;
                    break;
                    
                case "summarize_decision":
                    systemPrompt = "You are a helpful assistant that summarizes decisions made in conversations. Identify what was decided, who agreed, and any next steps.";
                    userPrompt = `Summarize the decisions made in this conversation:\n\n${conversationContext}`;
                    break;
                    
                case "extract_event":
                    systemPrompt = "You are a helpful assistant that extracts calendar events from messages. Return JSON with: title, date, time, location, attendees.";
                    userPrompt = `Extract calendar event details from this conversation:\n\n${conversationContext}`;
                    break;
                    
                case "track_rsvps":
                    systemPrompt = "You are a helpful assistant that tracks RSVPs and responses to questions. List who responded, what they said, and who hasn't responded yet.";
                    userPrompt = `Track RSVPs and responses in this conversation:\n\n${conversationContext}`;
                    break;
                    
                default:
                    throw new Error(`Unknown action: ${action}`);
            }
            
            // Call OpenAI
            const completion = await openai.chat.completions.create({
                model: "gpt-4o",
                messages: [
                    {role: "system", content: systemPrompt},
                    {role: "user", content: userPrompt}
                ],
                temperature: 0.7,
                max_tokens: 500,
            });
            
            const aiResponse = completion.choices[0].message.content;
            
            // Store AI response as a message visible only to requesting user
            const aiMessageRef = conversationRef.collection('messages').doc();
            await aiMessageRef.set({
                senderId: 'ai_assistant',
                text: aiResponse,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                status: 'sent',
                isAI: true,
                visibleTo: [userId], // Only visible to requesting user
                aiAction: action,
                threadId: threadId || null,
                replyCount: 0
            });
            
            console.log(`AI response generated for action: ${action}, user: ${userId}`);
            
            return {
                success: true,
                response: aiResponse,
                messageId: aiMessageRef.id
            };
            
        } catch (error) {
            console.error('Error in AI service:', error);
            throw new Error(`AI service error: ${error.message}`);
        }
    }
);
