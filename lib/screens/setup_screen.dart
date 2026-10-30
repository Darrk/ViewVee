import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../auth/auth_repository.dart';
import '../theme/viewvee_theme.dart';
import '../widgets/viewvee_logo.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.onSelected, this.drawer});
  final ValueChanged<WatchMode> onSelected;
  final Widget? drawer;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  WatchMode? _selectedMode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.drawer == null
          ? null
          : AppBar(
              leading: Builder(
                builder: (context) => IconButton(
                  key: const Key('setupMenuButton'),
                  tooltip: context.vv('Otevřít menu'),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                  icon: const Icon(Icons.menu_rounded),
                ),
              ),
            ),
      drawer: widget.drawer,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 420,
                  minHeight: constraints.maxHeight - 52,
                ),
                child: TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 550),
                  curve: Curves.easeOutCubic,
                  tween: Tween(begin: 0, end: 1),
                  builder: (context, value, child) => Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, 18 * (1 - value)),
                      child: child,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(
                        child: ViewVeeLogo(width: 188, useDarkBackground: true),
                      ),
                      const SizedBox(height: 26),
                      VvText(
                        'Režim sledování',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      VvText(
                        'Vyberte režim a ViewVee nastaví správnou citlivost.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 16,
                          height: 1.4,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Center(child: _BrandAccent()),
                      const SizedBox(height: 28),
                      _ModeTile(
                        key: const Key('modeBaby'),
                        icon: const FaIcon(
                          FontAwesomeIcons.babyCarriage,
                          size: 25,
                        ),
                        title: 'Dítě',
                        subtitle: 'Spánek, pláč a jemný pohyb',
                        sensitivity: 'Vysoká citlivost',
                        color: ViewVeeColors.teal,
                        selected: _selectedMode == WatchMode.baby,
                        onTap: () => _select(WatchMode.baby),
                      ),
                      const SizedBox(height: 12),
                      _ModeTile(
                        key: const Key('modePet'),
                        icon: const Icon(Icons.pets_rounded),
                        title: 'Mazlíček',
                        subtitle: 'Pohyb doma i na zahradě',
                        sensitivity: 'Vyvážená citlivost',
                        color: ViewVeeColors.blue,
                        selected: _selectedMode == WatchMode.pet,
                        onTap: () => _select(WatchMode.pet),
                      ),
                      const SizedBox(height: 12),
                      _ModeTile(
                        key: const Key('modeHome'),
                        icon: const Icon(Icons.home_rounded),
                        title: 'Domov',
                        subtitle: 'Vstup, pokoj nebo kancelář',
                        sensitivity: 'Nižší citlivost',
                        color: ViewVeeColors.violet,
                        selected: _selectedMode == WatchMode.home,
                        onTap: () => _select(WatchMode.home),
                      ),
                      const SizedBox(height: 24),
                      _ContinueButton(
                        onPressed: _selectedMode == null
                            ? null
                            : () => widget.onSelected(_selectedMode!),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _select(WatchMode mode) => setState(() => _selectedMode = mode);
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.sensitivity,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Widget icon;
  final String title;
  final String subtitle;
  final String sensitivity;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedScale(
        scale: selected ? 1 : 0.985,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.1)
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? color : Theme.of(context).colorScheme.outline,
              width: selected ? 2 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.14),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(15),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [color, color.withValues(alpha: 0.72)],
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconTheme(
                        data: const IconThemeData(
                          color: Colors.white,
                          size: 27,
                        ),
                        child: Center(child: icon),
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          VvText(
                            title,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          VvText(
                            subtitle,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          VvText(
                            sensitivity,
                            style: TextStyle(
                              color: color,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        key: ValueKey(selected),
                        color: selected ? color : ViewVeeColors.outline,
                        size: 25,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandAccent extends StatelessWidget {
  const _BrandAccent();

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    height: 4,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [ViewVeeColors.teal, ViewVeeColors.blue, ViewVeeColors.violet],
      ),
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

class _ContinueButton extends StatelessWidget {
  const _ContinueButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    decoration: BoxDecoration(
      gradient: onPressed == null
          ? LinearGradient(
              colors: Theme.of(context).brightness == Brightness.dark
                  ? const [Color(0xFF26364D), Color(0xFF1B293C)]
                  : const [Color(0xFFB8C7D4), Color(0xFFD2D7E0)],
            )
          : const LinearGradient(
              colors: [
                ViewVeeColors.teal,
                ViewVeeColors.blue,
                ViewVeeColors.violet,
              ],
            ),
      borderRadius: BorderRadius.circular(8),
      boxShadow: onPressed == null
          ? null
          : [
              BoxShadow(
                color: ViewVeeColors.blue.withValues(alpha: 0.2),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('continueSetup'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: const SizedBox(
          height: 54,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              VvText(
                'Pokračovat',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(width: 10),
              Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 21),
            ],
          ),
        ),
      ),
    ),
  );
}
