import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_repository.dart';
import '../config.dart';
import '../theme/viewvee_theme.dart';
import 'viewvee_logo.dart';

enum ViewveeDrawerDestination {
  monitor,
  devices,
  recordings,
  account,
  subscription,
  preferences,
  support,
  about,
}

class ViewveeAppDrawer extends StatelessWidget {
  const ViewveeAppDrawer({
    super.key,
    required this.watchMode,
    required this.activeDestination,
    required this.isPremium,
    required this.onOpenMonitor,
    required this.onOpenDevices,
    required this.onOpenRecordings,
    required this.onOpenAccount,
    required this.onOpenSubscription,
    required this.onOpenPreferences,
    required this.onOpenSupport,
    required this.onOpenAbout,
    required this.onSignOut,
    this.profileName,
    this.profileEmail,
  });

  final WatchMode? watchMode;
  final ViewveeDrawerDestination activeDestination;
  final bool isPremium;
  final VoidCallback onOpenMonitor;
  final VoidCallback onOpenDevices;
  final VoidCallback onOpenRecordings;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenSubscription;
  final VoidCallback onOpenPreferences;
  final VoidCallback onOpenSupport;
  final VoidCallback onOpenAbout;
  final VoidCallback onSignOut;
  final String? profileName;
  final String? profileEmail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    void closeAndRun(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    return Drawer(
      key: const Key('viewveeAppDrawer'),
      width: (MediaQuery.sizeOf(context).width * 0.82).clamp(0, 320),
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [
                    Color(0xFF0B1726),
                    Color(0xFF101C31),
                    Color(0xFF191533),
                  ]
                : const [
                    Color(0xFFF1FCFB),
                    Color(0xFFF2F8FE),
                    Color(0xFFF7F4FF),
                  ],
            stops: const [0, 0.52, 1],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _DrawerHeader(
                profileName: profileName,
                profileEmail: profileEmail,
                onSignOut: () => closeAndRun(onSignOut),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    _DrawerCard(
                      icon: Icons.visibility_outlined,
                      title: 'SLEDOVÁNÍ',
                      color: ViewveeColors.teal,
                      children: [
                        _DrawerItem(
                          key: const Key('drawerMonitor'),
                          icon: _watchModeIcon,
                          title: 'Režim sledování',
                          subtitle: _watchModeLabel,
                          selected:
                              activeDestination ==
                              ViewveeDrawerDestination.monitor,
                          onTap: () => closeAndRun(onOpenMonitor),
                        ),
                        _DrawerItem(
                          key: const Key('drawerDevices'),
                          icon: Icons.devices_rounded,
                          title: 'Připojená zařízení',
                          subtitle: 'Kamera a monitor',
                          selected:
                              activeDestination ==
                              ViewveeDrawerDestination.devices,
                          onTap: () => closeAndRun(onOpenDevices),
                        ),
                        _DrawerItem(
                          key: const Key('drawerRecordings'),
                          icon: Icons.video_library_outlined,
                          title: 'Nahrávky',
                          subtitle: isPremium
                              ? 'Uložená videa'
                              : 'Nahrávání je součástí Premium',
                          locked: !isPremium,
                          selected:
                              activeDestination ==
                              ViewveeDrawerDestination.recordings,
                          onTap: () => closeAndRun(onOpenRecordings),
                        ),
                      ],
                    ),
                    _DrawerCard(
                      icon: Icons.tune_rounded,
                      title: 'ÚČET A APLIKACE',
                      color: ViewveeColors.blue,
                      children: [
                        _DrawerItem(
                          key: const Key('drawerProfile'),
                          icon: Icons.person_outline_rounded,
                          title: 'Profil',
                          selected:
                              activeDestination ==
                              ViewveeDrawerDestination.account,
                          onTap: () => closeAndRun(onOpenAccount),
                        ),
                        if (Config.showPurchaseOptions)
                          _DrawerItem(
                            key: const Key('drawerSubscription'),
                            icon: Icons.workspace_premium_outlined,
                            title: 'Předplatné',
                            subtitle: 'ViewVee Free',
                            selected:
                                activeDestination ==
                                ViewveeDrawerDestination.subscription,
                            onTap: () => closeAndRun(onOpenSubscription),
                          ),
                        _DrawerItem(
                          key: const Key('drawerPreferences'),
                          icon: Icons.palette_outlined,
                          title: 'Jazyk a vzhled',
                          selected:
                              activeDestination ==
                              ViewveeDrawerDestination.preferences,
                          onTap: () => closeAndRun(onOpenPreferences),
                        ),
                      ],
                    ),
                    _DrawerCard(
                      icon: Icons.help_outline_rounded,
                      title: 'POMOC',
                      color: ViewveeColors.violet,
                      children: [
                        _DrawerItem(
                          key: const Key('drawerSupport'),
                          icon: Icons.support_agent_rounded,
                          title: 'Podpora',
                          selected:
                              activeDestination ==
                              ViewveeDrawerDestination.support,
                          onTap: () => closeAndRun(onOpenSupport),
                        ),
                        _DrawerItem(
                          key: const Key('drawerAbout'),
                          icon: Icons.info_outline_rounded,
                          title: 'O aplikaci',
                          subtitle: 'Verze 1.0.0',
                          selected:
                              activeDestination ==
                              ViewveeDrawerDestination.about,
                          onTap: () => closeAndRun(onOpenAbout),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _watchModeLabel => switch (watchMode) {
    WatchMode.baby => 'Dítě',
    WatchMode.pet => 'Mazlíček',
    WatchMode.home => 'Domov',
    null => 'Zatím nevybráno',
  };

  IconData get _watchModeIcon => Icons.videocam_outlined;
}

class _DrawerHeader extends StatefulWidget {
  const _DrawerHeader({
    required this.profileName,
    required this.profileEmail,
    required this.onSignOut,
  });

  final String? profileName;
  final String? profileEmail;
  final VoidCallback onSignOut;

  @override
  State<_DrawerHeader> createState() => _DrawerHeaderState();
}

class _DrawerHeaderState extends State<_DrawerHeader> {
  String _storedName = '';
  String _storedEmail = '';

  @override
  void initState() {
    super.initState();
    _loadStoredIdentity();
  }

  @override
  void didUpdateWidget(_DrawerHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadStoredIdentity();
  }

  String get _displayName {
    final providedName = widget.profileName?.trim() ?? '';
    if (providedName.isNotEmpty) return providedName;
    if (_storedName.isNotEmpty) return _storedName;
    return 'Profil';
  }

  String get _displaySubtitle {
    final providedEmail = widget.profileEmail?.trim() ?? '';
    if (providedEmail.isNotEmpty) return providedEmail;
    if (_storedEmail.isNotEmpty) return _storedEmail;
    return 'ViewVee Free';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        boxShadow: [
          BoxShadow(
            color: ViewveeColors.navy.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                padding: isDark ? EdgeInsets.zero : const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF101A2D) : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark
                        ? Theme.of(context).colorScheme.outline
                        : Colors.white.withValues(alpha: 0.9),
                    width: isDark ? 1 : 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: isDark
                      ? Image.asset(
                          'assets/branding/viewvee_icon_dark.png',
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.high,
                        )
                      : const ViewveeMark(size: 36),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    VvText(
                      _displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    VvText(
                      _displaySubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('drawerSignOutButton'),
            onPressed: widget.onSignOut,
            icon: const Icon(Icons.power_settings_new_rounded, size: 16),
            label: const VvText('Odhlásit se'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFB3261E),
              side: const BorderSide(color: Color(0xFFE8C7C3)),
              minimumSize: const Size.fromHeight(40),
              padding: const EdgeInsets.symmetric(vertical: 8),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadStoredIdentity() async {
    final preferences = await SharedPreferences.getInstance();
    final firstName =
        preferences.getString(AuthRepository.profileFirstNameKey) ?? '';
    final lastName =
        preferences.getString(AuthRepository.profileLastNameKey) ?? '';
    final name = [
      firstName,
      lastName,
    ].where((value) => value.trim().isNotEmpty).join(' ');
    final email = preferences.getString(AuthRepository.profileEmailKey) ?? '';
    if (!mounted || (name == _storedName && email == _storedEmail)) return;
    setState(() {
      _storedName = name;
      _storedEmail = email;
    });
  }
}

class _DrawerCard extends StatelessWidget {
  const _DrawerCard({
    required this.icon,
    required this.title,
    required this.color,
    required this.children,
  });

  final IconData icon;
  final String title;
  final Color color;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: 0.25)),
      boxShadow: [
        BoxShadow(
          color: color.withValues(alpha: 0.09),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icon, size: 15, color: color),
              ),
              const SizedBox(width: 8),
              VvText(
                title,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
          child: Column(children: children),
        ),
      ],
    ),
  );
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.selected = false,
    this.locked = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? ViewveeColors.teal.withValues(alpha: 0.08)
        : Colors.transparent,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? ViewveeColors.teal : ViewveeColors.blue,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  VvText(
                    title,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null)
                    VvText(
                      subtitle!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              locked ? Icons.lock_outline_rounded : Icons.chevron_right_rounded,
              size: 18,
              color: ViewveeColors.violet,
            ),
          ],
        ),
      ),
    ),
  );
}
