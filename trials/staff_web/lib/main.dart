// Disposable Flutter Web trial (Q10): copied from apps/mobile; do not build on this.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'platform_status/platform_status.dart';
import 'platform_status/platform_status_screen.dart';
import 'platform_status/supabase_platform_status_repository.dart';
import 'rota_trial/rota_fixture.dart';
import 'rota_trial/rota_trial_screen.dart';

/// Kept for the app's lifetime so the browser semantics tree is always built:
/// a screen-reader user should not need Flutter's hidden "enable
/// accessibility" button.
late final SemanticsHandle semanticsHandle;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  semanticsHandle = SemanticsBinding.instance.ensureSemantics();
  const config = AppConfig.fromEnvironment;
  Widget statusScreen = const MissingConfigScreen();
  if (config.isComplete) {
    final supabase = await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.publishableKey,
      postgrestOptions: const PostgrestClientOptions(schema: 'api'),
      // The tracer has no sign-in: keep any session in memory and ignore links.
      authOptions: const FlutterAuthClientOptions(
        persistSession: false,
        detectSessionInUri: false,
      ),
    );
    final PlatformStatusRepository repository =
        SupabasePlatformStatusRepository(supabase.client);
    statusScreen = PlatformStatusScreen(repository: repository);
  }
  runApp(
    MainApp(
      home: TrialShell(
        rota: RotaTrialScreen(fixture: RotaFixture.synthetic()),
        status: statusScreen,
      ),
    ),
  );
}

/// Keyboard focus ring shared by the trial's buttons.
final WidgetStateProperty<BorderSide?> _focusSide =
    WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? const BorderSide(color: TrialTokens.accent, width: kFocusRingWidth)
          : null,
    );

ThemeData trialTheme() {
  final focusStyle = ButtonStyle(side: _focusSide);
  return ThemeData(
    colorSchemeSeed: TrialTokens.primary,
    filledButtonTheme: FilledButtonThemeData(style: focusStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: focusStyle),
    textButtonTheme: TextButtonThemeData(style: focusStyle),
    segmentedButtonTheme: SegmentedButtonThemeData(style: focusStyle),
    inputDecorationTheme: const InputDecorationTheme(
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(
          color: TrialTokens.accent,
          width: kFocusRingWidth,
        ),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? TrialTokens.accent.withValues(alpha: 0.45)
            : null,
      ),
    ),
  );
}

/// Two destinations: the Q10 rota trial (default) and the 1.1 tracer status.
class TrialShell extends StatefulWidget {
  const TrialShell({super.key, required this.rota, required this.status});

  final Widget rota;
  final Widget status;

  @override
  State<TrialShell> createState() => _TrialShellState();
}

class _TrialShellState extends State<TrialShell>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: TrialTokens.primary,
        foregroundColor: Colors.white,
        title: const Text('BIC Kafue staff web trial'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: Colors.white,
          unselectedLabelColor: const Color(0xFFDCE6FF),
          indicatorColor: Colors.white,
          tabs: const [
            Tab(text: 'Rota grid trial'),
            Tab(text: 'Platform status'),
          ],
        ),
      ),
      body: IndexedStack(
        index: _tabs.index,
        children: [
          ExcludeFocus(excluding: _tabs.index != 0, child: widget.rota),
          ExcludeFocus(excluding: _tabs.index != 1, child: widget.status),
        ],
      ),
    );
  }
}

class MainApp extends StatelessWidget {
  const MainApp({super.key, required this.home});

  final Widget home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BIC Kafue staff web trial',
      theme: trialTheme(),
      home: home,
    );
  }
}

class MissingConfigScreen extends StatelessWidget {
  const MissingConfigScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Platform status not configured: build with '
            '--dart-define=SUPABASE_URL=… and '
            '--dart-define=SUPABASE_PUBLISHABLE_KEY=…',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
