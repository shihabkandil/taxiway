/// Where one step of a reported run stands.
enum StepState { pending, running, succeeded, failed, skipped, notRun }

/// One line of the step list a notification carries.
///
/// Mutable on purpose: a run's steps change state as it goes, and a live
/// message is re-rendered from whatever they say at that moment.
class ProgressStep {
  ProgressStep({required this.key, required this.label});

  final String key;
  final String label;
  StepState state = StepState.pending;
  Duration? duration;
  int? exitCode;
}
