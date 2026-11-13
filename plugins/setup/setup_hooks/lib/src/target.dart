import 'error.dart';

class Target {
  const Target({
    required this.goos,
    required this.goarch,
    this.abi,
    this.lowMemory = false,
    this.isLib = false,
  });

  final String goos;
  final String goarch;
  final String? abi;
  final bool lowMemory;

  /// A library target ships a static/shared blob instead of an executable.
  /// Only mobile targets set this; the desktop build stays a plain binary.
  final bool isLib;

  static const macosArm64 = Target(goos: 'darwin', goarch: 'arm64');
  static const macosAmd64 = Target(goos: 'darwin', goarch: 'amd64');

  static const linuxArm64 = Target(goos: 'linux', goarch: 'arm64');
  static const linuxAmd64 = Target(goos: 'linux', goarch: 'amd64');

  static const windowsAmd64 = Target(goos: 'windows', goarch: 'amd64');
  static const windowsArm64 = Target(goos: 'windows', goarch: 'arm64');

  static const iosArm64 = Target(
    goos: 'ios',
    goarch: 'arm64',
    abi: 'arm64',
    isLib: true,
  );
  static const iosArm64LowMem = Target(
    goos: 'ios',
    goarch: 'arm64',
    abi: 'arm64',
    lowMemory: true,
    isLib: true,
  );

  static const all = [
    macosArm64,
    macosAmd64,
    linuxArm64,
    linuxAmd64,
    windowsAmd64,
    windowsArm64,
  ];

  /// Mobile targets are built on demand, never in the desktop fan-out.
  static const mobile = [iosArm64, iosArm64LowMem];

  static List<Target> forPlatform(String platform) => [...all, ...mobile]
      .where((target) => target.platformDir == platform)
      .toList();

  static Target resolve({required String platform, required String goarch}) {
    for (final target in forPlatform(platform)) {
      if (target.goarch == goarch) return target;
    }
    throw BuildException('No $platform Core target for GOARCH $goarch');
  }

  bool get hasHelper => goos == 'linux' || goos == 'windows';

  String get executableExtension => goos == 'windows' ? '.exe' : '';

  String get dynamicLibExtension => switch (goos) {
    'android' => '.so',
    'ios' => '.a',
    _ => throw BuildException('No library extension for $this'),
  };

  String get platformDir => goos == 'darwin' ? 'macos' : goos;

  String get rustTriple {
    final arch = switch (goarch) {
      'amd64' => 'x86_64',
      'arm64' => 'aarch64',
      _ => throw BuildException('No Rust target for $this'),
    };
    return switch (goos) {
      'windows' => '$arch-pc-windows-msvc',
      'linux' => '$arch-unknown-linux-gnu',
      _ => throw BuildException('No Rust target for $this'),
    };
  }

  @override
  String toString() => '$goos/$goarch';
}
