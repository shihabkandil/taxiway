/// Process exit codes used across the CLI.
///
/// These are deliberately coarse: callers and CI scripts should be able to tell
/// "you asked for something impossible" apart from "this machine isn't set up"
/// apart from "taxiway itself broke", without parsing output.
abstract final class TaxiwayExit {
  /// Everything worked.
  static const int success = 0;

  /// The user asked for something invalid: bad flags, bad config, a conflict
  /// that needs an explicit decision.
  static const int userError = 1;

  /// The machine is not able to do this: a missing or too-old tool, a failing
  /// `doctor` check.
  static const int environmentError = 2;

  /// An unexpected failure inside taxiway. Always a bug worth reporting.
  static const int internalError = 70;
}
