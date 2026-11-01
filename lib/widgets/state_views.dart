import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_constants.dart';
import '../theme/app_theme.dart';

/// Shared loading / empty / error views so every role sees the same states.
/// Colours come from the active role theme.

class LoadingView extends StatelessWidget {
  final String? message;

  const LoadingView({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(message!, style: AppTheme.caption),
          ],
        ],
      ),
    );
  }
}

class EmptyStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: colors.primary),
            ),
            const SizedBox(height: 16),
            Text(title, style: AppTheme.sectionTitle, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: AppConstants.itemGap),
              Text(message!, style: AppTheme.body, textAlign: TextAlign.center),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class ErrorStateView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const ErrorStateView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  /// Builds the view from a raw error, mapping Firestore codes to plain words.
  factory ErrorStateView.fromError(Object? error,
      {Key? key, required VoidCallback onRetry, String what = 'data'}) {
    return ErrorStateView(
      key: key,
      message: friendlyErrorMessage(error, what: what),
      onRetry: onRetry,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: const BoxDecoration(
                color: Color(0xFFFFEBEE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cloud_off_outlined,
                  size: 36, color: AppColors.error),
            ),
            const SizedBox(height: 16),
            Text('Something went wrong',
                style: AppTheme.sectionTitle, textAlign: TextAlign.center),
            const SizedBox(height: AppConstants.itemGap),
            Text(message, style: AppTheme.body, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plain-language message for a Firestore / network error.
String friendlyErrorMessage(Object? error, {String what = 'data'}) {
  final raw = error?.toString() ?? '';
  if (raw.contains('permission-denied') || raw.contains('PERMISSION_DENIED')) {
    return 'You don\'t have permission to see $what. Check that you are '
        'signed in with the right account.';
  }
  if (raw.contains('FAILED_PRECONDITION') || raw.contains('requires an index')) {
    return 'This view needs a Firestore index that isn\'t deployed yet '
        '(firebase deploy --only firestore:indexes).';
  }
  if (raw.contains('unavailable') || raw.contains('network') ||
      raw.contains('SocketException')) {
    return 'Couldn\'t reach the server. Check your internet connection.';
  }
  return kDebugMode ? 'Couldn\'t load $what.\n$raw' : 'Couldn\'t load $what.';
}
