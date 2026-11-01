import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_constants.dart';
import '../models/chat_message.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/document_service.dart';
import '../widgets/health_documents_widget.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String otherUserName;
  final String? otherUserRole;
  final String otherUserUid;
  final bool isDoctor;
  final bool isOperator;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.otherUserName,
    this.otherUserRole,
    required this.otherUserUid,
    this.isDoctor = false,
    this.isOperator = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    final myUid = AuthService.currentUser?.uid;
    final myName = AuthService.currentUser?.displayName ??
        (widget.isDoctor ? 'Doctor' : (widget.isOperator ? 'Clinic Desk Operator' : 'Patient'));
    if (myUid == null) return;

    setState(() => _isSending = true);
    _messageController.clear();

    try {
      await ChatService.sendMessage(
        chatId: widget.chatId,
        senderUid: myUid,
        otherUid: widget.otherUserUid,
        text: text,
        senderName: myName,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send message: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _attachDocument(HealthDocument doc) async {
    final myUid = AuthService.currentUser?.uid;
    final myName = AuthService.currentUser?.displayName ?? 'Patient';
    if (myUid == null) return;

    setState(() => _isSending = true);
    try {
      await DocumentService.attachFileToChat(
        chatId: widget.chatId,
        senderUid: myUid,
        senderName: myName,
        otherUid: widget.otherUserUid,
        doc: doc,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Attached "${doc.title}" successfully.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Attachment failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _showAttachmentPicker() async {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.folder_shared_outlined, color: Theme.of(context).colorScheme.primary),
                title: const Text('Attach from Health Documents'),
                subtitle: const Text('Choose a local prescription, scan, or report'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _openLocalDocumentsDialog();
                },
              ),
              ListTile(
                leading: Icon(Icons.camera_alt_outlined, color: Theme.of(context).colorScheme.primary),
                title: const Text('Take Photo & Attach'),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  final doc = await DocumentService.pickAndSaveImage(
                    title: 'Photo ${DateTime.now().toIso8601String().split("T")[0]}',
                    category: 'Prescriptions',
                    date: DateTime.now(),
                    fromCamera: true,
                  );
                  if (doc != null) {
                    await _attachDocument(doc);
                  }
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_library_outlined, color: Theme.of(context).colorScheme.primary),
                title: const Text('Choose from Gallery & Attach'),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  final doc = await DocumentService.pickAndSaveImage(
                    title: 'Image ${DateTime.now().toIso8601String().split("T")[0]}',
                    category: 'Other',
                    date: DateTime.now(),
                    fromCamera: false,
                  );
                  if (doc != null) {
                    await _attachDocument(doc);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openLocalDocumentsDialog() {
    showDialog(
      context: context,
      builder: (dialogCtx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: double.maxFinite,
          height: 520,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Select Document to Attach', style: TextStyle(fontSize: 15)),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(dialogCtx)),
              ],
            ),
            body: HealthDocumentsWidget(
              isPickerMode: true,
              onSelectDocument: (doc) {
                Navigator.pop(dialogCtx);
                _attachDocument(doc);
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRevokeAttachment(String messageId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Shared File?'),
        content: const Text(
          'Revoking this file will disable access for the recipient immediately.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revoke Share'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ChatService.revokeAttachment(chatId: widget.chatId, messageId: messageId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Attachment revoked.')),
        );
      }
    }
  }

  Future<void> _confirmCloseChat() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close Conversation?'),
        content: const Text(
          'Closing the conversation will end this follow-up chat session and lock further messaging.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Close Conversation'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ChatService.closeChat(widget.chatId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Conversation closed successfully.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = AuthService.currentUser?.uid;

    return StreamBuilder<ChatSession?>(
      stream: ChatService.streamChatSession(widget.chatId),
      builder: (context, sessionSnap) {
        final session = sessionSnap.data;
        final isClosed = session?.status == 'closed';
        final isExpired = session?.isExpired ?? false;
        final isLimitReached = session?.isLimitReached ?? false;
        final canSend = session == null || session.canSendMessage;
        final remaining = session != null
            ? (session.messageLimit - session.messageCount).clamp(0, session.messageLimit)
            : 20;

        final canClose = (widget.isDoctor || widget.isOperator) && !isClosed;

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.otherUserName,
                  style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                Text(
                  widget.otherUserRole ?? (widget.isDoctor ? 'Patient' : 'Consultation'),
                  style: GoogleFonts.poppins(fontSize: 11, color: Colors.white.withValues(alpha: 0.8)),
                ),
              ],
            ),
            actions: [
              if (canClose)
                IconButton(
                  icon: const Icon(Icons.lock_clock_outlined, color: Colors.white),
                  tooltip: 'Close Conversation',
                  onPressed: _confirmCloseChat,
                ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                // Medical Disclaimer Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    border: Border(bottom: BorderSide(color: Colors.amber.shade200)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 18, color: Colors.amber.shade900),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Not for emergency medical conditions. In life-threatening emergencies, call 999 or visit the nearest ER immediately.',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: Colors.amber.shade900,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Status Banner
                if (isClosed)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Colors.red.shade50,
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline, size: 16, color: Colors.red.shade800),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Conversation closed. Direct messaging is disabled.',
                            style: TextStyle(fontSize: 11.5, color: Colors.red.shade800, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (isExpired)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Colors.orange.shade50,
                    child: const Row(
                      children: [
                        Icon(Icons.timer_off_outlined, size: 16, color: Color(0xFF78350F)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Care follow-up window has expired (7 days). Messaging is disabled.',
                            style: TextStyle(fontSize: 11.5, color: Color(0xFF78350F), fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (isLimitReached)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Colors.orange.shade50,
                    child: Row(
                      children: [
                        const Icon(Icons.chat_bubble_outline, size: 16, color: Color(0xFF78350F)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Message limit reached (${session?.messageLimit}/${session?.messageLimit}). Messaging is locked.',
                            style: const TextStyle(fontSize: 11.5, color: Color(0xFF78350F), fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    color: const Color(0xFFF0FDF4),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_outline, size: 15, color: Color(0xFF16A34A)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Active Conversation • $remaining messages remaining • ${session?.expiresAt != null ? "Closes on ${session!.expiresAt!.day}/${session.expiresAt!.month}" : "Active"}',
                            style: const TextStyle(fontSize: 11, color: Color(0xFF15803D), fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Messages Stream
                Expanded(
                  child: StreamBuilder<List<ChatMessage>>(
                    stream: ChatService.streamMessages(widget.chatId),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final messages = snapshot.data ?? [];
                      if (messages.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                Text(
                                  'Secure Follow-up Chat',
                                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.grey.shade700),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'You can send follow-up questions and attach health documents.',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.poppins(fontSize: 13, color: Colors.grey.shade500),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      return ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final msg = messages[index];
                          final isMe = msg.senderUid == myUid;
                          final hasAttachment = msg.hasAttachment;

                          return Align(
                            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: isMe ? Theme.of(context).colorScheme.primary : Colors.grey.shade100,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                                  bottomRight: Radius.circular(isMe ? 4 : 16),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                children: [
                                  if (msg.text.isNotEmpty)
                                    Text(
                                      msg.text,
                                      style: GoogleFonts.poppins(
                                        fontSize: 14,
                                        color: isMe ? Colors.white : Colors.black87,
                                      ),
                                    ),

                                  // Attachment Widget
                                  if (hasAttachment) ...[
                                    const SizedBox(height: 8),
                                    if (msg.isRevoked)
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: isMe ? Colors.white24 : Colors.grey.shade200,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.block, size: 16, color: isMe ? Colors.white70 : Colors.red),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Removed by sender',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontStyle: FontStyle.italic,
                                                color: isMe ? Colors.white70 : Colors.grey.shade700,
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    else if (msg.isShareExpired)
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: isMe ? Colors.white24 : Colors.grey.shade200,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.timer_off_outlined, size: 16, color: isMe ? Colors.white70 : Colors.orange),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Attachment expired (30-day limit)',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontStyle: FontStyle.italic,
                                                color: isMe ? Colors.white70 : Colors.grey.shade700,
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    else if (msg.inlineId != null)
                                      _InlineImageAttachment(
                                        chatId: widget.chatId,
                                        attachmentId: msg.inlineId!,
                                        title: msg.fileName ?? 'Photo',
                                        isMe: isMe,
                                        onRevoke: isMe ? () => _confirmRevokeAttachment(msg.id) : null,
                                      )
                                    else
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: isMe ? Colors.white.withValues(alpha: 0.15) : Colors.white,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: isMe ? Colors.white30 : Colors.grey.shade300),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  msg.mimeType == 'application/pdf' ? Icons.picture_as_pdf : Icons.image,
                                                  color: isMe ? Colors.white : Theme.of(context).colorScheme.primary,
                                                  size: 20,
                                                ),
                                                const SizedBox(width: 8),
                                                Flexible(
                                                  child: Text(
                                                    msg.fileName ?? 'Document',
                                                    style: TextStyle(
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 13,
                                                      color: isMe ? Colors.white : Colors.black87,
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${msg.fileCategory ?? "Document"} • ${msg.sizeBytes != null ? (msg.sizeBytes! / 1024).toStringAsFixed(0) : "0"} KB',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: isMe ? Colors.white70 : Colors.grey.shade600,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                InkWell(
                                                  onTap: () async {
                                                    final url = msg.fileUrl;
                                                    if (url != null && url.isNotEmpty) {
                                                      final uri = Uri.parse(url);
                                                      if (await canLaunchUrl(uri)) {
                                                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                                                      }
                                                    }
                                                  },
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                    decoration: BoxDecoration(
                                                      color: isMe ? Colors.white : Theme.of(context).colorScheme.primary,
                                                      borderRadius: BorderRadius.circular(8),
                                                    ),
                                                    child: Text(
                                                      'View / Download',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.w600,
                                                        color: isMe ? Theme.of(context).colorScheme.primary : Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                if (isMe) ...[
                                                  const SizedBox(width: 8),
                                                  InkWell(
                                                    onTap: () => _confirmRevokeAttachment(msg.id),
                                                    child: Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                      decoration: BoxDecoration(
                                                        color: Colors.red.withValues(alpha: 0.2),
                                                        borderRadius: BorderRadius.circular(8),
                                                      ),
                                                      child: const Text(
                                                        'Revoke Share',
                                                        style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],

                                  const SizedBox(height: 4),
                                  Text(
                                    '${msg.createdAt.hour > 12 ? msg.createdAt.hour - 12 : (msg.createdAt.hour == 0 ? 12 : msg.createdAt.hour)}:${msg.createdAt.minute.toString().padLeft(2, "0")} ${msg.createdAt.hour >= 12 ? "PM" : "AM"}',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: isMe ? Colors.white.withValues(alpha: 0.7) : Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),

                // Input Bar
                if (canSend)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border(top: BorderSide(color: Colors.grey.shade200)),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(Icons.attach_file, color: Theme.of(context).colorScheme.primary),
                          tooltip: 'Attach Document',
                          onPressed: _showAttachmentPicker,
                        ),
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            textCapitalization: TextCapitalization.sentences,
                            maxLines: 4,
                            minLines: 1,
                            decoration: InputDecoration(
                              hintText: 'Type your message...',
                              hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide(color: Colors.grey.shade300),
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _isSending ? null : _sendMessage,
                          icon: _isSending
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : const Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A photo stored inline in Firestore. Loaded only when its bubble is built,
/// never as part of the message list query.
class _InlineImageAttachment extends StatelessWidget {
  const _InlineImageAttachment({
    required this.chatId,
    required this.attachmentId,
    required this.title,
    required this.isMe,
    this.onRevoke,
  });

  final String chatId;
  final String attachmentId;
  final String title;
  final bool isMe;
  final VoidCallback? onRevoke;

  void _openFull(BuildContext context, Uint8List bytes) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(title, style: const TextStyle(fontSize: 15)),
        ),
        body: Center(
          child: InteractiveViewer(maxScale: 5, child: Image.memory(bytes)),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final muted = isMe ? Colors.white70 : Colors.grey.shade600;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FutureBuilder<Uint8List?>(
          future: ChatService.loadInlineImage(chatId, attachmentId),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                width: 200,
                height: 150,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            final bytes = snap.data;
            if (bytes == null) {
              return Text('Photo unavailable',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: muted));
            }
            return Semantics(
              label: 'Photo: $title. Tap to open.',
              child: GestureDetector(
                onTap: () => _openFull(context, bytes),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(bytes, width: 220, height: 220, fit: BoxFit.cover, gaplessPlayback: true),
                ),
              ),
            );
          },
        ),
        if (onRevoke != null)
          TextButton.icon(
            onPressed: onRevoke,
            style: TextButton.styleFrom(foregroundColor: isMe ? Colors.white : Colors.red),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Unsend photo', style: TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}
