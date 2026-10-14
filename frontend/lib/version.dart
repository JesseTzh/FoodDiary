/// Build scripts can override this with --dart-define=APP_VERSION=Ver:yymmdd-hhmm-gitsha.
const appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'Ver:261014-0000-dev',
);
