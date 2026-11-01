// trust_score.dart
//
// Generic score tiering — used for Doctor (and later Operator) trust scores.
// Doctor score reuses ratingAverage/ratingCount fields already on Doctor model.
//
// Red tier is deliberately harder to surface than green/yellow — a single
// hostile review must not be able to instantly tank someone's visible
// reputation. Green/yellow showing early is low-risk; red showing
// early is damaging, so it needs at least 5 reviews before red is shown.

import 'package:flutter/material.dart';

enum ScoreTier { notEnoughData, red, yellow, green }

class TrustScore {
  final double? ratingAverage; // 1-5 scale, null if zero reviews
  final int ratingCount;

  const TrustScore({required this.ratingAverage, required this.ratingCount});

  static const int minReviewsToShow = 3;    // below this: "not enough data yet"
  static const int minReviewsToShowRed = 5; // red specifically needs more evidence

  double? get scoreOutOf100 {
    if (ratingAverage == null) return null;
    return (ratingAverage! / 5.0) * 100;
  }

  ScoreTier get tier {
    final score = scoreOutOf100;
    if (score == null || ratingCount < minReviewsToShow) {
      return ScoreTier.notEnoughData;
    }
    if (score < 50) {
      // Extra evidence bar for the damaging tier — one bad-faith review
      // can't push this into visibly "red" on its own.
      return ratingCount >= minReviewsToShowRed ? ScoreTier.red : ScoreTier.notEnoughData;
    }
    if (score < 80) return ScoreTier.yellow;
    return ScoreTier.green;
  }
}

class ScoreBadge extends StatelessWidget {
  final TrustScore score;
  const ScoreBadge({super.key, required this.score});

  @override
  Widget build(BuildContext context) {
    final tier = score.tier;

    if (tier == ScoreTier.notEnoughData) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 6),
            Text(
              'New — not enough reviews yet',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      );
    }

    final Color color = switch (tier) {
      ScoreTier.green => const Color(0xFF16A34A),
      ScoreTier.yellow => const Color(0xFFD97706),
      ScoreTier.red => const Color(0xFFDC2626),
      ScoreTier.notEnoughData => Colors.grey,
    };

    final value = (score.scoreOutOf100 ?? 0) / 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_outlined, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              'Trust Score: ${score.scoreOutOf100!.round()} / 100',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '(${score.ratingCount} reviews)',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 140,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
      ],
    );
  }
}
