import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_repository.dart';
import 'recordings_screen.dart';
import '../theme/viewvee_theme.dart';
import '../widgets/viewvee_app_drawer.dart';
import '../widgets/viewvee_logo.dart';

enum DevicePairingAction { camera, monitor }

Future<WatchMode?> showViewveeWatchModePicker(
  BuildContext context,
  WatchMode? selected,
) => showModalBottomSheet<WatchMode>(
  context: context,
  showDragHandle: true,
  builder: (context) => _WatchModeSheet(selected: selected),
);

class AccountMenuScreen extends StatefulWidget {
  const AccountMenuScreen({
    super.key,
    required this.isGuest,
    required this.isPremium,
    this.accountId,
    required this.watchMode,
    required this.themeMode,
    required this.onWatchModeChanged,
    required this.onThemeModeChanged,
    required this.onPasswordReset,
    required this.onAddDevice,
    required this.onSignOut,
    this.openExternalUrl,
    this.initialDestination = ViewveeDrawerDestination.account,
  });

  final bool isGuest;
  final bool isPremium;
  final int? accountId;
  final WatchMode? watchMode;
  final ThemeMode themeMode;
  final Future<void> Function(WatchMode mode) onWatchModeChanged;
  final Future<void> Function(ThemeMode mode) onThemeModeChanged;
  final Future<void> Function(String email) onPasswordReset;
  final Future<void> Function(DevicePairingAction action) onAddDevice;
  final VoidCallback onSignOut;
  final Future<void> Function(Uri uri)? openExternalUrl;
  final ViewveeDrawerDestination initialDestination;

  @override
  State<AccountMenuScreen> createState() => _AccountMenuScreenState();
}

class _AccountMenuScreenState extends State<AccountMenuScreen> {
  static const _firstNameKey = AuthRepository.profileFirstNameKey;
  static const _lastNameKey = AuthRepository.profileLastNameKey;
  static const _emailKey = AuthRepository.profileEmailKey;

  String _languageCode = 'system';
  late ThemeMode _themeMode;
  WatchMode? _watchMode;
  _PersonalDetails _personalDetails = const _PersonalDetails();
  late ViewveeDrawerDestination _activeDestination;

  @override
  void initState() {
    super.initState();
    _watchMode = widget.watchMode;
    _themeMode = widget.themeMode;
    _activeDestination =
        !widget.isPremium &&
            widget.initialDestination == ViewveeDrawerDestination.recordings
        ? ViewveeDrawerDestination.subscription
        : widget.initialDestination;
    final locale = ViewveeLocaleController.instance.locale;
    _languageCode = locale == null
        ? 'system'
        : ViewveeLocaleController.codeOf(locale);
    _loadPersonalDetails();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            key: const Key('accountMenuButton'),
            tooltip: context.vv('Otevřít menu'),
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu_rounded),
          ),
        ),
        title: VvText(
          _pageTitle,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            key: const Key('accountBackButton'),
            tooltip: context.vv('Zpět'),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ],
      ),
      drawer: _buildAppDrawer(),
      body: SafeArea(top: false, child: _buildDestinationBody()),
    );
  }

  String get _pageTitle => switch (_activeDestination) {
    ViewveeDrawerDestination.monitor => 'Režim sledování',
    ViewveeDrawerDestination.devices => 'Připojená zařízení',
    ViewveeDrawerDestination.recordings => 'Nahrávky',
    ViewveeDrawerDestination.account => 'Profil',
    ViewveeDrawerDestination.subscription => 'Předplatné',
    ViewveeDrawerDestination.preferences => 'Jazyk a vzhled',
    ViewveeDrawerDestination.support => 'Podpora',
    ViewveeDrawerDestination.about => 'O aplikaci',
  };

  Widget _buildDestinationBody() => switch (_activeDestination) {
    ViewveeDrawerDestination.monitor => _buildProfilePage(),
    ViewveeDrawerDestination.devices => _buildDevicesPage(),
    ViewveeDrawerDestination.recordings =>
      widget.isPremium ? const RecordingsScreen() : const _SubscriptionSheet(),
    ViewveeDrawerDestination.account => _buildProfilePage(),
    ViewveeDrawerDestination.subscription => const _SubscriptionSheet(),
    ViewveeDrawerDestination.preferences => _buildPreferencesPage(),
    ViewveeDrawerDestination.support => _SupportPage(
      name: _personalDetails.fullName,
      email: _personalDetails.email,
    ),
    ViewveeDrawerDestination.about => const _AboutPage(),
  };

  Widget _buildProfilePage() => ListView(
    key: const Key('profilePage'),
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
    children: [
      _ProfileHeader(
        isGuest: widget.isGuest,
        personalDetails: _personalDetails,
      ),
      const SizedBox(height: 24),
      const _SectionLabel('PROFIL'),
      const SizedBox(height: 8),
      _SettingsGroup(
        children: [
          _MenuTile(
            key: const Key('profileMenuItem'),
            icon: Icons.badge_outlined,
            color: ViewveeColors.blue,
            title: _personalDetails.isEmpty
                ? 'Doplnit osobní údaje'
                : 'Upravit osobní údaje',
            subtitle: _personalDetails.summary,
            onTap: _showPersonalDetailsForm,
          ),
          const _GroupDivider(),
          _MenuTile(
            key: const Key('securityMenuItem'),
            icon: Icons.lock_outline_rounded,
            color: ViewveeColors.teal,
            title: 'Zabezpečení',
            subtitle: 'Obnovení přístupového hesla',
            onTap: _showSecurityForm,
          ),
          const _GroupDivider(),
          _MenuTile(
            key: const Key('deleteAccountMenuItem'),
            icon: Icons.person_remove_outlined,
            color: const Color(0xFFD84A4A),
            title: 'Smazat účet',
            subtitle: 'Trvalé odstranění účtu a souvisejících dat',
            onTap: _showDeleteAccountFlow,
          ),
        ],
      ),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        key: const Key('signOutButton'),
        onPressed: widget.onSignOut,
        icon: const Icon(Icons.logout_rounded),
        label: const VvText('Odhlásit se'),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFB3261E),
          side: const BorderSide(color: Color(0xFFE8C7C3)),
          minimumSize: const Size.fromHeight(52),
        ),
      ),
    ],
  );

  Widget _buildDevicesPage() => ListView(
    key: const Key('devicesPage'),
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
    children: [
      const _PageIntro(
        icon: Icons.devices_rounded,
        color: ViewveeColors.teal,
        title: 'Vaše zařízení',
        subtitle: 'Spravujte telefony používané jako kamera nebo monitor.',
      ),
      const SizedBox(height: 20),
      _SettingsGroup(
        children: [
          _MenuTile(
            key: const Key('addDeviceMenuItem'),
            icon: Icons.add_circle_outline_rounded,
            color: ViewveeColors.teal,
            title: 'Přidat zařízení',
            subtitle: 'Spárovat další kameru nebo monitor',
            onTap: _showAddDeviceOptions,
          ),
        ],
      ),
    ],
  );

  Widget _buildPreferencesPage() => ListView(
    key: const Key('preferencesPage'),
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
    children: [
      const _PageIntro(
        icon: Icons.palette_outlined,
        color: ViewveeColors.logoBlue,
        title: 'Přizpůsobení aplikace',
        subtitle: 'Vyberte jazyk a způsob zobrazení ViewVee.',
      ),
      const SizedBox(height: 20),
      _SettingsGroup(
        key: const Key('languageSettingsTile'),
        children: [
          _MenuTile(
            key: const Key('languageMenuItem'),
            icon: Icons.language_rounded,
            color: ViewveeColors.teal,
            title: 'Jazyk',
            subtitle: _languageCode == 'system'
                ? context.vv('Podle systému')
                : ViewveeLocaleController.languageNames[_languageCode] ??
                      _languageCode,
            onTap: _showLanguagePicker,
          ),
        ],
      ),
      const SizedBox(height: 12),
      _SettingsGroup(
        key: const Key('appearanceSettingsTile'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _MenuIcon(
                      icon: Icons.contrast_rounded,
                      color: ViewveeColors.violet,
                    ),
                    const SizedBox(width: 14),
                    VvText(
                      'Vzhled',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Center(
                  child: _AppearanceSelector(
                    selected: _themeMode,
                    onSelected: (mode) {
                      setState(() => _themeMode = mode);
                      widget.onThemeModeChanged(mode);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ],
  );

  Widget _buildAppDrawer() => ViewveeAppDrawer(
    watchMode: _watchMode,
    activeDestination: _activeDestination,
    isPremium: widget.isPremium,
    profileName: _personalDetails.fullName,
    profileEmail: _personalDetails.email,
    onOpenMonitor: _openWatchModeFromDrawer,
    onOpenDevices: () => _selectDestination(ViewveeDrawerDestination.devices),
    onOpenRecordings: () => _selectDestination(
      widget.isPremium
          ? ViewveeDrawerDestination.recordings
          : ViewveeDrawerDestination.subscription,
    ),
    onOpenAccount: () => _selectDestination(ViewveeDrawerDestination.account),
    onOpenSubscription: () =>
        _selectDestination(ViewveeDrawerDestination.subscription),
    onOpenPreferences: () =>
        _selectDestination(ViewveeDrawerDestination.preferences),
    onOpenSupport: () => _selectDestination(ViewveeDrawerDestination.support),
    onOpenAbout: () => _selectDestination(ViewveeDrawerDestination.about),
    onSignOut: widget.onSignOut,
  );

  void _selectDestination(ViewveeDrawerDestination destination) {
    if (mounted) setState(() => _activeDestination = destination);
  }

  Future<void> _showLanguagePicker() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => _LanguageSheet(selected: _languageCode),
    );
    if (selected == null) return;
    await ViewveeLocaleController.instance.setLanguage(selected);
    if (mounted) setState(() => _languageCode = selected);
  }

  Future<void> _showWatchModePicker() async {
    final selected = await showViewveeWatchModePicker(context, _watchMode);
    if (selected == null || selected == _watchMode) return;
    await widget.onWatchModeChanged(selected);
    if (mounted) setState(() => _watchMode = selected);
  }

  void _openWatchModeFromDrawer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showWatchModePicker();
    });
  }

  Future<void> _loadPersonalDetails() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('profile.phone');
    final details = _PersonalDetails(
      firstName: preferences.getString(_firstNameKey) ?? '',
      lastName: preferences.getString(_lastNameKey) ?? '',
      email: preferences.getString(_emailKey) ?? '',
    );
    if (mounted) setState(() => _personalDetails = details);
  }

  Future<void> _showPersonalDetailsForm() async {
    final details = await showModalBottomSheet<_PersonalDetails>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) =>
          _PersonalDetailsSheet(initialDetails: _personalDetails),
    );
    if (details == null) return;

    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setString(_firstNameKey, details.firstName),
      preferences.setString(_lastNameKey, details.lastName),
      preferences.setString(_emailKey, details.email),
    ]);
    if (!mounted) return;
    setState(() => _personalDetails = details);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: VvText('Osobní údaje byly uloženy.')),
    );
  }

  Future<void> _showSecurityForm() async {
    final email = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _SecuritySheet(
        initialEmail: _personalDetails.email,
        onPasswordReset: widget.onPasswordReset,
      ),
    );
    if (email == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: VvText('Odkaz pro změnu hesla jsme poslali na $email.'),
      ),
    );
  }

  Future<void> _showAddDeviceOptions() async {
    final action = await showModalBottomSheet<DevicePairingAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => const _AddDeviceSheet(),
    );
    if (action != null) await widget.onAddDevice(action);
  }

  Future<void> _showDeleteAccountFlow() async {
    final colors = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: colors.error),
        title: const VvText('Smazat účet?'),
        content: const VvText(
          'Tento krok nelze vrátit. Po ověření vlastníka bude trvale '
          'odstraněn váš účet i související osobní údaje.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const VvText('Zrušit'),
          ),
          FilledButton(
            key: const Key('continueAccountDeletionButton'),
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            child: const VvText('Pokračovat'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final uri = Uri.https(
      'viewvee.com',
      '/account/delete',
      widget.accountId == null
          ? null
          : {'accountId': widget.accountId.toString()},
    );
    final openExternalUrl = widget.openExternalUrl;
    if (openExternalUrl != null) {
      await openExternalUrl(uri);
    } else {
      await launchUrl(uri);
    }
  }
}

class _AddDeviceSheet extends StatelessWidget {
  const _AddDeviceSheet();

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VvText(
            'Přidat zařízení',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          VvText(
            'Jak chcete použít tento telefon?',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          _DeviceRoleChoice(
            key: const Key('addCameraDevice'),
            icon: Icons.videocam_rounded,
            color: ViewveeColors.teal,
            title: 'Jako kamera',
            subtitle: 'Zobrazit QR kód pro druhý telefon',
            onTap: () => Navigator.pop(context, DevicePairingAction.camera),
          ),
          const SizedBox(height: 12),
          _DeviceRoleChoice(
            key: const Key('addMonitorDevice'),
            icon: Icons.qr_code_scanner_rounded,
            color: ViewveeColors.blue,
            title: 'Jako monitor',
            subtitle: 'Naskenovat QR kód z telefonu s kamerou',
            onTap: () => Navigator.pop(context, DevicePairingAction.monitor),
          ),
        ],
      ),
    ),
  );
}

class _DeviceRoleChoice extends StatelessWidget {
  const _DeviceRoleChoice({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: color.withValues(alpha: 0.07),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: color.withValues(alpha: 0.24)),
    ),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            _MenuIcon(icon: icon, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  VvText(
                    title,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  VvText(
                    subtitle,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: color),
          ],
        ),
      ),
    ),
  );
}

class _SecuritySheet extends StatefulWidget {
  const _SecuritySheet({
    required this.initialEmail,
    required this.onPasswordReset,
  });

  final String initialEmail;
  final Future<void> Function(String email) onPasswordReset;

  @override
  State<_SecuritySheet> createState() => _SecuritySheetState();
}

class _SecuritySheetState extends State<_SecuritySheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _emailController;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.initialEmail);
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VvText(
                'Zabezpečení',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              VvText(
                'Na váš e-mail pošleme bezpečný odkaz pro nastavení nového hesla.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              TextFormField(
                key: const Key('securityEmailField'),
                controller: _emailController,
                enabled: !_loading,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                decoration: InputDecoration(labelText: context.vv('E-mail')),
                validator: (value) {
                  final email = value?.trim() ?? '';
                  if (email.isEmpty) return context.vv('Toto pole je povinné');
                  if (!email.contains('@') || !email.contains('.')) {
                    return context.vv('Zadejte platný e-mail.');
                  }
                  return null;
                },
                onFieldSubmitted: (_) => _sendResetLink(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                VvText(
                  _error!,
                  key: const Key('securityError'),
                  style: const TextStyle(color: Color(0xFFB3261E)),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('sendPasswordResetButton'),
                onPressed: _loading ? null : _sendResetLink,
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.mark_email_read_outlined),
                label: const VvText('Odeslat'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _sendResetLink() async {
    if (_loading || !(_formKey.currentState?.validate() ?? false)) return;
    final email = _emailController.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.onPasswordReset(email);
      if (mounted) Navigator.of(context).pop(email);
    } on AuthException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = context.vvError(error.message);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = context.vv('Něco se pokazilo. Zkuste to prosím znovu.');
        });
      }
    }
  }
}

class _PersonalDetails {
  const _PersonalDetails({
    this.firstName = '',
    this.lastName = '',
    this.email = '',
  });

  final String firstName;
  final String lastName;
  final String email;

  bool get isEmpty => firstName.isEmpty && lastName.isEmpty && email.isEmpty;

  String get fullName =>
      [firstName, lastName].where((value) => value.isNotEmpty).join(' ');

  String get summary {
    if (isEmpty) return 'Osobní údaje';
    if (email.isEmpty) return fullName;
    return '$fullName · $email';
  }
}

class _PersonalDetailsSheet extends StatefulWidget {
  const _PersonalDetailsSheet({required this.initialDetails});

  final _PersonalDetails initialDetails;

  @override
  State<_PersonalDetailsSheet> createState() => _PersonalDetailsSheetState();
}

class _PersonalDetailsSheetState extends State<_PersonalDetailsSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _emailController;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(
      text: widget.initialDetails.firstName,
    );
    _lastNameController = TextEditingController(
      text: widget.initialDetails.lastName,
    );
    _emailController = TextEditingController(text: widget.initialDetails.email);
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VvText(
                'Osobní údaje',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              VvText(
                'Údaje můžete kdykoliv změnit v profilu.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              TextFormField(
                key: const Key('profileFirstNameField'),
                controller: _firstNameController,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: context.vv('Jméno')),
                validator: _requiredField,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('profileLastNameField'),
                controller: _lastNameController,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: context.vv('Příjmení')),
                validator: _requiredField,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('profileEmailField'),
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                decoration: InputDecoration(labelText: context.vv('E-mail')),
                onFieldSubmitted: (_) => _save(),
                validator: (value) {
                  final email = value?.trim() ?? '';
                  if (email.isEmpty) return context.vv('Toto pole je povinné');
                  if (!email.contains('@') || !email.contains('.')) {
                    return context.vv('Zadejte platný e-mail.');
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('savePersonalDetailsButton'),
                onPressed: _save,
                child: const VvText('Uložit údaje'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  String? _requiredField(String? value) => value == null || value.trim().isEmpty
      ? context.vv('Toto pole je povinné')
      : null;

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      _PersonalDetails(
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        email: _emailController.text.trim(),
      ),
    );
  }
}

class _PageIntro extends StatelessWidget {
  const _PageIntro({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            colors.surface,
            color.withValues(alpha: 0.18),
            colors.surface,
          ],
          stops: const [0, 0.5, 1],
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          _MenuIcon(icon: icon, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VvText(
                  title,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                VvText(
                  subtitle,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutPage extends StatelessWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('aboutPage'),
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
    children: [
      const Center(child: ViewveeLogo(width: 190)),
      const SizedBox(height: 20),
      VvText(
        'Bezpečné spojení s tím, na čem vám záleží.',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 24),
      _SettingsGroup(
        children: [
          _MenuTile(
            icon: Icons.info_outline_rounded,
            color: ViewveeColors.blue,
            title: 'Verze aplikace',
            subtitle: '1.0.0 (1)',
            onTap: () {},
          ),
          const _GroupDivider(),
          _MenuTile(
            icon: Icons.shield_outlined,
            color: ViewveeColors.teal,
            title: 'Soukromí a podmínky',
            subtitle: 'Právní informace ViewVee',
            onTap: () =>
                launchUrl(Uri.parse('https://viewvee.com/privacy-policy.html')),
          ),
        ],
      ),
    ],
  );
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.isGuest, required this.personalDetails});

  final bool isGuest;
  final _PersonalDetails personalDetails;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            colors.surface,
            ViewveeColors.logoBlue.withValues(alpha: 0.2),
            colors.surface,
          ],
          stops: const [0, 0.5, 1],
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: ViewveeColors.logoBlue.withValues(alpha: 0.36),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: ViewveeColors.navy.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const ViewveeMark(size: 42),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VvText(
                  isGuest
                      ? 'Profil'
                      : personalDetails.isEmpty
                      ? 'Osobní údaje'
                      : personalDetails.fullName,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                VvText(
                  isGuest
                      ? 'Pokračovat bez přihlášení'
                      : personalDetails.email.isEmpty
                      ? 'Osobní údaje'
                      : personalDetails.email,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: VvText(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: Column(children: children),
  );
}

class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, indent: 68, endIndent: 16);
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          _MenuIcon(icon: icon, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VvText(
                  title,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                VvText(
                  subtitle,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Icon(
            Icons.chevron_right_rounded,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    ),
  );
}

class _MenuIcon extends StatelessWidget {
  const _MenuIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(icon, color: color, size: 21),
  );
}

class _AppearanceSelector extends StatelessWidget {
  const _AppearanceSelector({required this.selected, required this.onSelected});

  final ThemeMode selected;
  final ValueChanged<ThemeMode> onSelected;

  @override
  Widget build(BuildContext context) => SegmentedButton<ThemeMode>(
    showSelectedIcon: false,
    segments: const [
      ButtonSegment(
        value: ThemeMode.light,
        icon: Icon(Icons.light_mode_outlined),
        label: VvText('Světlý'),
      ),
      ButtonSegment(
        value: ThemeMode.dark,
        icon: Icon(Icons.dark_mode_outlined),
        label: VvText('Tmavý'),
      ),
      ButtonSegment(
        value: ThemeMode.system,
        icon: Icon(Icons.settings_suggest_outlined),
        label: VvText('Systém'),
      ),
    ],
    selected: {selected},
    onSelectionChanged: (values) => onSelected(values.first),
  );
}

class _LanguageSheet extends StatelessWidget {
  const _LanguageSheet({required this.selected});

  final String selected;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VvText(
            'Vyberte jazyk',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          for (final entry in ViewveeLocaleController.languageNames.entries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.translate_rounded),
              title: Text(
                entry.key == 'system'
                    ? context.vv('Podle systému')
                    : entry.value,
              ),
              trailing: entry.key == selected
                  ? const Icon(
                      Icons.check_circle_rounded,
                      color: ViewveeColors.teal,
                    )
                  : null,
              onTap: () => Navigator.pop(context, entry.key),
            ),
        ],
      ),
    ),
  );
}

class _WatchModeSheet extends StatelessWidget {
  const _WatchModeSheet({required this.selected});

  final WatchMode? selected;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: VvText(
                  'Vyberte režim sledování',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                key: const Key('closeWatchModePicker'),
                tooltip: context.vv('Zpět'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _WatchModeChoice(
            key: const Key('watchModeBaby'),
            icon: Icons.child_friendly_rounded,
            label: 'Dítě',
            color: ViewveeColors.teal,
            selected: selected == WatchMode.baby,
            onTap: () => Navigator.pop(context, WatchMode.baby),
          ),
          const SizedBox(height: 10),
          _WatchModeChoice(
            key: const Key('watchModePet'),
            icon: Icons.pets_rounded,
            label: 'Mazlíček',
            color: ViewveeColors.blue,
            selected: selected == WatchMode.pet,
            onTap: () => Navigator.pop(context, WatchMode.pet),
          ),
          const SizedBox(height: 10),
          _WatchModeChoice(
            key: const Key('watchModeHome'),
            icon: Icons.home_rounded,
            label: 'Domov',
            color: ViewveeColors.violet,
            selected: selected == WatchMode.home,
            onTap: () => Navigator.pop(context, WatchMode.home),
          ),
        ],
      ),
    ),
  );
}

class _WatchModeChoice extends StatelessWidget {
  const _WatchModeChoice({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? color.withValues(alpha: 0.12)
        : Theme.of(context).colorScheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(
        color: selected ? color : Theme.of(context).colorScheme.outline,
        width: selected ? 2 : 1,
      ),
    ),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _MenuIcon(icon: icon, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: VvText(
                label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? color : Theme.of(context).colorScheme.outline,
            ),
          ],
        ),
      ),
    ),
  );
}

class _SubscriptionSheet extends StatelessWidget {
  const _SubscriptionSheet();

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      key: const Key('subscriptionPage'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _PageIntro(
            icon: Icons.workspace_premium_rounded,
            color: ViewveeColors.logoBlue,
            title: 'Vyberte si tarif',
            subtitle: 'Premium zaplatíte pouze jednou. Žádné měsíční poplatky.',
          ),
          const SizedBox(height: 16),
          const _FreePlanCard(
            key: Key('freePlanCard'),
            title: 'Zdarma',
            subtitle: 'Aktuální tarif',
            color: ViewveeColors.blue,
            features: [
              _PlanFeature(Icons.wifi_rounded, 'Wi-Fi monitoring • 1 hodina'),
              _PlanFeature(Icons.sd_rounded, 'SD kvalita'),
              _PlanFeature(
                Icons.lock_outline_rounded,
                'Internet pouze s Premium',
              ),
              _PlanFeature(Icons.videocam_off_outlined, 'Bez nahrávání videa'),
              _PlanFeature(
                Icons.campaign_outlined,
                'Reklama po každé hodině sledování',
              ),
            ],
          ),
          const SizedBox(height: 12),
          _PremiumPlanCard(
            key: const Key('premiumPlanCard'),
            features: const [
              _PlanFeature(Icons.public_rounded, 'Neomezený internet'),
              _PlanFeature(Icons.hd_rounded, 'HD video'),
              _PlanFeature(
                Icons.video_library_rounded,
                'Nahrávání videa • pouze lokálně',
              ),
              _PlanFeature(Icons.record_voice_over_outlined, 'Obousměrný zvuk'),
              _PlanFeature(Icons.block_rounded, 'Žádné reklamy'),
              _PlanFeature(
                Icons.all_inclusive_rounded,
                'Neomezená délka spojení',
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _PremiumPlanCard extends StatelessWidget {
  const _PremiumPlanCard({super.key, required this.features});

  final List<_PlanFeature> features;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [ViewveeColors.teal, ViewveeColors.blue, ViewveeColors.violet],
        stops: [0, 0.5, 1],
      ),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      boxShadow: [
        BoxShadow(
          color: ViewveeColors.violet.withValues(alpha: 0.28),
          blurRadius: 28,
          offset: const Offset(0, 12),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(19),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    ViewveeColors.navy.withValues(alpha: 0.16),
                    ViewveeColors.navy.withValues(alpha: 0.32),
                  ],
                ),
              ),
            ),
          ),
          const Positioned(
            top: -34,
            right: -28,
            child: _PremiumGlow(size: 130),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            color: Colors.white,
                            size: 15,
                          ),
                          SizedBox(width: 6),
                          VvText(
                            'VIEWVEE PREMIUM',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.7,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const VvText(
                  'Víc klidu. Bez omezení.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 25,
                    height: 1.08,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                VvText(
                  'Vše, co potřebujete pro spolehlivé sledování doma i na cestách.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    VvText(
                      NumberFormat.currency(
                        locale: Localizations.localeOf(context).toLanguageTag(),
                        name: 'EUR',
                        symbol: '€',
                        decimalDigits: 2,
                      ).format(9.99),
                      key: const Key('premiumLocalizedPrice'),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        height: 1,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: VvText(
                        'jednou navždy',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.74),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.13),
                    ),
                  ),
                  child: Column(
                    children: [
                      for (var index = 0; index < features.length; index++) ...[
                        _PremiumFeatureRow(feature: features[index]),
                        if (index != features.length - 1)
                          Divider(
                            height: 1,
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('startSubscriptionButton'),
                  onPressed: () {},
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: ViewveeColors.violet,
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  icon: const Icon(Icons.workspace_premium_rounded),
                  label: const VvText('Získat Premium'),
                ),
                const SizedBox(height: 11),
                VvText(
                  'Jedna platba  •  Žádné předplatné  •  Navždy vaše',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.68),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _PremiumFeatureRow extends StatelessWidget {
  const _PremiumFeatureRow({required this.feature});

  final _PlanFeature feature;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 11),
    child: Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(feature.icon, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: VvText(
            feature.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Icon(
          Icons.check_circle_rounded,
          color: Colors.white.withValues(alpha: 0.78),
          size: 19,
        ),
      ],
    ),
  );
}

class _PremiumGlow extends StatelessWidget {
  const _PremiumGlow({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white.withValues(alpha: 0.08),
    ),
  );
}

class _FreePlanCard extends StatelessWidget {
  const _FreePlanCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.features,
  });

  final String title;
  final String subtitle;
  final Color color;
  final List<_PlanFeature> features;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: color.withValues(alpha: 0.2)),
      boxShadow: [
        BoxShadow(
          color: ViewveeColors.navy.withValues(alpha: 0.05),
          blurRadius: 18,
          offset: const Offset(0, 7),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.person_outline_rounded, color: color, size: 23),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: VvText(
                title,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: VvText(
                subtitle,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 17),
        Container(
          key: const Key('freePlanMonitoringSummary'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.075),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(features[0].icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    VvText(
                      features[0].text,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    VvText(
                      features[4].text,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12.5,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              for (var index = 1; index <= 3; index++) ...[
                _FreePlanFeatureRow(feature: features[index], color: color),
                if (index != 3)
                  Divider(
                    height: 1,
                    indent: 52,
                    color: Theme.of(context).colorScheme.outline,
                  ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _FreePlanFeatureRow extends StatelessWidget {
  const _FreePlanFeatureRow({required this.feature, required this.color});

  final _PlanFeature feature;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
    child: Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(feature.icon, color: color, size: 17),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: VvText(
            feature.text,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 13,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class _PlanFeature {
  const _PlanFeature(this.icon, this.text);

  final IconData icon;
  final String text;
}

class _SupportPage extends StatelessWidget {
  const _SupportPage({required this.name, required this.email});

  final String name;
  final String email;

  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('supportPage'),
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
    children: [
      const _PageIntro(
        icon: Icons.support_agent_rounded,
        color: ViewveeColors.violet,
        title: 'Jak vám můžeme pomoci?',
        subtitle: 'Vyberte nejrychlejší cestu k odpovědi nebo nám napište.',
      ),
      const SizedBox(height: 24),
      const _SectionLabel('KONTAKT'),
      const SizedBox(height: 8),
      _SettingsGroup(
        children: [
          _MenuTile(
            key: const Key('contactSupportItem'),
            icon: Icons.chat_bubble_outline_rounded,
            color: ViewveeColors.teal,
            title: 'Kontaktovat podporu',
            subtitle: 'Odpovíme obvykle do 24 hodin',
            onTap: () => _showContactForm(context),
          ),
        ],
      ),
      const SizedBox(height: 24),
      const _SectionLabel('NÁPOVĚDA'),
      const SizedBox(height: 8),
      _SettingsGroup(
        children: [
          _MenuTile(
            key: const Key('faqItem'),
            icon: Icons.quiz_outlined,
            color: ViewveeColors.blue,
            title: 'Časté dotazy',
            subtitle: 'Rychlé odpovědi a praktické tipy',
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const _FaqPage())),
          ),
        ],
      ),
      const SizedBox(height: 24),
      const _SectionLabel('APLIKACE'),
      const SizedBox(height: 8),
      _SettingsGroup(
        children: [
          _MenuTile(
            key: const Key('rateAppItem'),
            icon: Icons.star_outline_rounded,
            color: ViewveeColors.teal,
            title: 'Ohodnotit aplikaci',
            subtitle: 'Řekněte nám, jak se vám ViewVee líbí',
            onTap: () => _showRating(context),
          ),
        ],
      ),
    ],
  );

  Future<void> _showContactForm(BuildContext context) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _ContactSupportSheet(name: name, email: email),
      );

  Future<void> _showRating(BuildContext context) async {
    final rating = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const _RatingSheet(),
    );
    if (rating == null) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('feedback.appRating', rating);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: VvText('Děkujeme za vaše hodnocení.')),
    );
  }
}

class _ContactSupportSheet extends StatefulWidget {
  const _ContactSupportSheet({required this.name, required this.email});

  final String name;
  final String email;

  @override
  State<_ContactSupportSheet> createState() => _ContactSupportSheetState();
}

class _ContactSupportSheetState extends State<_ContactSupportSheet> {
  static const _supportDescription = 'Popište nám, s čím potřebujete pomoci.';
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  late final TextEditingController _subjectController;
  late final TextEditingController _messageController;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
    _emailController = TextEditingController(text: widget.email);
    _subjectController = TextEditingController();
    _messageController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _subjectController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VvText(
                'Kontaktovat podporu',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              VvText(
                _supportDescription,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                key: const Key('supportRecipientInfo'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: ViewveeColors.teal.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: ViewveeColors.teal.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.alternate_email_rounded,
                      color: ViewveeColors.teal,
                      size: 21,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          VvText(
                            'Zpráva bude odeslána na',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 2),
                          VvText(
                            'support@specterint.com',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              TextFormField(
                key: const Key('supportNameField'),
                controller: _nameController,
                enabled: !_sending,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: context.vv('Jméno')),
                validator: _requiredField,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('supportEmailField'),
                controller: _emailController,
                enabled: !_sending,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                decoration: InputDecoration(labelText: context.vv('E-mail')),
                validator: (value) {
                  final email = value?.trim() ?? '';
                  if (email.isEmpty) return context.vv('Toto pole je povinné');
                  if (!email.contains('@') || !email.contains('.')) {
                    return context.vv('Zadejte platný e-mail.');
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('supportSubjectField'),
                controller: _subjectController,
                enabled: !_sending,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: context.vv('Předmět')),
                validator: _requiredField,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('supportMessageField'),
                controller: _messageController,
                enabled: !_sending,
                minLines: 4,
                maxLines: 7,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: context.vv('Zpráva')),
                validator: (value) {
                  if ((value?.trim().length ?? 0) < 10) {
                    return context.vv('Toto pole je povinné');
                  }
                  return null;
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                VvText(
                  _error!,
                  key: const Key('supportFormError'),
                  style: const TextStyle(color: Color(0xFFB3261E)),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('sendSupportMessageButton'),
                onPressed: _sending ? null : _send,
                icon: const Icon(Icons.send_rounded),
                label: const VvText('Odeslat zprávu'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  String? _requiredField(String? value) => value == null || value.trim().isEmpty
      ? context.vv('Toto pole je povinné')
      : null;

  Future<void> _send() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final body =
        '${_messageController.text.trim()}\n\n'
        '${context.vv('Jméno')}: ${_nameController.text.trim()}\n'
        '${context.vv('E-mail')}: ${_emailController.text.trim()}';
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@specterint.com',
      queryParameters: {
        'subject': '[ViewVee] ${_subjectController.text.trim()}',
        'body': body,
      },
    );
    var opened = false;
    try {
      opened = await launchUrl(uri);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    if (opened) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _sending = false;
        _error = context.vv('Něco se pokazilo. Zkuste to prosím znovu.');
      });
    }
  }
}

class _RatingSheet extends StatefulWidget {
  const _RatingSheet();

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  int _rating = 0;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      key: const Key('ratingColorHeader'),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            ViewveeColors.navy,
            Color(0xFF075F75),
            ViewveeColors.blue,
            ViewveeColors.violet,
          ],
          stops: [0, 0.34, 0.68, 1],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.44),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                  ),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Padding(
                      padding: EdgeInsets.all(7),
                      child: ViewveeMark(size: 42),
                    ),
                  ),
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      VvText(
                        'Jak se vám ViewVee líbí?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          height: 1.15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 5),
                      VvText(
                        'Vaše hodnocení nám pomáhá aplikaci zlepšovat.',
                        style: TextStyle(
                          color: Color(0xD9FFFFFF),
                          fontSize: 13,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            VvText(
              _ratingLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var value = 1; value <= 5; value++)
                    IconButton(
                      key: Key('ratingStar$value'),
                      tooltip: '$value / 5',
                      onPressed: () => setState(() => _rating = value),
                      iconSize: 38,
                      color: value <= _rating
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.4),
                      icon: Icon(
                        value <= _rating
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              key: const Key('submitRatingButton'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: ViewveeColors.violet,
                disabledBackgroundColor: Colors.white.withValues(alpha: 0.2),
                disabledForegroundColor: Colors.white.withValues(alpha: 0.55),
                minimumSize: const Size.fromHeight(52),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              onPressed: _rating == 0
                  ? null
                  : () => Navigator.of(context).pop(_rating),
              child: const VvText('Odeslat hodnocení'),
            ),
          ],
        ),
      ),
    ),
  );

  String get _ratingLabel =>
      _rating == 0 ? 'Jak se vám ViewVee líbí?' : 'Děkujeme za vaše hodnocení.';
}

class _FaqPage extends StatelessWidget {
  const _FaqPage();

  static const _questions = [
    (
      icon: Icons.devices_rounded,
      question: 'Kolik telefonů potřebuji?',
      answer:
          'Potřebujete dva telefony. Jeden slouží jako kamera a druhý jako monitor, na kterém sledujete živý přenos.',
    ),
    (
      icon: Icons.qr_code_scanner_rounded,
      question: 'Jak telefony spáruji?',
      answer:
          'Na telefonu s kamerou zobrazte párovací QR kód. Na telefonu, který používáte jako monitor, zvolte Přidat zařízení a QR kód naskenujte. Můžete také zkopírovat a vložit bezpečný párovací odkaz.',
    ),
    (
      icon: Icons.wifi_rounded,
      question: 'Musí být oba telefony na stejné Wi-Fi?',
      answer:
          'Bezplatný tarif funguje mezi telefony na stejné Wi-Fi. S Premium můžete sledovat také přes internet a mobilní data mimo domov.',
    ),
    (
      icon: Icons.lock_outline_rounded,
      question: 'Je přenos obrazu a zvuku bezpečný?',
      answer:
          'Ano. Párování používá jednorázové bezpečné údaje a přenos mezi spárovanými zařízeními je šifrovaný. Párovací odkaz neposílejte lidem, kterým nedůvěřujete.',
    ),
    (
      icon: Icons.videocam_off_outlined,
      question: 'Proč nefunguje obraz nebo zvuk?',
      answer:
          'Zkontrolujte připojení k internetu nebo Wi-Fi a povolení kamery a mikrofonu v nastavení telefonu. Potom zkuste zařízení znovu spárovat.',
    ),
    (
      icon: Icons.visibility_outlined,
      question: 'Jak změním režim sledování?',
      answer:
          'Otevřete boční menu, klepněte na Režim sledování a vyberte Dítě, Mazlíček nebo Domov. Změna se uloží automaticky.',
    ),
    (
      icon: Icons.workspace_premium_outlined,
      question: 'Co získám s ViewVee Premium?',
      answer:
          'Premium nabízí sledování přes internet a mobilní data, HD video, nahrávání, obousměrný zvuk, spojení bez časového limitu a používání bez reklam. Jde o jednorázovou platbu.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const VvText(
        'Časté dotazy',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      leading: IconButton(
        tooltip: context.vv('Zpět'),
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back_rounded),
      ),
    ),
    body: SafeArea(
      top: false,
      child: ListView(
        key: const Key('faqPage'),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: [
          const _PageIntro(
            icon: Icons.quiz_outlined,
            color: ViewveeColors.blue,
            title: 'Rychlé odpovědi',
            subtitle: 'Nejčastější otázky k používání ViewVee.',
          ),
          const SizedBox(height: 20),
          for (var index = 0; index < _questions.length; index++) ...[
            _FaqItem(
              key: Key('faqQuestion$index'),
              icon: _questions[index].icon,
              question: _questions[index].question,
              answer: _questions[index].answer,
            ),
            if (index != _questions.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    ),
  );
}

class _FaqItem extends StatelessWidget {
  const _FaqItem({
    super.key,
    required this.icon,
    required this.question,
    required this.answer,
  });

  final IconData icon;
  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: ViewveeColors.blue.withValues(alpha: 0.2)),
    ),
    child: ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      leading: _MenuIcon(icon: icon, color: ViewveeColors.blue),
      title: VvText(
        question,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      iconColor: ViewveeColors.blue,
      collapsedIconColor: Theme.of(context).colorScheme.onSurfaceVariant,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: VvText(
            answer,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
}
