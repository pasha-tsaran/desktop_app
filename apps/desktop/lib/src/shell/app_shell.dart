import 'package:flutter/material.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../../bootstrap.dart';
import '../screens/account_screen.dart';
import '../screens/app_settings_screen.dart';
import '../screens/logs_screen.dart';
import '../screens/placeholder_screen.dart';
import '../screens/plans_screen.dart';
import '../screens/servers_screen.dart';
import '../screens/speed_test_screen.dart';
import '../screens/support_screen.dart';
import '../screens/vpn_settings_screen.dart';
import 'destination.dart';

final class AppShell extends StatefulWidget {
  const AppShell({required this.dependencies, super.key});
  final AppDependencies dependencies;
  @override
  State<AppShell> createState() => _AppShellState();
}

final class _AppShellState extends State<AppShell> {
  AppDestination _destination = AppDestination.servers;

  List<AppDestination> get _destinations => <AppDestination>[
        AppDestination.servers,
        AppDestination.account,
        AppDestination.logs,
        AppDestination.vpnSettings,
        AppDestination.settings,
        AppDestination.support,
        if (!widget.dependencies.minimalMvpMode) ...<AppDestination>[
          AppDestination.plans,
          AppDestination.statistics,
          AppDestination.speedTest,
        ],
      ];

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color edge = dark ? const Color(0xFF344C83) : Colors.white;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final bool compact = constraints.maxWidth < 1050;
          return Padding(
            padding: EdgeInsets.all(compact ? 8 : 20),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: edge),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                      color:
                          KenaiTheme.accent.withValues(alpha: dark ? .12 : .06),
                      blurRadius: 30),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(21),
                child: Row(children: <Widget>[
                  SizedBox(
                      width: compact ? 76 : 250,
                      child: _sidebar(compact, dark)),
                  VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: edge.withValues(alpha: .7)),
                  Expanded(child: _screenFrame(dark)),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _sidebar(bool compact, bool dark) {
    final bool dense = MediaQuery.sizeOf(context).height < 800;
    final Color text = dark ? const Color(0xFFE9EDFF) : const Color(0xFF112052);
    return Container(
      decoration: BoxDecoration(
          gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: dark
            ? const <Color>[
                Color(0xFF0B142D),
                Color(0xFF080F24),
                Color(0xFF151338)
              ]
            : const <Color>[
                Color(0xFFD6EFF7),
                Color(0xFFDCE5F9),
                Color(0xFFDCD0F4)
              ],
      )),
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 16, vertical: 20),
      child: Column(children: <Widget>[
        Row(
          mainAxisAlignment:
              compact ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: <Widget>[
            const _KenaiMark(),
            if (!compact) ...<Widget>[
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Kenai VPN',
                      style: TextStyle(
                          color: text,
                          fontSize: 20,
                          fontWeight: FontWeight.w700)),
                  Text('Свобода ближе',
                      style: TextStyle(
                          color: text.withValues(alpha: .62), fontSize: 13)),
                ],
              )),
            ],
          ],
        ),
        SizedBox(height: dense ? 24 : 48),
        Expanded(
            child: ListView(
                key: const Key('sidebar-navigation'),
                children: _destinations.map((destination) {
                  final bool selected = destination == _destination;
                  return Padding(
                    padding: EdgeInsets.only(bottom: dense ? 6 : 12),
                    child: Tooltip(
                      message: destination.label,
                      child: InkWell(
                        key: ValueKey<String>('nav-${destination.name}'),
                        onTap: () => setState(() => _destination = destination),
                        borderRadius: BorderRadius.circular(15),
                        child: Container(
                          height: dense ? 52 : 64,
                          padding: EdgeInsets.symmetric(
                              horizontal: compact ? 0 : 14),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            gradient: selected
                                ? LinearGradient(
                                    colors: dark
                                        ? const <Color>[
                                            Color(0xFF4420A2),
                                            Color(0xFF211D55)
                                          ]
                                        : const <Color>[
                                            Color(0xFFE5D4FA),
                                            Color(0xFFD7BCF4)
                                          ])
                                : null,
                            border: selected
                                ? Border.all(color: const Color(0xFF985BFF))
                                : null,
                            boxShadow: selected
                                ? <BoxShadow>[
                                    BoxShadow(
                                        color: KenaiTheme.accent
                                            .withValues(alpha: .30),
                                        blurRadius: 14),
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: compact
                                ? MainAxisAlignment.center
                                : MainAxisAlignment.start,
                            children: <Widget>[
                              if (destination.imageAsset case final asset?)
                                Image.asset(asset,
                                    width: 34,
                                    height: 34,
                                    fit: BoxFit.contain,
                                    excludeFromSemantics: true)
                              else
                                Icon(destination.icon,
                                    size: 27,
                                    color: selected
                                        ? (dark
                                            ? Colors.white
                                            : KenaiTheme.accent)
                                        : text),
                              if (!compact) ...<Widget>[
                                const SizedBox(width: 8),
                                Flexible(
                                    child: Text(destination.label,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: selected
                                                ? (dark
                                                    ? Colors.white
                                                    : KenaiTheme.accent)
                                                : text,
                                            fontSize: 16,
                                            fontWeight: selected
                                                ? FontWeight.w600
                                                : FontWeight.w500))),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(growable: false))),
        if (!compact)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF1A2544) : const Color(0xFFE3D9F6),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: dark ? const Color(0xFF354778) : Colors.white),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(children: <Widget>[
                    const Icon(Icons.workspace_premium,
                        color: KenaiTheme.accent),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text('Kenai VPN Pro',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: text, fontWeight: FontWeight.w700))),
                  ]),
                  const SizedBox(height: 8),
                  Text('Больше возможностей для вашей свободы',
                      style: TextStyle(
                          color: text.withValues(alpha: .7), fontSize: 12)),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: () =>
                          setState(() => _destination = AppDestination.plans),
                      child: const Text('Перейти на Pro →')),
                ]),
          ),
      ]),
    );
  }

  Widget _screenFrame(bool dark) {
    if (_destination == AppDestination.servers) return _buildScreen();
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: dark ? const Color(0xFF293C66) : Colors.white),
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? const <Color>[
                    Color(0xFF0C162D),
                    Color(0xFF0A1125),
                    Color(0xFF181335)
                  ]
                : const <Color>[
                    Color(0xFFD7EEF6),
                    Color(0xFFDDE5F8),
                    Color(0xFFE0D4F4)
                  ]),
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildScreen(),
    );
  }

  Widget _buildScreen() {
    if (_destination == AppDestination.servers)
      return ServersScreen(dependencies: widget.dependencies);
    if (_destination == AppDestination.account)
      return AccountScreen(dependencies: widget.dependencies);
    if (_destination == AppDestination.plans)
      return PlansScreen(dependencies: widget.dependencies);
    if (_destination == AppDestination.vpnSettings)
      return VpnSettingsScreen(dependencies: widget.dependencies);
    if (_destination == AppDestination.logs)
      return LogsScreen(dependencies: widget.dependencies);
    if (_destination == AppDestination.speedTest)
      return SpeedTestScreen(dependencies: widget.dependencies);
    if (_destination == AppDestination.settings)
      return AppSettingsScreen(dependencies: widget.dependencies);
    if (_destination == AppDestination.support)
      return SupportScreen(
          repository: widget.dependencies.supportRepository,
          onOpenAccount: () =>
              setState(() => _destination = AppDestination.account));
    return PlaceholderScreen(destination: _destination);
  }
}

final class _KenaiMark extends StatelessWidget {
  const _KenaiMark();
  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Kenai VPN',
        child: Image.asset(
          'assets/branding/sphere-logo.png',
          width: 54,
          height: 54,
          fit: BoxFit.contain,
          excludeFromSemantics: true,
        ),
      );
}
