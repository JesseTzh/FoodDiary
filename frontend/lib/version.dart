/// Release builds inject Ver:yymmdd-hhmm-gitsha (Asia/Shanghai) via build-flutter.sh.
const appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'Ver:dev',
);

/// Full Git revision shared by the APK, release manifest, and backend image.
const appBuildCommit = String.fromEnvironment(
  'APP_BUILD_COMMIT',
  defaultValue: 'dev',
);
