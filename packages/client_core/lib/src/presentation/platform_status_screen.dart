import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../domain/platform_status.dart';

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
    final c = ChurchColors.of(context);
    final loading = _state is _Loading;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Platform status'),
        actions: [
          FocusRing(
            child: IconButton(
              key: const Key('reload'),
              tooltip: 'Reload',
              onPressed: loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: ChurchLayout.of(context).pagePadding,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: DefaultTextStyle.merge(
                style: ChurchLayout.of(context).body.copyWith(color: c.ink),
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
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Loading platform status…'),
      ],
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.status});

  final PlatformStatus status;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Card(
      key: const Key('state-data'),
      child: Padding(
        padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Status: ${status.status}',
              style: ChurchType.sectionTitle.copyWith(
                color: c.brand,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(status.message),
            const SizedBox(height: 8),
            Text(
              'Updated ${formatUtc(status.updatedAt)}',
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
            if (status.isSynthetic) ...[
              const SizedBox(height: 12),
              const StatusLabel(
                label: 'Synthetic test data',
                tone: StatusTone.neutral,
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
    final c = ChurchColors.of(context);
    return Column(
      key: const Key('state-empty'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.inbox_outlined, color: c.ink, size: 40),
        const SizedBox(height: 12),
        Text(
          'No platform status recorded',
          textAlign: TextAlign.center,
          style: ChurchType.cardTitle.copyWith(color: c.ink),
        ),
        const SizedBox(height: 16),
        FocusRing(
          child: OutlinedButton(
            onPressed: onReload,
            child: const Text('Reload'),
          ),
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
    return RequestStateBanner(
      key: const Key('state-error'),
      tone: StatusTone.danger,
      icon: Icons.error_outline,
      title: title,
      message: detail,
      actions: [BannerAction('Try again', onRetry, primary: true)],
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

/// The platform-status destination: the tracer read when a backend is
/// configured, otherwise an explanation of how to configure the build.
class PlatformStatusDestination extends ConsumerWidget {
  const PlatformStatusDestination({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(platformStatusRepositoryProvider);
    if (repository == null) return const MissingConfigScreen();
    return PlatformStatusScreen(repository: repository);
  }
}

/// Shown when the build lacks backend configuration.
class MissingConfigScreen extends StatelessWidget {
  const MissingConfigScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Platform status')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(ChurchGeometry.mobileContentPadding),
          child: Text(
            'App not configured: build with --dart-define=SUPABASE_URL=… and '
            '--dart-define=SUPABASE_PUBLISHABLE_KEY=…',
            key: Key('missing-config'),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
