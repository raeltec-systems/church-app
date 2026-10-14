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

ThemeData trialTheme() {
  // Standard density everywhere: the desktop default (compact) shrinks
  // buttons to 32 px, below the design contract's 44 px target.
  const minTarget = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(kMinTarget, 48)),
    visualDensity: VisualDensity.standard,
  );
  return ThemeData(
    colorSchemeSeed: TrialTokens.primary,
    visualDensity: VisualDensity.standard,
    // Keyboard highlight for list/menu items (e.g. dropdown options):
    // a near-solid accent, ≥3:1 against the unfocused white item.
    focusColor: TrialTokens.accent.withValues(alpha: 0.85),
    filledButtonTheme: const FilledButtonThemeData(style: minTarget),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: minTarget),
    textButtonTheme: const TextButtonThemeData(style: minTarget),
    inputDecorationTheme: const InputDecorationTheme(
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(
          color: TrialTokens.accent,
          // One px wider than the ring: the inner 3 px replace field background.
          width: kFocusRingWidth + 1,
        ),
      ),
    ),
  );
}

/// Two destinations: the Q10 rota trial (default) and the 1.1 tracer status.
///
/// Custom tabs instead of [TabBar]: TabBar's only focus cue is a faint ink
/// overlay, which fails a 3:1 focus-change contrast check on the navy bar.
class TrialShell extends StatefulWidget {
  const TrialShell({super.key, required this.rota, required this.status});

  final Widget rota;
  final Widget status;

  @override
  State<TrialShell> createState() => _TrialShellState();
}

class _TrialShellState extends State<TrialShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: TrialTokens.primary,
        foregroundColor: Colors.white,
        title: const Text('BIC Kafue staff web trial'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Semantics(
            role: SemanticsRole.tabBar,
            label: 'Trial sections',
            explicitChildNodes: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Row(
                children: [
                  _ShellTab(
                    label: 'Rota grid trial',
                    selected: _index == 0,
                    onTap: () => setState(() => _index = 0),
                  ),
                  _ShellTab(
                    label: 'Platform status',
                    selected: _index == 1,
                    onTap: () => setState(() => _index = 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: IndexedStack(
        index: _index,
        children: [
          ExcludeFocus(excluding: _index != 0, child: widget.rota),
          ExcludeFocus(excluding: _index != 1, child: widget.status),
        ],
      ),
    );
  }
}

class _ShellTab extends StatelessWidget {
  const _ShellTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        role: SemanticsRole.tab,
        selected: selected,
        container: true,
        child: FocusRing(
          color: Colors.white,
          radius: 10,
          child: InkWell(
            onTap: onTap,
            focusColor: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: selected ? Colors.white : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : const Color(0xFFDCE6FF),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
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
