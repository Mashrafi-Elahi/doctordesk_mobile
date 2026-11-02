import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';

/// Screen for creating feed posts:
/// - Doctors, Admins, and Moderators can post YouTube video guides, tips, and clinical advisories.
/// - Patients and Operators can submit health questions to be answered by specialists.
class CreatePostScreen extends StatefulWidget {
  final String? initialType; // 'video' | 'tip' | 'question'

  const CreatePostScreen({super.key, this.initialType});

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _youtubeUrlController = TextEditingController();

  late String _selectedType;
  bool _isSubmitting = false;


  YoutubePlayerController? _previewController;
  String? _previewVideoId;

  @override
  void initState() {
    super.initState();
    final roles = AuthService.userRoles;
    if (widget.initialType != null) {
      _selectedType = widget.initialType!;
    } else if (roles.canPostVideo) {
      _selectedType = 'video';
    } else {
      _selectedType = 'question';
    }

    _youtubeUrlController.addListener(_onUrlChanged);
  }

  void _onUrlChanged() {
    final text = _youtubeUrlController.text.trim();
    final videoId = YoutubePlayer.convertUrlToId(text);
    if (videoId != _previewVideoId) {
      setState(() {
        _previewVideoId = videoId;
        _previewController?.dispose();
        if (videoId != null && videoId.isNotEmpty) {
          _previewController = YoutubePlayerController(
            initialVideoId: videoId,
            flags: const YoutubePlayerFlags(
              autoPlay: false,
              mute: false,
              hideControls: false,
            ),
          );
        } else {
          _previewController = null;
        }
      });
    }
  }

  @override
  void dispose() {
    _youtubeUrlController.removeListener(_onUrlChanged);
    _youtubeUrlController.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _previewController?.dispose();
    super.dispose();
  }

  Future<void> _submitPost() async {
    final roles = AuthService.userRoles;

    if (_selectedType == 'video' && !roles.canPostVideo) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only registered doctors, moderators, and admins can post clinical videos.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    if (_selectedType == 'video') {
      final url = _youtubeUrlController.text.trim();
      final id = YoutubePlayer.convertUrlToId(url);
      if (id == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a valid YouTube video URL (e.g. https://youtu.be/... or youtube.com/watch?v=...)'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    }

    setState(() => _isSubmitting = true);

    try {
      final user = AuthService.currentUser;
      final role = roles.isAdmin
          ? 'admin'
          : (roles.isModerator
              ? 'moderator'
              : (roles.isDoctor ? 'doctor' : (roles.isOperator ? 'operator' : 'patient')));

      await DataService.createFeedPost(
        type: _selectedType,
        title: _titleController.text.trim(),
        content: _contentController.text.trim(),
        youtubeUrl: _selectedType == 'video' ? _youtubeUrlController.text.trim() : null,
        authorName: user?.displayName ?? (roles.isDoctor ? 'Dr. Specialist' : 'Community Member'),
        authorRole: role,
        isBmdcVerified: roles.isDoctor,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_selectedType == 'video'
                ? 'YouTube video posted to health feed!'
                : (_selectedType == 'question'
                    ? 'Question submitted! Specialists will answer shortly.'
                    : 'Health tip published!')),
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to publish post: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roles = AuthService.userRoles;
    final canPostMedia = roles.canPostVideo;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectedType == 'video'
              ? 'Share Health Video'
              : (_selectedType == 'question' ? 'Ask Doctor a Question' : 'Post Health Tip'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Post Type Selector
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'video',
                    label: const Text('Video'),
                    icon: const Icon(Icons.ondemand_video, size: 18),
                    enabled: canPostMedia,
                  ),
                  ButtonSegment(
                    value: 'tip',
                    label: const Text('Clinical Tip'),
                    icon: const Icon(Icons.article_outlined, size: 18),
                    enabled: canPostMedia,
                  ),
                  const ButtonSegment(
                    value: 'question',
                    label: Text('Ask Doctor'),
                    icon: Icon(Icons.help_outline, size: 18),
                  ),
                ],
                selected: {_selectedType},
                onSelectionChanged: (newSelection) {
                  setState(() {
                    _selectedType = newSelection.first;
                  });
                },
              ),
              const SizedBox(height: 12),

              // Informational badge about permissions
              if (!canPostMedia)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Patients and operators can ask health questions and comment. Video posting and answering FAQs are reserved for BMDC-verified doctors and moderators.',
                          style: TextStyle(fontSize: 12, color: Colors.blue.shade900),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),

              // YouTube URL Input (Only for Video type)
              if (_selectedType == 'video') ...[
                TextFormField(
                  controller: _youtubeUrlController,
                  decoration: InputDecoration(
                    labelText: 'YouTube Video Link',
                    hintText: 'https://youtu.be/... or https://youtube.com/watch?v=...',
                    prefixIcon: const Icon(Icons.link, color: Colors.redAccent),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    suffixIcon: _youtubeUrlController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => _youtubeUrlController.clear(),
                          )
                        : null,
                  ),
                  validator: (value) {
                    if (_selectedType == 'video' && (value == null || value.trim().isEmpty)) {
                      return 'Please enter a YouTube video URL';
                    }
                    if (YoutubePlayer.convertUrlToId(value!.trim()) == null) {
                      return 'Invalid YouTube link format';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                // Live Preview Player
                if (_previewController != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: YoutubePlayer(
                      controller: _previewController!,
                      showVideoProgressIndicator: true,
                      progressIndicatorColor: Colors.redAccent,
                      bottomActions: const [
                        CurrentPosition(),
                        ProgressBar(isExpanded: true),
                        RemainingDuration(),
                        PlaybackSpeedButton(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],

              // Post Title / Question Field
              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: _selectedType == 'question'
                      ? 'Your Health Question or Symptom'
                      : 'Title / Clinical Topic',
                  hintText: _selectedType == 'question'
                      ? 'e.g. Sudden knee pain during morning walk — what should I do?'
                      : 'e.g. Managing Hypertension During Winter: Specialist Advice',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Title cannot be empty';
                  }
                  if (value.trim().length < 5) {
                    return 'Title must be at least 5 characters';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Content / Description / Clinical Notes
              TextFormField(
                controller: _contentController,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: _selectedType == 'question'
                      ? 'Detailed Symptoms & Medical History (Optional)'
                      : 'Article Body / Health Guidance / Advice',
                  hintText: _selectedType == 'question'
                      ? 'Describe your duration, severity, and any medications taken...'
                      : 'Write clear, patient-friendly guidance and recommendations...',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 16),

              const SizedBox(height: 24),

              // Submit Button
              FilledButton.icon(
                onPressed: _isSubmitting ? null : _submitPost,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(_selectedType == 'video'
                        ? Icons.cloud_upload_outlined
                        : (_selectedType == 'question' ? Icons.send : Icons.publish)),
                label: Text(
                  _isSubmitting
                      ? 'Publishing...'
                      : (_selectedType == 'video'
                          ? 'Post Video to Feed'
                          : (_selectedType == 'question' ? 'Submit Question' : 'Publish Tip')),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
