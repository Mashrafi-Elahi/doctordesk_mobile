import 'package:flutter/material.dart';
import '../services/tts_service.dart';
import '../theme/app_constants.dart';
import '../theme/app_theme.dart';

/// Reusable SwitchListTile for global Read Aloud setting across all role settings screens.
class ReadAloudSettingTile extends StatelessWidget {
  const ReadAloudSettingTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: TtsService.instance.isReadAloudEnabled,
      builder: (context, isEnabled, _) {
        return SwitchListTile.adaptive(
          secondary: Icon(
            isEnabled ? Icons.volume_up : Icons.volume_up_outlined,
            color: isEnabled ? Theme.of(context).colorScheme.primary : AppColors.textSecondary,
          ),
          title: Text(
            'Read Aloud',
            style: AppTheme.bodyBold,
          ),
          subtitle: Text(
            'Tap any item to hear it. Double-tap to open',
            style: AppTheme.caption,
          ),
          value: isEnabled,
          activeTrackColor: Theme.of(context).colorScheme.primary,
          onChanged: (val) {
            TtsService.instance.setReadAloud(val);
          },
        );
      },
    );
  }
}
