import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _cargoEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android and iOS, so it needs a libclang that can see
// the platform SDK headers: Apple platforms get that from Xcode, Android from
// the NDK Flutter hands us.
Map<String, String> _cargoEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets) return const {};
  final code = input.config.code;
  final environment = <String, String>{
    // Stripping can misalign Mach-O LINKEDIT on Apple targets and the archive
    // then fails to link (rust-lang/rust#157750).
    if (code.targetOS == OS.macOS || code.targetOS == OS.iOS)
      'CARGO_PROFILE_RELEASE_STRIP': 'none',
  };

  if (code.targetOS == OS.iOS) {
    final sdk = code.iOS.targetSdk == IOSSdk.iPhoneOS
        ? 'iphoneos'
        : 'iphonesimulator';
    String xcrun(List<String> arguments) {
      final result = Process.runSync('xcrun', ['--sdk', sdk, ...arguments]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'xcrun',
          arguments,
          '${result.stderr}',
          result.exitCode,
        );
      }
      return (result.stdout as String).trim();
    }

    final sdkPath = xcrun(['--show-sdk-path']);
    final clang = xcrun(['--find', 'clang']);
    return {
      ...environment,
      'LIBCLANG_PATH': '${File(clang).parent.parent.path}/lib',
      // Cross-compiling means bindgen cannot fall back to host SDK headers.
      'BINDGEN_EXTRA_CLANG_ARGS': '-isysroot "$sdkPath"',
      'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}.0',
    };
  }

  if (code.targetOS != OS.android) return environment;

  final compiler = code.cCompiler?.compiler;
  if (compiler == null) return environment;
  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {...environment, 'LIBCLANG_PATH': directory.path};
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}
