import 'dart:async';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/v2board/brand_config.dart';
import 'package:fl_clash/features/v2board/v2board_client.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class V2BoardGate extends ConsumerStatefulWidget {
  const V2BoardGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<V2BoardGate> createState() => _V2BoardGateState();
}

class _V2BoardGateState extends ConsumerState<V2BoardGate> {
  late final V2BoardClient _client;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  V2BoardSession? _session;
  Object? _error;
  bool _initializing = true;
  bool _submitting = false;
  bool _authenticated = false;
  bool _obscurePassword = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _client = V2BoardClient();
    unawaited(_restoreSession());
  }

  Future<void> _restoreSession() async {
    try {
      final session = await V2BoardClient.loadSession();
      if (!mounted) return;
      if (session == null) {
        await _stopProxy();
        if (!mounted) return;
        setState(() => _initializing = false);
        return;
      }
      _emailController.text = session.email;
      _session = session;
      await _syncSubscription(session);
    } on V2BoardException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        await V2BoardClient.clearSession();
        _session = null;
      }
      await _stopProxy();
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      await _stopProxy();
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = '恢复登录状态失败：$error';
      });
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = '请输入有效的邮箱地址');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final session = await _client.login(email: email, password: password);
      _passwordController.clear();
      _session = session;
      await _importSubscription(session);
      if (!mounted) return;
      setState(() {
        _authenticated = true;
        _error = null;
      });
      _startRefreshTimer();
    } on V2BoardException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '登录失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _initializing = false;
        });
      }
    }
  }

  Future<void> _syncSubscription(V2BoardSession session) async {
    try {
      final subscribeUrl = await _client.refreshSubscribeUrl(session);
      final refreshed = session.copyWith(
        subscribeUrl: subscribeUrl,
        updatedAt: DateTime.now(),
      );
      _session = refreshed;
      await _importSubscription(refreshed);
      if (!mounted) return;
      setState(() {
        _authenticated = true;
        _initializing = false;
        _error = null;
      });
      _startRefreshTimer();
    } on V2BoardException catch (error) {
      if (error.isUnauthorized) {
        await V2BoardClient.clearSession();
        _session = null;
      }
      rethrow;
    }
  }

  Future<void> _importSubscription(V2BoardSession session) async {
    final profiles = ref.read(profilesProvider);
    final label = BrandConfig.profileLabel(session.email);
    Profile? managed;
    for (final profile in profiles) {
      if (profile.label == label && profile.type == ProfileType.url) {
        managed = profile;
        break;
      }
    }
    final action = ref.read(profilesActionProvider.notifier);
    if (managed == null) {
      await action.addProfileFromLink(
        session.subscribeUrl,
        label: label,
        showProfiles: false,
      );
      return;
    }
    final updated = managed.copyWith(
      url: session.subscribeUrl,
      autoUpdate: true,
    );
    await action.updateProfile(updated);
  }

  void _startRefreshTimer() {
    _refreshTimer ??= Timer.periodic(
      const Duration(minutes: 20),
      (_) => unawaited(_refreshSubscriptionInBackground()),
    );
  }

  Future<void> _refreshSubscriptionInBackground() async {
    final session = _session;
    if (session == null || !_authenticated || _submitting) return;
    try {
      final subscribeUrl = await _client.refreshSubscribeUrl(session);
      if (subscribeUrl == session.subscribeUrl) return;
      final refreshed = session.copyWith(
        subscribeUrl: subscribeUrl,
        updatedAt: DateTime.now(),
      );
      _session = refreshed;
      await _importSubscription(refreshed);
    } on V2BoardException catch (error) {
      if (error.isUnauthorized && mounted) {
        await _logout();
      }
    } catch (_) {
      // Keep the current profile usable when a background refresh is offline.
    }
  }

  Future<void> _stopProxy() async {
    try {
      await ref.read(setupActionProvider.notifier).setRunning(false);
    } catch (_) {
      // The login gate must still be usable if the Core is already gone.
    }
  }

  Future<void> _logout() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await V2BoardClient.clearSession();
    await _stopProxy();
    if (!mounted) return;
    setState(() {
      _authenticated = false;
      _session = null;
      _error = null;
      _initializing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_authenticated) {
      return Stack(
        children: [
          widget.child,
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: Tooltip(
                message: '退出当前账号',
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: () => unawaited(_logout()),
                    icon: const Icon(Icons.logout),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (_initializing) return const _V2BoardLoadingView();
    return _V2BoardLoginView(
      appName: BrandConfig.appName,
      tagline: BrandConfig.tagline,
      emailController: _emailController,
      passwordController: _passwordController,
      obscurePassword: _obscurePassword,
      loading: _submitting,
      error: _error?.toString(),
      hasSession: _session != null,
      onTogglePassword: () {
        setState(() => _obscurePassword = !_obscurePassword);
      },
      onSubmit: _session != null && _error != null ? _syncExisting : _submit,
      onLogout: _session == null
          ? null
          : () {
              unawaited(_logout());
            },
    );
  }

  Future<void> _syncExisting() async {
    final session = _session;
    if (session == null || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _syncSubscription(session);
    } on V2BoardException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '订阅同步失败：$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }
}

class _V2BoardLoadingView extends StatelessWidget {
  const _V2BoardLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _V2BoardLoginView extends StatelessWidget {
  const _V2BoardLoginView({
    required this.appName,
    required this.tagline,
    required this.emailController,
    required this.passwordController,
    required this.obscurePassword,
    required this.loading,
    required this.error,
    required this.hasSession,
    required this.onTogglePassword,
    required this.onSubmit,
    required this.onLogout,
  });

  final String appName;
  final String tagline;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool obscurePassword;
  final bool loading;
  final String? error;
  final bool hasSession;
  final VoidCallback onTogglePassword;
  final VoidCallback onSubmit;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Card(
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Image.asset(
                          'assets/images/icon.png',
                          width: 64,
                          height: 64,
                          errorBuilder: (_, _, _) => Icon(
                            Icons.shield_outlined,
                            size: 56,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          appName,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          tagline,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 28),
                        TextField(
                          controller: emailController,
                          enabled: !loading,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [
                            AutofillHints.username,
                            AutofillHints.email,
                          ],
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: '邮箱',
                            hintText: '请输入站点账号邮箱',
                            prefixIcon: Icon(Icons.email_outlined),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: passwordController,
                          enabled: !loading,
                          obscureText: obscurePassword,
                          autofillHints: const [AutofillHints.password],
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => onSubmit(),
                          decoration: InputDecoration(
                            labelText: '密码',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              onPressed: loading ? null : onTogglePassword,
                              icon: Icon(
                                obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            error!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ],
                        const SizedBox(height: 22),
                        FilledButton(
                          onPressed: loading ? null : onSubmit,
                          child: loading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(hasSession ? '重试同步订阅' : '登录并同步订阅'),
                        ),
                        if (onLogout != null) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: loading ? null : onLogout,
                            child: const Text('退出当前账号'),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Text(
                          '使用站点账号登录，无需在 APP 内注册。',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
