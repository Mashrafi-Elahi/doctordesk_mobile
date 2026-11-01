// notifications_screen.dart
//
// In-app notifications screen showing appointment confirmations, comments on
// posts, doctor reviews, and system alerts.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../widgets/state_views.dart';
import '../services/notification_service.dart';
import '../services/auth_service.dart';
import 'appointment_screen.dart';
import 'chat_screen.dart';
import 'feed_screen.dart';
import 'operator_desk_screen.dart';
import '../theme/app_constants.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final String _userId = NotificationService.currentUserId;

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all notifications?'),
        content: const Text('This removes every notification from this account.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await NotificationService.clearAll(_userId);
      setState(() {});
    }
  }

  IconData _iconForType(String type) => switch (type) {
        'comment' => Icons.chat_bubble_outline_rounded,
        'chat_message' || 'chat_unlock' => Icons.mail_outline_rounded,
        'appointment' || 'appointment_confirmed' || 'appointment_requested' => Icons.calendar_today_rounded,
        'review' => Icons.star_outline_rounded,
        _ => Icons.notifications_outlined,
      };

  Color _colorForType(String type) => switch (type) {
        'comment' => const Color(0xFF0288D1),
        'chat_message' || 'chat_unlock' => Theme.of(context).colorScheme.primary,
        'appointment' || 'appointment_confirmed' || 'appointment_requested' => Theme.of(context).colorScheme.primary,
        'review' => AppColors.star,
        _ => Colors.blueGrey,
      };

  String _formatTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  Future<void> _openNotification(AppNotification notification) async {
    await NotificationService.markAsRead(notification.id, _userId);
    if (!mounted) return;
    final type = notification.type;
    if (type.contains('chat') && notification.relatedId != null && notification.relatedId!.isNotEmpty) {
      final title = notification.title.replaceAll('New message from ', '');
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: notification.relatedId!,
            otherUserName: title.isNotEmpty ? title : 'Chat',
            otherUserUid: '',
            isDoctor: AuthService.userRoles.isDoctor,
            isOperator: AuthService.userRoles.isOperator,
          ),
        ),
      );
    } else if (type.contains('appointment') || type.contains('queue')) {
      final roles = AuthService.userRoles;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => roles.isDoctor || roles.isOperator
              ? const OperatorDeskScreen()
              : const AppointmentScreen(),
        ),
      );
    } else if (type.contains('comment') || type.contains('post')) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const FeedScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Notifications',
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Clear all',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _confirmClearAll,
          ),
        ],
      ),
      body: StreamBuilder<List<AppNotification>>(
        stream: NotificationService.notificationsStream(_userId),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorStateView.fromError(snapshot.error,
                what: 'notifications', onRetry: () => setState(() {}));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final notifications = snapshot.data ?? [];

          if (notifications.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.notifications_off_outlined,
                    size: 64,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No notifications yet',
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Confirmations, review updates, and replies appear here.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: notifications.length,
            separatorBuilder: (_, __) => Divider(
              height: 1,
              color: Colors.grey.shade200,
            ),
            itemBuilder: (context, index) {
              final n = notifications[index];
              final color = _colorForType(n.type);
              final icon = _iconForType(n.type);

              return Dismissible(
                key: ValueKey(n.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: AppColors.error,
                  child: const Icon(Icons.delete_outline, color: Colors.white),
                ),
                onDismissed: (_) {
                  NotificationService.deleteNotification(n.id, _userId);
                },
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.12),
                    child: Icon(icon, color: color, size: 20),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          n.title,
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: n.isRead
                                ? FontWeight.w500
                                : FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        _formatTime(n.timestamp),
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      n.body,
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        color: n.isRead
                            ? Colors.grey.shade600
                            : Colors.grey.shade800,
                      ),
                    ),
                  ),
                  trailing: !n.isRead
                      ? Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                  onTap: () => _openNotification(n),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
