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
        const {conversationId, threadId, action, userId, messageText} = request.data;
        
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
            
            let messages = [];
            
            if (threadId) {
                // For threads, we need to get BOTH the root message AND all replies
                // The root message doesn't have threadId set, so we fetch it separately
                
                // 1. Get the root message
                const rootMessageDoc = await conversationRef
                    .collection('messages')
                    .doc(threadId)
                    .get();
                
                if (rootMessageDoc.exists) {
                    const rootData = rootMessageDoc.data();
                    const senderSnap = await admin.firestore()
                        .collection('users')
                        .doc(rootData.senderId)
                        .get();
                    const senderData = senderSnap.data() || {};
                    const senderName = senderData.displayName || senderData.email || 'Unknown';
                    
                    messages.push({
                        sender: senderName,
                        text: rootData.text,
                        timestamp: rootData.createdAt?.toDate?.()?.toISOString() || 'Unknown time'
                    });
                }
                
                // 2. Get all replies in the thread
                const threadMessagesQuery = conversationRef
                    .collection('messages')
                    .where('threadId', '==', threadId)
                    .orderBy('createdAt', 'asc')
                    .limit(100);
                
                const threadSnapshot = await threadMessagesQuery.get();
                
                for (const doc of threadSnapshot.docs) {
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
            } else {
                // Get recent conversation messages
                const messagesQuery = conversationRef
                    .collection('messages')
                    .orderBy('createdAt', 'desc')
                    .limit(50);
                
                const messagesSnapshot = await messagesQuery.get();
                const docs = messagesSnapshot.docs.reverse(); // Reverse to chronological order
                
                for (const doc of docs) {
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
            }
            
            // Build context string
            const conversationContext = messages.map(m => 
                `${m.sender} (${m.timestamp}): ${m.text}`
            ).join('\n');
            
            console.log(`🤖 AI Context for ${action}:\n${conversationContext}`);
            
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
                    
                case "extract_event": {
                    const now = new Date();
                    const currentDate = now.toISOString();
                    
                    // Get current day info in UTC (where Cloud Function runs)
                    const dayOfWeekNum = now.getUTCDay(); // 0=Sunday, 1=Monday, ..., 6=Saturday
                    const dayNames = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
                    const monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
                    const dayOfWeek = dayNames[dayOfWeekNum];
                    const dateStr = `${monthNames[now.getUTCMonth()]} ${now.getUTCDate()}, ${now.getUTCFullYear()}`;
                    
                    // Calculate what "next Thursday" means from today
                    const daysUntilNextThursday = dayOfWeekNum <= 4 ? (4 - dayOfWeekNum + 7) : (11 - dayOfWeekNum);
                    const nextThursday = new Date(now);
                    nextThursday.setUTCDate(now.getUTCDate() + daysUntilNextThursday);
                    const nextThursdayStr = `${monthNames[nextThursday.getUTCMonth()]} ${nextThursday.getUTCDate()}`;
                    
                    systemPrompt = `You are a helpful assistant that extracts calendar events from messages. 

TODAY'S INFO (UTC):
- Current date: ${dateStr} (${dayOfWeek})
- ISO timestamp: ${currentDate}

IMPORTANT DATE PARSING RULES:
- If someone says "next Thursday" today (${dayOfWeek} ${dateStr}), that means ${nextThursdayStr}
- "this Thursday" = the upcoming Thursday of this current week (if we haven't passed Thursday yet)
- "next Thursday" = the Thursday of next week
- Calculate dates carefully by counting forward from today

Read the ENTIRE conversation to find the final agreed meeting time. If the time changed during the conversation, use the FINAL agreed time.

CRITICAL: For the date field, use ISO8601 format but WITHOUT timezone conversion. If someone says "1pm", return the date with 13:00 in the local time context (use 'T13:00:00' in the ISO string). Do NOT convert to UTC. The client app will handle timezone.

Return ONLY a valid JSON object (no markdown, no extra text):
{
  "title": "string",
  "date": "ISO8601 string without timezone offset (e.g., '2025-10-30T13:00:00')",
  "durationMinutes": 60,
  "location": "string or null",
  "attendees": ["array", "of", "strings"],
  "notes": "string or null"
}`;
                    userPrompt = `Extract calendar event details from this conversation:\n\n${conversationContext}`;
                    break;
                }
                    
                case "track_rsvps":
                    systemPrompt = "You are a helpful assistant that tracks RSVPs and responses to questions. List who responded, what they said, and who hasn't responded yet.";
                    userPrompt = `Track RSVPs and responses in this conversation:\n\n${conversationContext}`;
                    break;
                
                case "extract_meeting_subject":
                    if (!messageText) {
                        throw new Error("messageText is required for extract_meeting_subject action");
                    }
                    systemPrompt = `You are a helpful assistant that extracts the subject/purpose of a meeting from a message. 
Extract ONLY the meeting subject - what the meeting is about.

Examples:
- "Let's meet at 3pm today for the Farmer's Market." → "Farmer's Market"
- "Coffee at 3pm tomorrow" → "Coffee"
- "Team meeting next Thursday at 2pm" → "Team meeting"
- "Let's meet for lunch" → "Lunch"

Return ONLY the subject text, no quotes, no extra explanation.`;
                    userPrompt = `Extract the meeting subject from this message:\n\n${messageText}`;
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
            
            // For calendar events and meeting subject extraction, don't store as a message - return directly
            if (action === "extract_event" || action === "extract_meeting_subject") {
                console.log(`${action} completed for user: ${userId}`);
                return {
                    success: true,
                    response: aiResponse,
                    messageId: null // No message created
                };
            }
            
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

// Proactive Assistant - Detects meeting proposals and checks for conflicts
exports.proactiveAssistant = onDocumentCreated(
    {
        document: "conversations/{conversationId}/messages/{messageId}",
        secrets: [openaiApiKey],
    },
    async (event) => {
        const message = event.data.data();
        const conversationId = event.params.conversationId;
        const messageText = message.text;
        const senderId = message.senderId;
        
        // Skip AI messages
        if (message.isAI) {
            return null;
        }
        
        try {
            const openai = new OpenAI({
                apiKey: openaiApiKey.value(),
            });
            
            // Ask AI if this message contains a meeting proposal
            const detectMeetingCompletion = await openai.chat.completions.create({
                model: "gpt-4o-mini",
                messages: [
                    {
                        role: "system",
                        content: `You are a meeting detection assistant. Determine if a message contains a meeting proposal with a specific time. 
                        Return ONLY a JSON object with these fields:
                        - isMeetingProposal (boolean): true if the message proposes a meeting with a specific time
                        - dateTime (string): ISO8601 date/time if found, null otherwise
                        - duration (number): meeting duration in minutes (default 60)
                        - title (string): brief meeting title
                        
                        Examples of meeting proposals:
                        - "Let's meet at 2pm tomorrow"
                        - "Can we schedule a call for 3:30pm on Thursday?"
                        - "Meeting at 10am next Monday"
                        
                        NOT meeting proposals:
                        - "Let's meet sometime"
                        - "We should talk soon"
                        - "Available this week?"`,
                    },
                    {
                        role: "user",
                        content: `Current time: ${new Date().toISOString()}\n\nMessage: "${messageText}"`,
                    },
                ],
                response_format: {type: "json_object"},
                temperature: 0.3,
            });
            
            const detection = JSON.parse(detectMeetingCompletion.choices[0].message.content);
            console.log("Meeting detection result:", detection);
            
            if (!detection.isMeetingProposal || !detection.dateTime) {
                return null; // Not a meeting proposal
            }
            
            // Get all conversation members except the sender
            const conversationRef = admin.firestore()
                .collection('conversations')
                .doc(conversationId);
            const conversationSnap = await conversationRef.get();
            const members = conversationSnap.data()?.members || [];
            const recipients = members.filter(uid => uid !== senderId);
            
            // For each recipient, check their calendar for conflicts
            for (const userId of recipients) {
                try {
                    // Get user's calendar tokens
                    const userDoc = await admin.firestore()
                        .collection('users')
                        .doc(userId)
                        .get();
                    const userData = userDoc.data() || {};
                    
                    // For now, we'll create a placeholder proactive message
                    // In a full implementation, you'd call Google Calendar API here
                    const hasConflict = false; // TODO: Actual conflict checking
                    
                    if (hasConflict) {
                        // Send proactive AI message suggesting alternatives
                        const aiMessageRef = conversationRef.collection('messages').doc();
                        await aiMessageRef.set({
                            senderId: 'ai_assistant',
                            text: `⚠️ **Calendar Conflict Detected**\n\nThe proposed meeting time (${detection.dateTime}) conflicts with an existing event on your calendar.\n\n**Suggested alternatives:**\n- Option 1: [Alternative time 1]\n- Option 2: [Alternative time 2]\n- Option 3: [Alternative time 3]\n\nWould you like me to help reschedule?`,
                            createdAt: admin.firestore.FieldValue.serverTimestamp(),
                            status: 'sent',
                            isAI: true,
                            visibleTo: [userId],
                            aiAction: 'proactive_conflict_detection',
                            replyCount: 0,
                        });
                        
                        console.log(`Sent proactive conflict warning to user ${userId}`);
                    }
                } catch (error) {
                    console.error(`Error checking calendar for user ${userId}:`, error);
                }
            }
            
            return null;
        } catch (error) {
            console.error('Error in proactive assistant:', error);
            return null; // Don't throw, just log
        }
    }
);

// Callable function to check conflicts and suggest times (called from iOS app)
exports.checkConflictsAndSuggest = onCall(
    {secrets: [openaiApiKey]},
    async (request) => {
        const {dateTime, duration, userId} = request.data;
        
        if (!userId || !dateTime) {
            throw new Error("userId and dateTime are required");
        }
        
        try {
            // Get user's calendar tokens
            const userDoc = await admin.firestore()
                .collection('users')
                .doc(userId)
                .get();
            const userData = userDoc.data() || {};
            
            const proposedDate = new Date(dateTime);
            const durationMs = (duration || 60) * 60 * 1000; // Convert to milliseconds
            
            // TODO: Check Apple Calendar via user's device (requires callback)
            // TODO: Check Google Calendar via API
            const hasConflict = false; // Placeholder
            const conflicts = []; // Placeholder
            
            if (!hasConflict) {
                return {
                    success: true,
                    hasConflict: false,
                    conflicts: [],
                    suggestions: [],
                };
            }
            
            // Find alternative slots (placeholder logic)
            const suggestions = [
                new Date(proposedDate.getTime() + 3600000).toISOString(), // +1 hour
                new Date(proposedDate.getTime() + 7200000).toISOString(), // +2 hours
                new Date(proposedDate.getTime() + 10800000).toISOString(), // +3 hours
            ];
            
            return {
                success: true,
                hasConflict: true,
                conflicts: conflicts,
                suggestions: suggestions,
            };
            
        } catch (error) {
            console.error('Error checking conflicts:', error);
            throw new Error(`Conflict check error: ${error.message}`);
        }
    }
);

// Intelligent search - rank messages by relevance to natural language query
exports.intelligentSearch = onCall(
    {secrets: [openaiApiKey]},
    async (request) => {
        const {messages, query} = request.data;
        
        if (!messages || !Array.isArray(messages) || messages.length === 0) {
            throw new Error('Messages array is required');
        }
        
        if (!query || typeof query !== 'string') {
            throw new Error('Query string is required');
        }
        
        console.log(`🤖 Intelligent search: query="${query}", ${messages.length} messages`);
        
        try {
            const openai = new OpenAI({
                apiKey: openaiApiKey.value(),
            });
            
            // Prepare message data for the AI
            const messageTexts = messages.map((msg, idx) => {
                const senderName = msg.senderName || 'Unknown';
                const conversationName = msg.conversationName || 'DM';
                const date = new Date(msg.createdAt * 1000).toLocaleDateString();
                return `[${idx}] From ${senderName} in ${conversationName} on ${date}: ${msg.text}`;
            }).join('\n\n');
            
            const prompt = `You are a search assistant. Given a list of messages and a user query, rank each message by relevance to the query on a scale of 0.0 to 1.0, where 1.0 is highly relevant and 0.0 is not relevant at all.

Query: "${query}"

Messages:
${messageTexts}

Respond with ONLY a valid JSON array of objects with "index" (the message number in brackets) and "score" (0.0-1.0) fields, ordered by relevance score descending. Example format:
[{"index": 5, "score": 0.95}, {"index": 2, "score": 0.80}, ...]`;
            
            const completion = await openai.chat.completions.create({
                model: 'gpt-4o',
                messages: [
                    {
                        role: 'system',
                        content: 'You are a precise search relevance scoring assistant. Always respond with valid JSON only, no additional text.',
                    },
                    {
                        role: 'user',
                        content: prompt,
                    },
                ],
                temperature: 0.3,
            });
            
            const responseText = completion.choices[0].message.content.trim();
            console.log('🤖 AI response:', responseText);
            
            // Parse JSON response
            let rankings;
            try {
                rankings = JSON.parse(responseText);
            } catch (parseError) {
                console.error('Failed to parse AI response:', parseError);
                // Try to extract JSON from markdown code blocks
                const jsonMatch = responseText.match(/```json\s*([\s\S]*?)\s*```/);
                if (jsonMatch) {
                    rankings = JSON.parse(jsonMatch[1]);
                } else {
                    throw new Error('AI response is not valid JSON');
                }
            }
            
            if (!Array.isArray(rankings)) {
                throw new Error('AI response is not an array');
            }
            
            // Map indices back to message IDs
            const result = rankings.map(ranking => {
                const messageIndex = ranking.index;
                if (messageIndex >= 0 && messageIndex < messages.length) {
                    return {
                        messageId: messages[messageIndex].id,
                        score: ranking.score,
                    };
                }
                return null;
            }).filter(r => r !== null);
            
            console.log(`🤖 Ranked ${result.length} messages`);
            
            return {
                success: true,
                rankings: result,
            };
            
        } catch (error) {
            console.error('Error in intelligent search:', error);
            return {
                success: false,
                error: `Intelligent search error: ${error.message}`,
            };
        }
    }
);
