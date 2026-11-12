/// Build-time white-label configuration for the client.
///
/// Override values with Flutter's `--dart-define` flags, for example:
/// `--dart-define=APP_NAME=MyVPN --dart-define=V2BOARD_URL=https://panel.example.com`.
abstract final class BrandConfig {
  static const appName = String.fromEnvironment(
    'APP_NAME',
    defaultValue: '99294837',
  );
  static const apiBaseUrl = String.fromEnvironment(
    'V2BOARD_URL',
    defaultValue: 'https://free.99294837.xyz',
  );
  static const tagline = String.fromEnvironment(
    'APP_TAGLINE',
    defaultValue: '登录后自动同步订阅，简单、安全、跨平台',
  );
  static const profileLabelPrefix = String.fromEnvironment(
    'PROFILE_LABEL',
    defaultValue: '我的订阅',
  );
  static const requestTimeoutSeconds = int.fromEnvironment(
    'V2BOARD_TIMEOUT_SECONDS',
    defaultValue: 20,
  );

  static String get normalizedApiBaseUrl {
    final value = apiBaseUrl.trim();
    if (value.isEmpty) return value;
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  static String profileLabel(String email) {
    final account = email.trim();
    return account.isEmpty
        ? profileLabelPrefix
        : '$profileLabelPrefix · $account';
  }
}
