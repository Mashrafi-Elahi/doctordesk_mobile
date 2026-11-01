import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../theme/app_constants.dart';
import '../services/data_service.dart';
import '../services/verification_provider.dart';

class BmdcVerificationScreen extends StatefulWidget {
  final String doctorId;
  final String doctorName;
  final String bmdcNumber;
  final String currentStatus;

  const BmdcVerificationScreen({
    super.key,
    required this.doctorId,
    required this.doctorName,
    required this.bmdcNumber,
    this.currentStatus = 'unverified',
  });

  @override
  State<BmdcVerificationScreen> createState() => _BmdcVerificationScreenState();
}

class _BmdcVerificationScreenState extends State<BmdcVerificationScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _isUpdating = false;
  final VerificationProvider _verificationProvider =
      const ManualVerificationProvider();

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (mounted) setState(() => _isLoading = true);
          },
          onPageFinished: (url) {
            if (mounted) setState(() => _isLoading = false);
            _injectBmdcNumber();
          },
        ),
      )
      ..loadRequest(Uri.parse('https://verify.bmdc.org.bd/'));
  }

  void _injectBmdcNumber() {
    final cleanNum = widget.bmdcNumber.trim();
    if (cleanNum.isEmpty) return;

    final js = '''
      (function() {
        try {
          const val = ${jsonEncode(cleanNum)};
          const inputs = Array.from(document.querySelectorAll('input[type="text"], input[name*="reg"], input[id*="reg"], input[name*="number"], input[placeholder*="Reg"], input[placeholder*="BMDC"], input[placeholder*="Registration"]'));
          let target = null;
          for (const el of inputs) {
            const attr = ((el.name || '') + ' ' + (el.id || '') + ' ' + (el.placeholder || '')).toLowerCase();
            if (attr.includes('reg') || attr.includes('bmdc') || attr.includes('number')) {
              target = el;
              break;
            }
          }
          if (!target && inputs.length > 0) target = inputs[0];
          if (target) {
            target.value = val;
            target.dispatchEvent(new Event('input', { bubbles: true }));
            target.dispatchEvent(new Event('change', { bubbles: true }));

            // The admin completes any search themselves. Never auto-submit a
            // third-party registry form or bypass its interaction controls.
          }
        } catch (e) {
          console.error('BMDC JS injection error:', e);
        }
      })();
    ''';

    _controller.runJavaScript(js);
  }

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.bmdcNumber.trim()));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('BMDC Number "${widget.bmdcNumber}" copied to clipboard!'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _recordOutcome(BmdcVerificationOutcome outcome) async {
    setState(() => _isUpdating = true);
    try {
      final result = _verificationProvider.recordOutcome(
        registrationNumber: widget.bmdcNumber,
        outcome: outcome,
      );
      await DataService.recordManualBmdcVerification(
        doctorId: widget.doctorId,
        registrationNumber: result.registrationNumber,
        outcome: result.outcome.value,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Manual BMDC outcome recorded: ${result.outcome.label}.'),
            backgroundColor: outcome == BmdcVerificationOutcome.found
                ? Colors.green
                : outcome == BmdcVerificationOutcome.mismatch
                    ? Colors.orange
                    : Colors.red,
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update status: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cleanBmdc = widget.bmdcNumber.trim();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.doctorName, style: const TextStyle(fontSize: 16)),
            Text(
              cleanBmdc.isNotEmpty ? 'BMDC: $cleanBmdc' : 'No BMDC Number',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          if (cleanBmdc.isNotEmpty)
            TextButton.icon(
              onPressed: _copyToClipboard,
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy Number'),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload Page',
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading)
            const LinearProgressIndicator(minHeight: 3),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 8,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.search_off_outlined, size: 18),
                      label: const Text('Not found'),
                      onPressed: _isUpdating
                          ? null
                          : () => _recordOutcome(BmdcVerificationOutcome.notFound),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange.shade800,
                        side: BorderSide(color: Colors.orange.shade800),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.compare_arrows_outlined, size: 18),
                      label: const Text('Mismatch'),
                      onPressed: _isUpdating
                          ? null
                          : () => _recordOutcome(BmdcVerificationOutcome.mismatch),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.success,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.verified, size: 18),
                      label: _isUpdating
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Found'),
                      onPressed: _isUpdating
                          ? null
                          : () => _recordOutcome(BmdcVerificationOutcome.found),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
