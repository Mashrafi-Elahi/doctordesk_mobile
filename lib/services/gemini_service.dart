import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

class GeminiSymptomResult {
  final String explanation;
  final String? recommendedSpecialty;
  final bool isOffTopic;

  const GeminiSymptomResult({
    required this.explanation,
    this.recommendedSpecialty,
    this.isOffTopic = false,
  });
}

class GeminiService {
  static String? _cachedApiKey;

  static Future<String> _getApiKey() async {
    if (_cachedApiKey != null && _cachedApiKey!.isNotEmpty) {
      return _cachedApiKey!;
    }
    const envDefine = String.fromEnvironment('GEMINI_API_KEY');
    if (envDefine.isNotEmpty) {
      _cachedApiKey = envDefine;
      return _cachedApiKey!;
    }
    try {
      final envContent = await rootBundle.loadString('.env');
      for (final rawLine in envContent.split('\n')) {
        final line = rawLine.trim();
        if (line.startsWith('GEMINI_API_KEY=')) {
          _cachedApiKey = line.substring('GEMINI_API_KEY='.length).trim();
          return _cachedApiKey!;
        }
      }
    } catch (e) {
      debugPrint('Could not load .env asset: $e');
    }
    return '';
  }

  // gemini-2.5-flash is retired for new API keys (404 NOT_FOUND). The lite
  // model answers in a few seconds; gemini-3.8-flash is the backup but often
  // needs over 30 s, so it only runs if the lite model fails.
  static const List<String> _models = [
    'gemini-2.5-flash-lite',
    'gemini-3.8-flash',
  ];

  static const String _systemPrompt = '''
You are a clinical symptom triage assistant for DoctorDesk (Bangladesh healthcare network).
STRICT RULES:
1. You ONLY answer queries about health symptoms, medical conditions, and doctor recommendations.
2. If the user asks anything unrelated to health, symptoms, or medical triage, respond EXACTLY:
"I am the DoctorDesk Symptom Assistant and can only answer questions related to medical symptoms and specialist doctor recommendations."
3. For medical symptoms:
   - Provide a concise, clear explanation (2 to 3 sentences maximum).
   - If red flags or urgent risks exist, briefly mention them.
   - At the very end of your response, on a new line, write:
     RECOMMENDED_SPECIALTY: <SpecialtyName>
     where <SpecialtyName> is one of: Medicine, Cardiology, Neurology, Orthopedics, Pediatrics, Gynecology, ENT, Dermatology, Psychiatry, Ophthalmology, Gastroenterology, Surgery, Urology, Dental, Nephrology, Pulmonology, Endocrinology, Oncology, Rheumatology.
''';

  /// Evaluates user symptoms through Gemini API.
  /// Used ONLY when local rule-based matching yields no match.
  static Future<GeminiSymptomResult?> evaluateSymptoms(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    final apiKey = await _getApiKey();
    if (apiKey.isEmpty) return null;

    final requestBody = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': '$_systemPrompt\n\nPatient Query: $trimmed'}
          ]
        }
      ]
    });

    for (final model in _models) {
      try {
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
        );

        final response = await http.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'X-goog-api-key': apiKey,
          },
          body: requestBody,
        ).timeout(const Duration(seconds: 12));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final candidates = data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            final content = candidates[0]['content'];
            final parts = content?['parts'] as List?;
            if (parts != null && parts.isNotEmpty) {
              final text = parts[0]['text'] as String? ?? '';
              return _parseResult(text);
            }
          }
        } else if (response.statusCode == 503 || response.statusCode == 429) {
          debugPrint('Gemini model $model returned ${response.statusCode}, trying fallback model...');
          continue;
        } else {
          debugPrint('Gemini API error: ${response.statusCode} - ${response.body}');
        }
      } catch (e) {
        debugPrint('Gemini request exception for $model: $e');
      }
    }

    return null;
  }

  static GeminiSymptomResult _parseResult(String rawText) {
    String explanation = rawText.trim();
    String? specialty;
    bool isOffTopic = false;

    if (explanation.contains('can only answer questions related to medical symptoms') ||
        explanation.contains('I am the DoctorDesk Symptom Assistant')) {
      isOffTopic = true;
    }

    final regExp = RegExp(r'RECOMMENDED_SPECIALTY:\s*([A-Za-z /]+)', caseSensitive: false);
    final match = regExp.firstMatch(explanation);
    if (match != null) {
      specialty = match.group(1)?.trim();
      explanation = explanation.replaceAll(match.group(0)!, '').trim();
    }

    return GeminiSymptomResult(
      explanation: explanation,
      recommendedSpecialty: specialty,
      isOffTopic: isOffTopic,
    );
  }
}
