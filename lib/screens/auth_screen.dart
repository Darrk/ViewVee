import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_repository.dart';
import '../config.dart';
import '../theme/viewvee_theme.dart';
import '../widgets/viewvee_logo.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    required this.authRepository,
    required this.onAuthenticated,
  });

  final AuthRepository authRepository;
  final VoidCallback onAuthenticated;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _forgotPasswordFormKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmationController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  _AuthView _view = _AuthView.choices;
  bool _loading = false;
  bool _obscurePassword = true;
  bool _termsAccepted = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    widget.authRepository.getLastEmail().then((email) {
      if (!mounted || _emailController.text.isNotEmpty) return;
      setState(() => _emailController.text = email.trim());
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _passwordConfirmationController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _formError = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final email = _emailController.text;
      final password = _passwordController.text;
      if (_view == _AuthView.register) {
        if (!_termsAccepted) {
          setState(() => _formError = context.vv('Toto pole je povinné'));
          return;
        }
        await widget.authRepository.register(
          email: email,
          password: password,
          firstName: _firstNameController.text,
          lastName: _lastNameController.text,
        );
      } else {
        await widget.authRepository.signIn(email: email, password: password);
      }
      widget.onAuthenticated();
    } on AuthException catch (error) {
      if (mounted) setState(() => _formError = context.vvError(error.message));
    } on Exception {
      if (mounted) {
        setState(
          () => _formError = context.vv(
            'Něco se pokazilo. Zkuste to prosím znovu.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signInWithProvider(AuthProvider provider) async {
    setState(() => _loading = true);
    try {
      await widget.authRepository.signInWithProvider(provider);
      widget.onAuthenticated();
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.vvError(error.message))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _continueAsGuest() async {
    setState(() => _loading = true);
    await widget.authRepository.continueAsGuest();
    if (!mounted) return;
    widget.onAuthenticated();
  }

  Future<void> _forgotPassword() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _formError = null);
    if (!_forgotPasswordFormKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await widget.authRepository.forgotPassword(_emailController.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: VvText('Pokyny pro obnovu hesla byly odeslány.'),
          ),
        );
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.vvError(error.message))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _clearFormError(String _) {
    if (_formError != null) setState(() => _formError = null);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.04, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: _view == _AuthView.choices
                    ? _buildChoices()
                    : _view == _AuthView.forgotPassword
                    ? _buildForgotPasswordForm(colors)
                    : _buildForm(colors),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChoices() {
    return Column(
      key: const ValueKey('authChoices'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: ViewveeLogo(width: 300, useDarkBackground: true)),
        const SizedBox(height: 28),
        VvText(
          'Spolehlivý dohled, ať jste kdekoliv.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 18,
            height: 1.4,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 18),
        const Center(child: _BrandAccent()),
        const SizedBox(height: 40),
        _BrandGradientButton(
          key: const Key('openSignIn'),
          onPressed: _loading
              ? null
              : () => setState(() => _view = _AuthView.signIn),
          icon: Icons.login_rounded,
          label: 'Přihlásit se',
        ),
        const SizedBox(height: 14),
        _BrandOutlineButton(
          key: const Key('openRegister'),
          onPressed: _loading
              ? null
              : () => setState(() => _view = _AuthView.register),
          icon: Icons.person_add_alt_rounded,
          label: 'Registrace',
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: const Key('continueAsGuest'),
          onPressed: _loading ? null : _continueAsGuest,
          icon: const Icon(Icons.person_outline_rounded),
          label: const VvText('Pokračovat bez přihlášení'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            foregroundColor: Theme.of(context).colorScheme.onSurface,
            backgroundColor: Theme.of(context).colorScheme.surface,
            side: BorderSide(color: Theme.of(context).colorScheme.outline),
          ),
        ),
        const SizedBox(height: 34),
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: VvText(
                'NEBO',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (Platform.isIOS)
              _SocialIconButton(
                key: const Key('signInApple'),
                icon: const FaIcon(FontAwesomeIcons.apple, size: 23),
                label: 'Pokračovat přes Apple',
                foregroundColor: Colors.black,
                backgroundColor: Colors.white,
                borderColor: ViewveeColors.outline,
                onPressed: _loading
                    ? null
                    : () => _signInWithProvider(AuthProvider.apple),
              ),
            if (Config.showFacebookLogin) ...[
              const SizedBox(width: 22),
              _SocialIconButton(
                key: const Key('signInFacebook'),
                icon: const FaIcon(
                  FontAwesomeIcons.facebookF,
                  size: 22,
                  color: Colors.white,
                ),
                label: 'Pokračovat přes Facebook',
                foregroundColor: Colors.white,
                backgroundColor: const Color(0xFF1877F2),
                borderColor: const Color(0xFF1877F2),
                onPressed: _loading
                    ? null
                    : () => _signInWithProvider(AuthProvider.facebook),
              ),
            ],
            if (Config.showGoogleLogin) ...[
              const SizedBox(width: 22),
              _SocialIconButton(
                key: const Key('signInGoogle'),
                icon: Image.asset(
                  'assets/branding/google_g_logo.png',
                  width: 23,
                  height: 23,
                  filterQuality: FilterQuality.high,
                ),
                label: 'Pokračovat přes Google',
                foregroundColor: Colors.black,
                backgroundColor: Colors.white,
                borderColor: ViewveeColors.outline,
                onPressed: _loading
                    ? null
                    : () => _signInWithProvider(AuthProvider.google),
              ),
            ],
          ],
        ),
        if (_loading) ...[
          const SizedBox(height: 20),
          const Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: ViewveeColors.teal,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildForm(ColorScheme colors) {
    final registering = _view == _AuthView.register;
    return Form(
      key: _formKey,
      child: Column(
        key: ValueKey(_view),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: colors.outline),
              ),
              child: IconButton(
                key: const Key('authBackButton'),
                tooltip: context.vv('Zpět'),
                onPressed: _loading
                    ? null
                    : () => setState(() => _view = _AuthView.choices),
                icon: const Icon(
                  Icons.arrow_back_rounded,
                  color: ViewveeColors.navy,
                ),
              ),
            ),
          ),
          const Center(child: ViewveeLogo(width: 220, useDarkBackground: true)),
          const SizedBox(height: 32),
          VvText(
            registering ? 'Registrace' : 'Přihlášení',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 24),
          TextFormField(
            key: const Key('emailField'),
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: context.vv('E-mail'),
              prefixIcon: const Icon(Icons.mail_outline_rounded),
            ),
            onChanged: _clearFormError,
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
            key: const Key('passwordField'),
            controller: _passwordController,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: context.vv('Heslo'),
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                tooltip: context.vv('Heslo'),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            onChanged: _clearFormError,
            validator: (value) {
              if (value == null || value.isEmpty) {
                return context.vv('Toto pole je povinné');
              }
              if (value.length < 8) {
                return context.vv('Heslo musí mít alespoň 8 znaků.');
              }
              return null;
            },
          ),
          if (registering) ...[
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('passwordConfirmationField'),
              controller: _passwordConfirmationController,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: context.vv('Heslo znovu'),
                prefixIcon: const Icon(Icons.lock_reset_rounded),
              ),
              onChanged: _clearFormError,
              validator: (value) => value != _passwordController.text
                  ? context.vv('Hesla se neshodují.')
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('firstNameField'),
              controller: _firstNameController,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: context.vv('Křestní jméno'),
                prefixIcon: const Icon(Icons.person_outline_rounded),
              ),
              onChanged: _clearFormError,
              validator: (value) => value == null || value.trim().isEmpty
                  ? context.vv('Toto pole je povinné')
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('lastNameField'),
              controller: _lastNameController,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: context.vv('Příjmení'),
                prefixIcon: const Icon(Icons.badge_outlined),
              ),
              onChanged: _clearFormError,
              validator: (value) => value == null || value.trim().isEmpty
                  ? context.vv('Toto pole je povinné')
                  : null,
            ),
            const SizedBox(height: 10),
            CheckboxListTile(
              key: const Key('termsAccepted'),
              value: _termsAccepted,
              onChanged: _loading
                  ? null
                  : (value) => setState(() {
                      _termsAccepted = value ?? false;
                      _formError = null;
                    }),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const VvText('Souhlasím s podmínkami použití'),
            ),
            TextButton(
              onPressed: () =>
                  launchUrl(Uri.parse('https://viewvee.com/terms-of-use.html')),
              child: const VvText('Přečíst podmínky použití'),
            ),
          ],
          const SizedBox(height: 12),
          if (!registering)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _loading
                    ? null
                    : () => setState(() {
                        _formError = null;
                        _view = _AuthView.forgotPassword;
                      }),
                child: const VvText('Zapomenuté heslo?'),
              ),
            ),
          if (_formError != null) ...[
            const SizedBox(height: 8),
            _AuthErrorMessage(message: _formError!),
            const SizedBox(height: 16),
          ],
          _BrandGradientButton(
            key: const Key('authSubmit'),
            onPressed: _loading ? null : _submit,
            icon: registering ? Icons.person_add_alt : Icons.login,
            label: registering ? 'Registrace' : 'Přihlásit se',
            loading: _loading,
          ),
          TextButton(
            onPressed: _loading
                ? null
                : () => setState(
                    () => _view = registering
                        ? _AuthView.signIn
                        : _AuthView.register,
                  ),
            child: VvText(registering ? 'Zpět na přihlášení' : 'Registrace'),
          ),
        ],
      ),
    );
  }

  Widget _buildForgotPasswordForm(ColorScheme colors) {
    return Form(
      key: _forgotPasswordFormKey,
      child: Column(
        key: const ValueKey(_AuthView.forgotPassword),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: colors.outline),
              ),
              child: IconButton(
                key: const Key('forgotPasswordBackButton'),
                tooltip: context.vv('Zpět na přihlášení'),
                onPressed: _loading
                    ? null
                    : () => setState(() {
                        _formError = null;
                        _view = _AuthView.signIn;
                      }),
                icon: const Icon(
                  Icons.arrow_back_rounded,
                  color: ViewveeColors.navy,
                ),
              ),
            ),
          ),
          const Center(child: ViewveeLogo(width: 220, useDarkBackground: true)),
          const SizedBox(height: 28),
          const VvText(
            'Zapomenuté heslo?',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 24),
          TextFormField(
            key: const Key('forgotPasswordEmailField'),
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) {
              if (!_loading) _forgotPassword();
            },
            decoration: InputDecoration(
              labelText: context.vv('E-mail'),
              prefixIcon: const Icon(Icons.mail_outline_rounded),
            ),
            onChanged: _clearFormError,
            validator: (value) {
              final email = value?.trim() ?? '';
              if (email.isEmpty) return context.vv('Toto pole je povinné');
              if (!email.contains('@') || !email.contains('.')) {
                return context.vv('Zadejte platný e-mail.');
              }
              return null;
            },
          ),
          if (_formError != null) ...[
            const SizedBox(height: 16),
            _AuthErrorMessage(message: _formError!),
          ],
          const SizedBox(height: 20),
          _BrandGradientButton(
            key: const Key('forgotPasswordSubmit'),
            onPressed: _loading ? null : _forgotPassword,
            icon: Icons.mark_email_read_outlined,
            label: 'Odeslat',
            loading: _loading,
          ),
          TextButton(
            onPressed: _loading
                ? null
                : () => setState(() {
                    _formError = null;
                    _view = _AuthView.signIn;
                  }),
            child: const VvText('Zpět na přihlášení'),
          ),
        ],
      ),
    );
  }
}

enum _AuthView { choices, signIn, register, forgotPassword }

class _BrandAccent extends StatelessWidget {
  const _BrandAccent();

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    height: 4,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [ViewveeColors.teal, ViewveeColors.blue, ViewveeColors.violet],
      ),
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

class _BrandGradientButton extends StatelessWidget {
  const _BrandGradientButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: onPressed == null
          ? LinearGradient(
              colors: Theme.of(context).brightness == Brightness.dark
                  ? const [Color(0xFF26364D), Color(0xFF1B293C)]
                  : const [Color(0xFFB8C7D4), Color(0xFFD2D7E0)],
            )
          : const LinearGradient(
              colors: [
                ViewveeColors.teal,
                ViewveeColors.blue,
                ViewveeColors.violet,
              ],
            ),
      borderRadius: BorderRadius.circular(8),
      boxShadow: onPressed == null
          ? null
          : [
              BoxShadow(
                color: ViewveeColors.blue.withValues(alpha: 0.2),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 54,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else
                Icon(icon, color: Colors.white, size: 21),
              const SizedBox(width: 10),
              VvText(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AuthErrorMessage extends StatelessWidget {
  const _AuthErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF2F1),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFF2C4BF)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline_rounded, color: Color(0xFFB3261E)),
        const SizedBox(width: 10),
        Expanded(
          child: VvText(
            message,
            style: const TextStyle(color: Color(0xFF7A211B), height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class _BrandOutlineButton extends StatelessWidget {
  const _BrandOutlineButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: onPressed == null
            ? const [ViewveeColors.outline, ViewveeColors.outline]
            : const [
                ViewveeColors.teal,
                ViewveeColors.blue,
                ViewveeColors.violet,
              ],
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.all(1.5),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(7),
          child: SizedBox(
            height: 51,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  color: Theme.of(context).colorScheme.onSurface,
                  size: 21,
                ),
                const SizedBox(width: 10),
                VvText(
                  label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _SocialIconButton extends StatelessWidget {
  const _SocialIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.foregroundColor,
    required this.backgroundColor,
    required this.onPressed,
    this.borderColor,
  });

  final Widget icon;
  final String label;
  final Color foregroundColor;
  final Color backgroundColor;
  final Color? borderColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Tooltip(
      message: label,
      child: IconButton(
        onPressed: onPressed,
        icon: icon,
        style: IconButton.styleFrom(
          fixedSize: const Size.square(54),
          foregroundColor: foregroundColor,
          backgroundColor: backgroundColor,
          disabledBackgroundColor: backgroundColor.withValues(alpha: 0.45),
          side: BorderSide(color: borderColor ?? backgroundColor),
          shape: const CircleBorder(),
          elevation: 1,
          shadowColor: ViewveeColors.blue.withValues(alpha: 0.16),
        ),
      ),
    ),
  );
}
