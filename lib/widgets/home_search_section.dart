// home_search_section.dart (v2 — matches specialty_matcher.dart v2 + feedback loop)
//
// Requires: SpecialtyMatcher.load() already awaited once at app startup
// (e.g. in main() before runApp, or in a splash/loading screen). This widget
// does NOT call load() itself — don't duplicate that call here.

import 'package:flutter/material.dart';
import '../services/specialty_matcher.dart';
import '../screens/health_chat_screen.dart';
import 'specialty_feedback_widget.dart';

class HomeSearchSection extends StatefulWidget {
  final void Function(String query) onSearch;
  final Future<void> Function({
    required String inputText,
    required String matchedSpecialty,
    required String source,
    required bool liked,
  }) onSubmitFeedback; // wire to ApiService.submitSpecialtyFeedback

  const HomeSearchSection({
    super.key,
    required this.onSearch,
    required this.onSubmitFeedback,
  });

  @override
  State<HomeSearchSection> createState() => _HomeSearchSectionState();
}

class _HomeSearchSectionState extends State<HomeSearchSection> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _symptomController = TextEditingController();
  String _ghostSuggestion = '';
  bool _panelOpen = false;

  // Result of the last symptom match — drives the suggestion card + feedback row.
  MatchResult? _lastMatch;
  String _lastMatchedInput = '';

  static const List<String> quickPicks = [
    'General Physician', 'Gynecologist', 'Pediatrician', 'Dermatologist',
    'Cardiologist', 'Psychiatrist', 'Orthopedist', 'ENT Specialist', 'Dentist', 'Neurologist',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    _symptomController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    final match = quickPicks.firstWhere(
      (s) => value.isNotEmpty && s.toLowerCase().startsWith(value.toLowerCase()),
      orElse: () => '',
    );
    setState(() => _ghostSuggestion = match);
    widget.onSearch(value);
  }

  void _acceptGhostSuggestion() {
    if (_ghostSuggestion.isEmpty) return;
    _searchController.text = _ghostSuggestion;
    _searchController.selection = TextSelection.fromPosition(
      TextPosition(offset: _ghostSuggestion.length),
    );
    final accepted = _ghostSuggestion;
    setState(() => _ghostSuggestion = '');
    widget.onSearch(accepted);
  }

  void _onSymptomChanged(String value) {
    if (value.trim().isEmpty) {
      setState(() => _lastMatch = null);
      return;
    }
    final result = SpecialtyMatcher.match(value);
    setState(() {
      _lastMatch = result;
      _lastMatchedInput = value;
    });
  }

  void _acceptMatch(String specialty) {
    _searchController.text = specialty;
    widget.onSearch(specialty);
    setState(() => _panelOpen = false);
    // Suggestion card + feedback row stay visible via _lastMatch until
    // symptom field is cleared — user can still vote after navigating results.
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- Ghost-text search bar ---
        Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(fontSize: 16, color: Colors.black),
                      children: [
                        TextSpan(text: _searchController.text),
                        if (_ghostSuggestion.isNotEmpty &&
                            _ghostSuggestion.length > _searchController.text.length)
                          TextSpan(
                            text: _ghostSuggestion.substring(_searchController.text.length),
                            style: const TextStyle(color: Colors.grey),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _acceptGhostSuggestion(),
              style: const TextStyle(fontSize: 16, color: Colors.transparent),
              cursorColor: Colors.black,
              decoration: InputDecoration(
                hintText: _searchController.text.isEmpty
                    ? 'Search by name, specialty, hospital, or location'
                    : null,
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _ghostSuggestion.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        onPressed: _acceptGhostSuggestion,
                        tooltip: 'Accept suggestion',
                      )
                    : const Icon(Icons.search),
              ),
            ),
          ],
        ),

        // --- "Not sure which specialist?" trigger ---
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: GestureDetector(
            onTap: () => setState(() => _panelOpen = !_panelOpen),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_panelOpen ? Icons.expand_less : Icons.help_outline,
                    size: 16, color: Colors.blueGrey),
                const SizedBox(width: 4),
                Text('Not sure which specialist?',
                    style: TextStyle(fontSize: 13, color: Colors.blueGrey.shade700)),
              ],
            ),
          ),
        ),

        // --- Expandable panel ---
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: _panelOpen
              ? Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _symptomController,
                        onChanged: _onSymptomChanged,
                        decoration: InputDecoration(
                          hintText: 'Describe your symptoms or health concern',
                          hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),

                      // --- Suggestion card (only shown once a match exists) ---
                      if (_lastMatch != null && _lastMatch!.topSpecialty != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              GestureDetector(
                                onTap: () => _acceptMatch(_lastMatch!.topSpecialty!),
                                child: Text.rich(
                                  TextSpan(
                                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                                    children: [
                                      const TextSpan(text: 'Sounds like you need a '),
                                      TextSpan(
                                        text: _lastMatch!.topSpecialty,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                      const TextSpan(text: '. Tap to show doctors →'),
                                    ],
                                  ),
                                ),
                              ),
                              if (_lastMatch!.isVague && _lastMatch!.alternatives.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  children: _lastMatch!.alternatives
                                      .where((s) => s != _lastMatch!.topSpecialty)
                                      .map((s) => ActionChip(
                                            label: Text(s, style: const TextStyle(fontSize: 11)),
                                            onPressed: () => _acceptMatch(s),
                                          ))
                                      .toList(),
                                ),
                              ],
                              // Feedback loop — source is 'rule_based' here; the Gemini
                              // fallback path (separate screen/call) passes source: 'gemini'.
                              SpecialtyFeedbackRow(
                                inputText: _lastMatchedInput,
                                matchedSpecialty: _lastMatch!.topSpecialty!,
                                source: 'symptom_ai',
                                onSubmitFeedback: widget.onSubmitFeedback,
                              ),
                            ],
                          ),
                        ),
                      ] else if (_symptomController.text.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'No local match found. Ask DoctorDesk AI?',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const HealthChatScreen()),
                                );
                              },
                              icon: const Icon(Icons.auto_awesome, size: 16),
                              label: const Text('Ask AI'),
                            ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 10),
                      const Text('Or pick a common specialty:',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: quickPicks.map((s) {
                          return ActionChip(
                            label: Text(s, style: const TextStyle(fontSize: 12)),
                            backgroundColor: Colors.white,
                            onPressed: () => _acceptMatch(s),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
