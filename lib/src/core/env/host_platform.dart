import 'dart:io';

/// The operating system taxiway is running on.
///
/// Distinct from `RunEnvironment`, which says what *kind* of machine this is —
/// a laptop, a disposable runner, a Mac mini. This says what the machine can
/// physically do, and there is exactly one thing it decides: whether Apple's
/// toolchain can exist here. Nothing on Linux substitutes for `xcodebuild`, the
/// login keychain or a provisioning profile.
///
/// Held as a value rather than read from [Platform] at each use, because the
/// Linux path will only ever be exercised from a Mac and a direct
/// `Platform.isMacOS` cannot be tested.
enum HostPlatform {
  macos,
  linux,
  windows,

  /// Anything else. Treated exactly like Linux: no Apple toolchain.
  other;

  static HostPlatform get current => fromName(Platform.operatingSystem);

  static HostPlatform fromName(String name) => switch (name.toLowerCase()) {
    'macos' => HostPlatform.macos,
    'linux' => HostPlatform.linux,
    'windows' => HostPlatform.windows,
    _ => HostPlatform.other,
  };

  /// Whether iOS work is possible here at all.
  ///
  /// Everything Apple is gated on this: the Xcode and CocoaPods checks, the
  /// login keychain, `taxiway build ios`. On a machine where it is false those
  /// are not failures — they are questions that do not apply, and reporting
  /// them as failures tells a user their machine cannot ship an app it can in
  /// fact ship.
  bool get canBuildIos => this == HostPlatform.macos;

  /// Whether the macOS `security` keychain exists to be read or written.
  bool get hasSecurityKeychain => this == HostPlatform.macos;

  String get label => switch (this) {
    HostPlatform.macos => 'macOS',
    HostPlatform.linux => 'Linux',
    HostPlatform.windows => 'Windows',
    HostPlatform.other => Platform.operatingSystem,
  };
}
