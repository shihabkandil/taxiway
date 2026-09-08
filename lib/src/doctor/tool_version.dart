/// A permissively-parsed `major.minor.patch`.
///
/// Tool version banners drift constantly and are not worth modelling
/// precisely — we only ever ask "is this at least X?". Anything past the patch
/// number (build metadata, pre-release tags, Java's fourth component) is
/// deliberately discarded.
class ToolVersion implements Comparable<ToolVersion> {
  const ToolVersion(this.major, [this.minor = 0, this.patch = 0]);

  final int major;
  final int minor;
  final int patch;

  /// Matches a version *token*: two or three dot-separated numbers.
  static final RegExp _token = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?');

  /// Parses a bare version string such as `3.35.0`.
  static ToolVersion? tryParse(String value) {
    final match = _token.firstMatch(value.trim());
    if (match == null) return null;
    return ToolVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3) ?? '0'),
    );
  }

  /// Pulls a version out of a tool's raw output.
  ///
  /// [preferLine] restricts the search to lines mentioning it, which is how the
  /// real version is told apart from noise — `gem list` prints unrelated
  /// versions in its warning preamble, and fastlane's banner contains its own
  /// install path with two version numbers in it.
  ///
  /// [highest] returns the largest match rather than the first, for tools that
  /// list every installed version on one line.
  static ToolVersion? extract(
    String output, {
    String? preferLine,
    bool highest = false,
  }) {
    var lines = _lines(output);
    if (preferLine != null) {
      final needle = preferLine.toLowerCase();
      final filtered = lines
          .where((l) => l.toLowerCase().contains(needle))
          .toList();
      if (filtered.isNotEmpty) lines = filtered;
    }

    final found = <ToolVersion>[];
    for (final line in lines) {
      for (final match in _token.allMatches(_stripPathLikeTokens(line))) {
        found.add(
          ToolVersion(
            int.parse(match.group(1)!),
            int.parse(match.group(2)!),
            int.parse(match.group(3) ?? '0'),
          ),
        );
      }
      if (found.isNotEmpty && !highest) break;
    }
    if (found.isEmpty) return null;
    if (!highest) return found.first;
    return found.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  }

  static List<String> _lines(String output) =>
      output.split(RegExp(r'\r\n|\r|\n')).where((l) => l.isNotEmpty).toList();

  /// Drops paths and URLs, whose own version-shaped segments are not the
  /// tool's version — `.../fastlane/3.4.0/gems/fastlane-2.238.0/bin/fastlane`
  /// is the single most misleading line any of these tools prints.
  static String _stripPathLikeTokens(String line) => line
      .split(RegExp(r'\s+'))
      .where((token) => !token.contains('/'))
      .join(' ');

  bool operator >=(ToolVersion other) => compareTo(other) >= 0;
  bool operator <(ToolVersion other) => compareTo(other) < 0;
  bool operator >(ToolVersion other) => compareTo(other) > 0;
  bool operator <=(ToolVersion other) => compareTo(other) <= 0;

  @override
  int compareTo(ToolVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is ToolVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}
