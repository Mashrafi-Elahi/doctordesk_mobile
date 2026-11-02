import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../theme/app_constants.dart';
import '../models/user_role.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';
import '../services/app_language.dart';
import '../widgets/user_avatar.dart';
import '../widgets/profile_avatar_button.dart';
import 'create_post_screen.dart';

String _publicName(String? value, {String fallback = 'Community member'}) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return fallback;
  if (trimmed.contains('@')) {
    final prefix = trimmed.split('@').first.trim();
    if (prefix.isNotEmpty) {
      return prefix[0].toUpperCase() + prefix.substring(1);
    }
    return fallback;
  }
  return trimmed;
}

/// Real-time Health Feed Screen
/// - Blended stream of clinical YouTube videos, health tips, and community Q&A.
/// - Role permissions:
///   * Doctors, Admins, Moderators: post videos, publish articles, answer questions.
///   * Patients & Operators: comment on any post and ask health questions.
///   * Admins & Moderators: moderate and delete posts.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  String _selectedFilter =
      'All'; // 'All' | 'Videos' | 'Articles' | 'Community Q&A'

  String? _mapFilterToType(String filter) {
    return switch (filter) {
      'Videos' => 'video',
      'Articles' => 'tip',
      'Community Q&A' => 'question',
      _ => null,
    };
  }

  /// Feed order: Relevant (default) or Newest.
  bool _newestFirst = false;

  /// "Relevant" without a real algorithm: videos and detailed, discussed,
  /// doctor-written or answered posts rank up; the score fades over ~2 days
  /// so fresh posts still surface.
  static double _relevance(Map<String, dynamic> d) {
    final created = (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime(2000);
    final ageHours = DateTime.now().difference(created).inMinutes / 60.0;
    var score = 0.0;
    if (d['type'] == 'video') score += 3;
    score += ((d['content'] ?? '').toString().length / 300).clamp(0, 3);
    score += ((d['commentsCount'] as num?) ?? 0) * 0.5;
    if (d['authorRole'] == 'doctor' || d['isBmdcVerified'] == true) score += 1.5;
    if (d['answer'] != null) score += 1;
    return score / (1 + ageHours / 48);
  }

  void _openCreatePost({String? initialType}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(initialType: initialType),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roles = AuthService.userRoles;
    final canPostMedia = roles.canPostVideo;
    final typeFilter = _mapFilterToType(_selectedFilter);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          tr('Health Feed & Q&A'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: const [
          ProfileAvatarButton(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => _openCreatePost(
          initialType: canPostMedia ? 'video' : 'question',
        ),
        icon:
            Icon(canPostMedia ? Icons.add_circle_outline : Icons.help_outline),
        label: Text(canPostMedia ? 'New Post' : 'Ask Question'),
      ),
      body: Column(
        children: [
          // Feed Category Filters
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            child: SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  ActionChip(
                    avatar: Icon(_newestFirst ? Icons.schedule : Icons.auto_awesome, size: 16),
                    label: Text(_newestFirst ? 'Newest' : 'Relevant'),
                    onPressed: () => setState(() => _newestFirst = !_newestFirst),
                  ),
                  const SizedBox(width: 8),
                  _buildFilterChip('All'),
                  const SizedBox(width: 8),
                  _buildFilterChip('Videos'),
                  const SizedBox(width: 8),
                  _buildFilterChip('Articles'),
                  const SizedBox(width: 8),
                  _buildFilterChip('Community Q&A'),
                  const SizedBox(width: 8),
                  _buildFilterChip('My posts'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),

          // Real-time Firestore Stream of Posts
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: DataService.feedPostsStream(typeFilter: typeFilter),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline,
                              size: 48, color: Colors.redAccent),
                          const SizedBox(height: 12),
                          Text('Failed to load feed: ${snapshot.error}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  );
                }

                final rawDocs = snapshot.data?.docs ?? [];
                final currentUid = AuthService.currentUser?.uid;
                final docs = _selectedFilter == 'My posts'
                    ? rawDocs
                        .where((doc) => doc.data()['userId'] == currentUid)
                        .toList()
                    : rawDocs.toList();
                if (!_newestFirst) {
                  docs.sort((a, b) => _relevance(b.data()).compareTo(_relevance(a.data())));
                }

                if (docs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _selectedFilter == 'Videos'
                                ? Icons.ondemand_video
                                : (_selectedFilter == 'Community Q&A'
                                    ? Icons.forum_outlined
                                    : Icons.feed_outlined),
                            size: 56,
                            color: Colors.grey[350],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _selectedFilter == 'Videos'
                                ? 'No health videos posted yet'
                                : (_selectedFilter == 'Community Q&A'
                                    ? 'No community questions yet'
                                    : 'Health feed is empty'),
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            canPostMedia
                                ? 'Tap the button below to share a clinical YouTube guide or article.'
                                : 'Ask a health question to receive answers from verified doctors.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 13),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: () => _openCreatePost(
                              initialType: canPostMedia ? 'video' : 'question',
                            ),
                            icon: Icon(canPostMedia
                                ? Icons.post_add
                                : Icons.help_outline),
                            label: Text(canPostMedia
                                ? 'Share First Post'
                                : 'Ask a Question'),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    await Future.delayed(const Duration(milliseconds: 300));
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final doc = docs[index];
                      final data = doc.data();
                      return _FeedCard(
                        postId: doc.id,
                        data: data,
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label) {
    final isSelected = _selectedFilter == label;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => _selectedFilter = label);
        }
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Feed Card Widget
// ─────────────────────────────────────────────────────────────────────────────

class _FeedCard extends StatelessWidget {
  final String postId;
  final Map<String, dynamic> data;

  const _FeedCard({
    required this.postId,
    required this.data,
  });

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp is Timestamp) {
      final dt = timestamp.toDate();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inHours < 1) return '${diff.inMinutes}m ago';
      if (diff.inDays < 1) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${dt.day}/${dt.month}/${dt.year}';
    }
    return 'Recently';
  }

  void _showAnswerDialog(BuildContext context) {
    final answerController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.verified, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Answer Health Inquiry', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Q: ${data['title'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: answerController,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText:
                    'Provide clinical answer, advice, and recommendations...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final text = answerController.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(ctx);
              try {
                await DataService.answerQuestion(
                  postId: postId,
                  answerContent: text,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Answer posted successfully!')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to submit answer: $e')),
                  );
                }
              }
            },
            child: const Text('Submit Answer'),
          ),
        ],
      ),
    );
  }

  void _openComments(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CommentsSheet(postId: postId),
    );
  }

  void _retractDoctorAnswer(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Retract Specialist Answer?'),
        content: const Text(
            'This will remove your medical answer from this health question.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Retract'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await DataService.deleteDoctorAnswer(postId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Doctor answer retracted.')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to retract answer: $e')),
          );
        }
      }
    }
  }

  void _confirmDelete(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Post?'),
        content: const Text(
            'This will remove the post and its comments from the health feed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await DataService.deleteFeedPost(postId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Post deleted')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final roles = AuthService.userRoles;
    final currentUid = AuthService.currentUser?.uid;

    final type = data['type'] as String? ?? 'tip';
    final title = data['title'] as String? ?? '';
    final content = data['content'] as String? ?? '';
    final youtubeUrl = data['youtubeUrl'] as String? ?? '';
    final authorName = _publicName(data['authorName'] as String?, fallback: 'Specialist');
    final authorRole = data['authorRole'] as String? ?? 'doctor';
    final authorUid = data['userId'] as String? ?? '';
    final isBmdcVerified = data['isBmdcVerified'] == true;
    final commentsCount = (data['commentsCount'] as int?) ?? 0;
    final answer = data['answer'] as Map<String, dynamic>?;

    final canDelete = roles.isAdmin ||
        roles.isModerator ||
        (currentUid != null && currentUid == authorUid);
    // Answers come from the portal you're in, not the roles you hold: a doctor
    // browsing as a patient must switch to the Doctor portal first.
    final active = AuthService.activeRole;
    final canAnswer = (roles.isDoctor && active == UserRole.doctor) ||
        (roles.isAdmin && active == UserRole.admin) ||
        (roles.isModerator && active != UserRole.patient);
    final mustSwitchToAnswer = !canAnswer && roles.isDoctor;
    final canRetractAnswer = (answer != null &&
            currentUid != null &&
            answer['authorUid'] == currentUid) ||
        roles.isAdmin ||
        roles.isModerator;

    final badgeColor = switch (authorRole) {
      'admin' => Colors.purple,
      'moderator' => Colors.deepOrange,
      'doctor' => Colors.blue,
      'operator' => Colors.amber.shade800,
      _ => Colors.teal,
    };

    final badgeLabel = switch (authorRole) {
      'admin' => 'Admin',
      'moderator' => 'Moderator',
      'doctor' => isBmdcVerified ? 'BMDC Verified Doctor' : 'Doctor Specialist',
      'operator' => 'Chamber Operator',
      _ => 'Patient Member',
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      elevation: 0.8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Author details & more menu
            Row(
              children: [
                UserAvatar(uid: authorUid, name: authorName, radius: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              authorName,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (currentUid != null && currentUid == authorUid)
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.blue.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text('You', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                            ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: badgeColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isBmdcVerified ||
                                    authorRole == 'doctor') ...[
                                  Icon(Icons.verified,
                                      size: 10, color: badgeColor),
                                  const SizedBox(width: 2),
                                ],
                                Text(
                                  badgeLabel,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: badgeColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatTimestamp(data['timestamp']),
                        style: TextStyle(color: Colors.grey[500], fontSize: 11),
                      ),
                    ],
                  ),
                ),
                if (canDelete)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (val) {
                      if (val == 'delete') _confirmDelete(context);
                    },
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline,
                                size: 18, color: Colors.red),
                            SizedBox(width: 8),
                            Text('Delete Post',
                                style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Post Title
            Text(
              title,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold, height: 1.3),
            ),
            if (content.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                content,
                style: TextStyle(
                    fontSize: 13.5, color: Colors.grey[800], height: 1.4),
              ),
            ],
            const SizedBox(height: 12),

            // Embedded Video (for video posts)
            if (type == 'video' && youtubeUrl.isNotEmpty) ...[
              _YoutubeFeedPlayer(youtubeUrl: youtubeUrl),
              const SizedBox(height: 12),
            ],

            // Attached Image (for health question/tip photo)
            if (data['imageUrl'] != null && data['imageUrl'].toString().isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  data['imageUrl'].toString(),
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Question Answer Box (for Q&A posts)
            if (type == 'question') ...[
              if (answer != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.verified,
                              size: 16, color: Colors.green),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Specialist Answer by ${answer['authorName'] ?? 'Doctor'}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5,
                                color: Colors.green.shade900,
                              ),
                            ),
                          ),
                          if (canRetractAnswer)
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 16, color: Colors.redAccent),
                              tooltip: 'Retract / Delete Answer',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _retractDoctorAnswer(context),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        answer['content'] ?? '',
                        style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade900,
                            height: 1.35),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ] else ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.amber.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.hourglass_empty,
                          size: 18, color: Colors.amber.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Awaiting verified doctor response...',
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.amber.shade900),
                        ),
                      ),
                      if (canAnswer)
                        FilledButton.tonal(
                          onPressed: () => _showAnswerDialog(context),
                          style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact),
                          child: const Text('Answer'),
                        )
                      else if (mustSwitchToAnswer)
                        Text('Switch to Doctor portal to answer',
                            style: TextStyle(fontSize: 11, color: Colors.amber.shade900)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],

            // Action Row: Comments & Interaction
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _openComments(context),
                  icon: const Icon(Icons.comment_outlined, size: 18),
                  label: Text(
                    commentsCount > 0 ? '$commentsCount Comments' : 'Comment',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Embedded YouTube Feed Player
// ─────────────────────────────────────────────────────────────────────────────

class _YoutubeFeedPlayer extends StatefulWidget {
  final String youtubeUrl;

  const _YoutubeFeedPlayer({required this.youtubeUrl});

  @override
  State<_YoutubeFeedPlayer> createState() => _YoutubeFeedPlayerState();
}

class _YoutubeFeedPlayerState extends State<_YoutubeFeedPlayer> {
  YoutubePlayerController? _controller;
  String? _videoId;

  @override
  void initState() {
    super.initState();
    _videoId = YoutubePlayer.convertUrlToId(widget.youtubeUrl);
    if (_videoId != null && _videoId!.isNotEmpty) {
      _controller = YoutubePlayerController(
        initialVideoId: _videoId!,
        flags: const YoutubePlayerFlags(
          autoPlay: false,
          mute: false,
          hideControls: false,
          enableCaption: true,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || _videoId == null) {
      return Container(
        height: 180,
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.ondemand_video, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Unable to load video link'),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: YoutubePlayer(
        controller: _controller!,
        showVideoProgressIndicator: true,
        progressIndicatorColor: Colors.redAccent,
        bottomActions: const [
          CurrentPosition(),
          ProgressBar(isExpanded: true),
          RemainingDuration(),
          PlaybackSpeedButton(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Comments Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _CommentsSheet extends StatefulWidget {
  final String postId;

  const _CommentsSheet({required this.postId});

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _commentController = TextEditingController();
  bool _isSending = false;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submitComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isSending = true);
    try {
      final user = AuthService.currentUser;
      final roles = AuthService.userRoles;
      final role = roles.isAdmin
          ? 'admin'
          : (roles.isModerator
              ? 'moderator'
              : (roles.isDoctor
                  ? 'doctor'
                  : (roles.isOperator ? 'operator' : 'patient')));

      await DataService.addPostComment(
        postId: widget.postId,
        comment: text,
        authorName: _publicName(user?.displayName),
        authorRole: role,
      );
      _commentController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to comment: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: mediaQuery.viewInsets.bottom,
      ),
      child: SizedBox(
        height: mediaQuery.size.height * 0.65,
        child: Column(
          children: [
            // Sheet handle
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.chat_bubble_outline, size: 20),
                  SizedBox(width: 8),
                  Text('Comments',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
            ),
            const Divider(height: 1),

            // Live Comments Stream
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: DataService.postCommentsStream(widget.postId),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final docs = snapshot.data?.docs ?? [];
                  if (docs.isEmpty) {
                    return Center(
                      child: Text('No comments yet. Start the discussion!',
                          style:
                              TextStyle(color: Colors.grey[500], fontSize: 13)),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final c = docs[index].data();
                      final author = _publicName(c['authorName'] as String?, fallback: 'User');
                      final commentText = c['comment'] as String? ?? '';
                      final role = c['authorRole'] as String? ?? 'patient';

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            UserAvatar(
                              uid: c['userId'] as String?,
                              name: author,
                              radius: 14,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          author,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12),
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.blue.shade50,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            role,
                                            style: TextStyle(
                                                fontSize: 9,
                                                color: Colors.blue.shade800),
                                          ),
                                        ),
                                        const Spacer(),
                                        if ((c['userId'] != null &&
                                                c['userId'] ==
                                                    AuthService
                                                        .currentUser?.uid) ||
                                            AuthService.userRoles.isAdmin ||
                                            AuthService.userRoles.isModerator)
                                          IconButton(
                                            icon: Icon(Icons.delete_outline,
                                                size: 15,
                                                color: Colors.red.shade400),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                            tooltip: 'Delete comment',
                                            onPressed: () async {
                                              final commentId = docs[index].id;
                                              await DataService.deletePostComment(
                                                  widget.postId, commentId);
                                            },
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(commentText,
                                        style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),

            // Comment text input bar
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _commentController,
                        decoration: InputDecoration(
                          hintText: 'Add a comment...',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _isSending ? null : _submitComment,
                      icon: _isSending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.send, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
