// Release builds override both values from the checked pubspec version.
const String clientVersion =
    String.fromEnvironment('KENAI_APP_VERSION', defaultValue: '2.3.4');
const String clientBuildNumber =
    String.fromEnvironment('KENAI_APP_BUILD', defaultValue: '20');
