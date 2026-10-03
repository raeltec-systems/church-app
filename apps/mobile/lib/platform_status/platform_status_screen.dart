import 'package:flutter/material.dart';

import 'platform_status.dart';

/// Local tracer colours from the design contract tokens. The semantic design
/// system arrives with entry 1.7; do not reuse these elsewhere.
abstract final class _Tokens {
  static const bg = Color(0xFFF4F6FA);
  static const ink = Color(0xFF0E1530);
  static const primary = Color(0xFF14246B);
  static const redBg = Color(0xFFFCE5E2);
  static const redFg = Color(0xFFA3241A);
}

/// Minimum tap target used by every action on this screen.
const double kMinTapTarget = 48;

sealed class _ViewState {
  const _ViewState();
}

class _Loading extends _ViewState {
  const _Loading();
}

class _Loaded extends _ViewState {
  const _Loaded(this.status);
  final PlatformStatus status;
}

class _Empty extends _ViewState {
  const _Empty();
}

class _Failed extends _ViewState {
  const _Failed(this.failure);
  final PlatformStatusFailure failure;
}

/// Shows the platform status with loading, data, empty and error states.
class PlatformStatusScreen extends StatefulWidget {
  const PlatformStatusScreen({super.key, required this.repository});

  final PlatformStatusRepository repository;

  @override
  State<PlatformStatusScreen> createState() => _PlatformStatusScreenState();
}

class _PlatformStatusScreenState extends State<PlatformStatusScreen> {
  _ViewState _state = const _Loading();
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final requestId = ++_requestId;
    // Never keep an older value on screen as if it were current.
    if (_state is! _Loading) setState(() => _state = const _Loading());
    _ViewState next;
    try {
      final status = await widget.repository.fetch();
      next = status == null ? const _Empty() : _Loaded(status);
    } on PlatformStatusException catch (e) {
      next = _Failed(e.failure);
    } catch (_) {
      next = const _Failed(PlatformStatusFailure.rejected);
    }
    // Ignore responses that a newer request has superseded.
    if (!mounted || requestId != _requestId) return;
    setState(() => _state = next);
  }

  @override
  Widget build(BuildContext context) {
    final loading = _state is _Loading;
    return Scaffold(
      backgroundColor: _Tokens.bg,
      appBar: AppBar(
        backgroundColor: _Tokens.bg,
        foregroundColor: _Tokens.primary,
        title: const Text('Platform status'),
        actions: [
          IconButton(
            key: const Key('reload'),
            tooltip: 'Reload',
            constraints: const BoxConstraints(
              minWidth: kMinTapTarget,
              minHeight: kMinTapTarget,
            ),
            onPressed: loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: switch (_state) {
                _Loading() => const _LoadingView(),
                _Loaded(:final status) => _StatusView(status: status),
                _Empty() => _EmptyView(onReload: _load),
                _Failed(:final failure) => _ErrorView(
                  failure: failure,
                  onRetry: _load,
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Column(
      key: Key('state-loading'),
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: _Tokens.primary),
        SizedBox(height: 16),
        Text(
          'Loading platform status…',
          style: TextStyle(color: _Tokens.ink, fontSize: 16),
        ),
      ],
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.status});

  final PlatformStatus status;

  @override
  Widget build(BuildContext context) {
    const ink = TextStyle(color: _Tokens.ink, fontSize: 16);
    return Card(
      key: const Key('state-data'),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Status: ${status.status}',
              style: const TextStyle(
                color: _Tokens.primary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(status.message, style: ink),
            const SizedBox(height: 8),
            Text(
              'Updated ${formatUtc(status.updatedAt)}',
              style: ink.copyWith(fontSize: 14),
            ),
            if (status.isSynthetic) ...[
              const SizedBox(height: 12),
              const Text(
                'Synthetic test data',
                style: TextStyle(
                  color: _Tokens.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onReload});

  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('state-empty'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.inbox_outlined, color: _Tokens.ink, size: 40),
        const SizedBox(height: 12),
        const Text(
          'No platform status recorded',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _Tokens.ink,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(kMinTapTarget * 2, kMinTapTarget),
          ),
          onPressed: onReload,
          child: const Text('Reload'),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.failure, required this.onRetry});

  final PlatformStatusFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (title, detail) = switch (failure) {
      PlatformStatusFailure.unreachable => (
        "Couldn't reach the server",
        'Check your connection, then try again.',
      ),
      PlatformStatusFailure.rejected => (
        "The server couldn't provide the platform status",
        'Try again. If this keeps happening, the service may be misconfigured.',
      ),
    };
    return Container(
      key: const Key('state-error'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _Tokens.redBg,
        border: Border.all(color: _Tokens.redFg),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, color: _Tokens.redFg),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _Tokens.redFg,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: const TextStyle(color: _Tokens.ink, fontSize: 16),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _Tokens.primary,
              minimumSize: const Size(kMinTapTarget * 2, kMinTapTarget),
            ),
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

/// Formats an instant as `YYYY-MM-DD HH:MM UTC`. Church-local time waits for Q2.
String formatUtc(DateTime instant) {
  final t = instant.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)} UTC';
}
