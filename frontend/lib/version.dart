/// Release builds inject Ver:yymmdd-hhmm-gitsha (Asia/Shanghai) via build-flutter.sh.
const appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'Ver:dev',
);
