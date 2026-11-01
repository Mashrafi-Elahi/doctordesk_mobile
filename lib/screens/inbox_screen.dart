import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/chat_message.dart';
import '../services/app_language.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../widgets/user_avatar.dart';
import '../widgets/state_views.dart';
import '../widgets/profile_avatar_button.dart';
import 'chat_screen.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {

  String _formatTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    // The shell builds this tab once (const), so follow sign-in/out here.
    return StreamBuilder<User?>(
      stream: AuthService.authStateChanges,
      initialData: AuthService.currentUser,
      builder: (context, snap) => _buildFor(context, snap.data?.uid),
    );
  }

  Widget _buildFor(BuildContext context, String? currentUid) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          tr('Inbox'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: const [
          ProfileAvatarButton(),
        ],
      ),
      body: currentUid == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Please sign in to view your conversations.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          : StreamBuilder<List<ChatSession>>(
              stream: ChatService.streamUserChats(currentUid),
              builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorStateView.fromError(snapshot.error,
                what: 'conversations', onRetry: () => setState(() {}));
          }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final chats = snapshot.data ?? [];
                if (chats.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.chat_bubble_outline, size: 56, color: Colors.grey[350]),
                          const SizedBox(height: 16),
                          const Text(
                            'No conversations yet',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Direct messaging unlocks with your doctor and clinic desk operator when an appointment is confirmed.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey[600], fontSize: 14, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: chats.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final chat = chats[index];
                    final otherName = chat.otherParticipantName(currentUid);
                    final otherRole = chat.otherParticipantRole(currentUid);
                    final isClosed = chat.status == 'closed';
                    final isExpired = chat.isExpired;

                    Color statusColor = Colors.green;
                    String statusLabel = 'Active';
                    if (isClosed) {
                      statusColor = Colors.grey;
                      statusLabel = 'Closed';
                    } else if (isExpired) {
                      statusColor = Colors.orange;
                      statusLabel = 'Expired';
                    }

                    final otherUid = chat.participants.firstWhere((p) => p != currentUid, orElse: () => '');

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      leading: UserAvatar(uid: otherUid, name: otherName),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              otherName,
                              style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 15),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              statusLabel,
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: statusColor),
                            ),
                          ),
                        ],
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 2),
                          Text(
                            otherRole,
                            style: TextStyle(fontSize: 11, color: theme.colorScheme.primary, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            chat.lastMessage,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.grey[700], fontSize: 13),
                          ),
                        ],
                      ),
                      trailing: Text(
                        _formatTime(chat.updatedAt),
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                              chatId: chat.id,
                              otherUserName: otherName,
                              otherUserRole: otherRole,
                              otherUserUid: otherUid,
                              isDoctor: AuthService.userRoles.isDoctor,
                              isOperator: AuthService.userRoles.isOperator,
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
    );
  }
}
