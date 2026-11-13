import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/auth_service.dart';
import '../../services/distribution_consent_service.dart';
import '../theme/colors.dart';

/// Restores an existing account using a fresh device link and its separate PIN.
/// No session is retained after sign-out and no replacement account is created.
class AccountLinkRecoveryDialog extends StatefulWidget {
  const AccountLinkRecoveryDialog({
    required this.client,
    required this.auth,
    super.key,
  });
  final SupabaseClient client;
  final IAuthService auth;

  @override
  State<AccountLinkRecoveryDialog> createState() =>
      _AccountLinkRecoveryDialogState();
}

class _AccountLinkRecoveryDialogState extends State<AccountLinkRecoveryDialog> {
  final _code = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _link() async {
    if (_busy) return;
    var token = _code.text.trim();
    try {
      if (token.startsWith('{')) {
        final payload = jsonDecode(token);
        token =
            payload is Map<String, Object?> && payload['link_token'] is String
            ? payload['link_token']! as String
            : '';
      }
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(token) ||
          !RegExp(r'^\d{6}$').hasMatch(_pin.text.trim())) {
        throw const FormatException('Invalid link code or PIN');
      }
    } on FormatException {
      setState(() => _error = 'Paste the link code and enter its 6-digit PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await widget.client.functions.invoke(
        'exchange-link-token',
        body: {'token': token, 'pin': _pin.text.trim()},
      );
      final data = response.data;
      final refresh = data is Map<String, Object?>
          ? data['refresh_token']
          : null;
      if (refresh is! String || refresh.isEmpty) {
        throw const FormatException('Missing session');
      }
      await widget.auth.signInWithRefreshToken(refresh);
      final prefs = await loadConsentPreferences();
      await prefs.setBool('distribution_cloud_paused', false);
      if (mounted) Navigator.of(context).pop(true);
    } on Exception {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              'Could not link. Check the PIN and connection, or generate a new link code on your signed-in device.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      backgroundColor: GhostColors.surface,
      title: const Text('Link existing device'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'On a signed-in device, open Settings → Link New Device, then copy its link code. Enter the PIN shown beside it. Links expire after 5 minutes. You will restore your encryption passphrase separately.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _code,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Link code'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pin,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 6,
                obscureText: true,
                decoration: const InputDecoration(labelText: '6-digit PIN'),
              ),
              if (_error != null) Text(_error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _link,
          child: Text(_busy ? 'Linking…' : 'Restore account'),
        ),
      ],
    ),
  );
}
