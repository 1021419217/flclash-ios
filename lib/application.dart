import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/bootstrap.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/hotkey_manager.dart';
import 'package:fl_clash/manager/manager.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/pages.dart';

Widget buildManagerStack({
  required bool isDesktop,
  required Future<void> Function(List<ConnectivityResult> results)
  onConnectivityChanged,
  Stream<ProcessSignal>? terminateSignals,
  required Widget child,
}) {
  final platformApp = isDesktop
      ? WindowHeaderContainer(child: child)
      : VpnManager(child: child);
  final state = AppStateManager(
    child: CoreManager(
      child: ConnectivityManager(
        onConnectivityChanged: onConnectivityChanged,
        child: platformApp,
      ),
    ),
  );
  final platformState = isDesktop
      ? WindowManager(
          terminateSignals: terminateSignals,
          child: TrayManager(
            child: HotKeyManager(child: ProxyManager(child: state)),
          ),
        )
      : AndroidManager(child: TileManager(child: state));
  // App-wide light tap haptics (Circuit / Surge / Shadowrocket feel). One
  // translucent listener at the root of the whole page stack covers every
  // button, switch and list tap, and stays out of the shared views and the
  // prism_ui submodule so future upstream merges remain clean.
  return HapticFeedbackScope(
    child: AppEnvManager(
      child: LocaleManager(child: ThemeManager(child: platformState)),
    ),
  );
}

class Application extends ConsumerStatefulWidget {
  const Application({super.key});

  @override
  ConsumerState<Application> createState() => ApplicationState();
}

class ApplicationState extends ConsumerState<Application> {
  Timer? _autoUpdateProfilesTaskTimer;
  bool _preHasVpn = false;
  // Windows can only watch SIGINT and SIGHUP.
  final _terminateSignals = system.isDesktop && !system.isWindows
      ? ProcessSignal.sigterm.watch()
      : null;

  @override
  void initState() {
    super.initState();
    SystemNavigator.setFrameworkHandlesBack(true);
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      if (globalState.navigatorKey.currentContext != null) {
        await bootstrap.attach();
      } else {
        exit(0);
      }
      _autoUpdateProfilesTask();
      _initLink();
      if (!safeModeBuild) {
        unawaited(app?.initShortcuts());
      }
    });
  }

  void _initLink() {
    linkManager.initAppLinksListen((url) async {
      unawaited(window?.show());
      // Tapping a subscription link is the confirmation, so go straight to the
      // import. A prompt raised while the app is still coming up cannot be
      // drawn in that first frame and only leaves a stray back button behind.
      // Import failures still surface through the banner.
      await ref
          .read(profilesActionProvider.notifier)
          .addProfileFromLink(url, silence: true);
      _collapseRootStack();
    });
  }

  /// A cold-start URL can become the WidgetsApp initial route, and this app's
  /// onGenerateRoute answers every name with a HomeRoute. Two HomeRoutes share
  /// one child: the top one shows a back button, and popping it exposes a blank
  /// page. Collapse any residue left by the launch once the import has run.
  void _collapseRootStack([int remaining = 3]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = globalState.navigatorKey.currentState;
      if (navigator == null || !navigator.canPop()) {
        return;
      }
      navigator.popUntil((route) => route.isFirst);
      if (remaining > 1) {
        _collapseRootStack(remaining - 1);
      }
    });
  }

  void _autoUpdateProfilesTask() {
    _autoUpdateProfilesTaskTimer = Timer(const Duration(minutes: 20), () async {
      await ref.read(profilesActionProvider.notifier).autoUpdateProfiles();
      await ref.read(resourcesActionProvider.notifier).autoUpdate();
      await ref.read(mitmModulesActionProvider.notifier).autoUpdate();
      if (!mounted) {
        return;
      }
      _autoUpdateProfilesTask();
    });
  }

  Future<void> _handleConnectivityChanged(
    List<ConnectivityResult> results,
  ) async {
    commonPrint.log('connectivityChanged ${results.toString()}');
    unawaited(systemDnsCoordinator?.resync() ?? Future.value());
    unawaited(ref.read(systemActionProvider.notifier).updateLocalIp());
    final hasVpn = results.contains(ConnectivityResult.vpn);
    if (_preHasVpn == hasVpn) {
      ref.read(routeTrackerProvider.notifier).bumpHostEpoch();
      // Android's NetworkObserver tells the Core about a new network itself.
      if (system.isDesktop) {
        debouncer.call(
          FunctionTag.networkChange,
          ref.read(coreActionProvider.notifier).reportNetworkChange,
          duration: const Duration(milliseconds: 200),
        );
      }
    }
    _preHasVpn = hasVpn;
  }

  @override
  Widget build(context) {
    return Consumer(
      builder: (_, ref, child) {
        final locale = ref.watch(
          appSettingProvider.select((state) => state.locale),
        );
        final themeProps = ref.watch(themeSettingProvider);
        final textScale = themeProps.textScale;
        return PrismApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: globalState.navigatorKey,
          onNavigationNotification: (_) => true,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            AppUiLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          builder: (context, child) {
            return buildManagerStack(
              isDesktop: system.isDesktop,
              onConnectivityChanged: _handleConnectivityChanged,
              terminateSignals: _terminateSignals,
              child: child!,
            );
          },
          title: appName,
          locale: getLocaleForString(locale),
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          themeMode: themeProps.themeMode,
          theme: watchAppTheme(ref, Brightness.light),
          darkTheme: watchAppTheme(ref, Brightness.dark),
          textScale: textScale.enable ? textScale.scale : null,
          minTextScale: minTextScale,
          maxTextScale: maxTextScale,
          liquidGlass: switch (themeProps.liquidGlass) {
            LiquidGlassMode.none => null,
            LiquidGlassMode.ultra => LiquidGlassQuality.ultra,
            LiquidGlassMode.standard => LiquidGlassQuality.standard,
          },
          emojiFont: (family: FontFamily.twEmoji.value, pattern: emojiPattern),
          stackedBanners: !ref.watch(isMobileViewProvider),
          bannerTopInset: ref.watch(overlayTopOffsetProvider),
          remoteFocus: system.isTV,
          floatingKeyboard: app?.floatingKeyboard,
          onGenerateRoute: (settings) {
            // Only '/' owns the root page. A subscription URL delivered on a
            // cold start is not a route: answering it with a second HomeRoute
            // is what produced the stray back button and the blank page behind
            // it. Let Navigator fall back to '/' instead.
            if (settings.name != null &&
                settings.name != Navigator.defaultRouteName) {
              return null;
            }
            return HomeRoute(
              settings: settings,
              builder: (_) => KeyboardInsetHold(child: child!),
            );
          },
        );
      },
      child: const HomePage(),
    );
  }

  @override
  void dispose() {
    linkManager.destroy();
    _autoUpdateProfilesTaskTimer?.cancel();
    super.dispose();
  }
}
