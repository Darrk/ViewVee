import 'package:flutter/material.dart';

import '../localization/viewvee_localizations.dart';

class ViewveeLogo extends StatelessWidget {
  const ViewveeLogo({
    super.key,
    this.width = 280,
    this.useDarkBackground = false,
  });

  final double width;
  final bool useDarkBackground;

  @override
  Widget build(BuildContext context) {
    final isDarkVersion =
        useDarkBackground && Theme.of(context).brightness == Brightness.dark;
    final logoHeight = width * 0.66;
    final iconSize = width * 0.34;
    return SizedBox(
      width: width,
      height: logoHeight,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: width * 0.015),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(iconSize * 0.2),
                child: Image.asset(
                  isDarkVersion
                      ? 'assets/branding/viewvee_icon_dark.png'
                      : 'assets/branding/viewvee_icon_foreground.png',
                  width: iconSize,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
            SizedBox(height: width * 0.012),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: VvText(
                'ViewVee',
                maxLines: 1,
                style: TextStyle(
                  color: isDarkVersion
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurface,
                  fontSize: width * 0.155,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1,
                ),
              ),
            ),
            SizedBox(height: width * 0.018),
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [
                  Color(0xFF13C9B7),
                  Color(0xFF3799E8),
                  Color(0xFF8150F4),
                ],
              ).createShader(bounds),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: VvText(
                  'SEE MORE. CARE MORE.',
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: width * 0.041,
                    fontWeight: FontWeight.w800,
                    letterSpacing: width * 0.012,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ViewveeMark extends StatelessWidget {
  const ViewveeMark({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/viewvee_icon_foreground.png',
    width: size,
    height: size,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
  );
}

class AnimatedViewveeLogo extends StatefulWidget {
  const AnimatedViewveeLogo({super.key, this.width = 320});

  final double width;

  @override
  State<AnimatedViewveeLogo> createState() => _AnimatedViewveeLogoState();
}

class _AnimatedViewveeLogoState extends State<AnimatedViewveeLogo>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final AnimationController _effectController;
  late final Animation<double> _entrance;
  late final Animation<double> _eyeTurns;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
    _effectController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _entrance = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOutBack,
    );
    _eyeTurns = CurvedAnimation(
      parent: _effectController,
      curve: Curves.linear,
    );
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _effectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final eyeSize = width * 0.136;

    return FadeTransition(
      opacity: _entranceController,
      child: ScaleTransition(
        scale: Tween(begin: 0.9, end: 1.0).animate(_entrance),
        child: SizedBox(
          key: const Key('animatedSplashLogo'),
          width: width,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ViewveeLogo(width: width),
              Positioned(
                left: width * 0.432,
                top: width * 0.17,
                child: _AnimatedEyeHighlight(size: eyeSize, turns: _eyeTurns),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnimatedEyeHighlight extends StatelessWidget {
  const _AnimatedEyeHighlight({required this.size, required this.turns});

  final double size;
  final Animation<double> turns;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      children: [
        Positioned(
          left: size * 0.255,
          top: size * 0.295,
          child: Container(
            width: size * 0.56,
            height: size * 0.56,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: Alignment(0.45, -0.45),
                radius: 1.05,
                colors: [
                  Color(0xFF293653),
                  Color(0xFF17223E),
                  Color(0xFF071127),
                ],
                stops: [0, 0.58, 1],
              ),
            ),
          ),
        ),
        Positioned(
          left: size * 0.19,
          top: size * 0.26,
          width: size * 0.62,
          height: size * 0.62,
          child: RotationTransition(
            turns: turns,
            child: Align(
              alignment: Alignment.topRight,
              child: Container(
                key: const Key('animatedEyeHighlight'),
                width: size * 0.22,
                height: size * 0.22,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
