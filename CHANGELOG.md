# Changelog

## 0.1.0-beta.1

First public beta.

- `shipway import` reads an existing Flutter project (flavors, Xcode schemes,
  Gradle, fastlane) and writes a `shipway.yaml` that describes it. It changes
  nothing else.
- `shipway generate` and `shipway adopt` write flavors, Xcode build
  configurations and schemes, and fastlane lanes. They only touch files you
  have handed over, and show a diff first.
- `shipway doctor` checks the machine: Flutter, Xcode, Ruby, the JDK,
  CocoaPods, fastlane.
- `shipway build` and `shipway release` build a flavor and send it to
  TestFlight, the App Store, Google Play or Firebase App Distribution.
- `shipway run` runs named pipelines from `shipway.yaml`, with parallel steps
  and `--resume` after a failure.
- `shipway secrets` and `shipway setup` cover signing and credentials, using
  the keychain on your own machine and environment variables in CI.
- Slack notifications: a message per event through a webhook, or one live
  message that updates as a run goes through a bot token. The message text is
  yours to write. `shipway notify test` sends a sample.
- Fixed: an installed shipway could not find its own Xcode and Gradle helper
  scripts.
