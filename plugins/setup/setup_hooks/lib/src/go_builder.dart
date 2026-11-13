import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'error.dart';
import 'fingerprint.dart';
import 'options.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('go_builder');

class GoBuilder {
  GoBuilder({
    required this.rootDir,
    required this.config,
    required this.cache,
    required this.notice,
    this.harnessInputs = const [],
  });

  final String rootDir;
  final BuildConfig config;
  final BuildCache cache;
  final BuildNotice notice;
  final List<String> harnessInputs;

  static const _desktopPackage = './cmd/core';
  static const _iosPackage = './cmd/ios';

  /// The Xcode project links this archive by name, so it has to match the
  /// file references in Runner.xcodeproj and the libclash output directory.
  static const _iosLibName = 'libclash';

  String _mainPackageFor(Target target) =>
      target.goos == 'ios' ? _iosPackage : _desktopPackage;

  String get _corePath => p.join(rootDir, config.coreDir);
  String get _outputPath => p.join(rootDir, config.outputDir);

  Future<BuildExecution> build(Target target) async {
    final outDir = target.isLib
        ? p.join(_outputPath, target.platformDir, target.abi!)
        : p.join(_outputPath, target.platformDir);
    ensureDir(outDir);

    final fileName = target.isLib
        ? '$_iosLibName${target.lowMemory ? '_lowmem' : ''}'
              '${target.dynamicLibExtension}'
        : '${config.coreName}${target.executableExtension}';
    final outFile = p.join(outDir, fileName);

    final variantKey = target.lowMemory ? '-lowmem' : '';
    return cache.run(
      key: '${target.platformDir}-${target.goarch}$variantKey-core',
      fingerprint: () => _calculateFingerprint(target),
      primaryOutput: outFile,
      notice: notice,
      build: () async {
        final env = _buildEnvironment(target);
        _log.info('Building Go core: $target');

        // A failed build must not destroy the previous artifacts.
        final stagingDir = Directory(
          p.join(outDir, '.staging-${target.goarch}$variantKey-$pid'),
        );
        final staged = p.join(stagingDir.path, fileName);
        try {
          await runCommandStream(
            'go',
            _buildArguments(target, outFile: staged),
            workingDirectory: _corePath,
            environment: env,
          );
          replaceFile(staged, outFile);

          final outputs = <String>[outFile];
          if (target.goos == 'ios') {
            // c-archive also emits the C header the extension compiles against.
            final headerName = '${p.basenameWithoutExtension(fileName)}.h';
            final stagedHeader = p.join(stagingDir.path, headerName);
            if (File(stagedHeader).existsSync()) {
              final header = p.join(outDir, headerName);
              replaceFile(stagedHeader, header);
              outputs.add(header);
            }
            // The generated header re-includes bride.h, and quoted includes
            // resolve against the header's own directory, so the C shim has to
            // sit next to it for the Xcode targets to compile.
            final brideHeader = p.join(_corePath, 'cmd', 'ios', 'bride.h');
            if (File(brideHeader).existsSync()) {
              final shim = p.join(outDir, 'bride.h');
              File(brideHeader).copySync(shim);
              outputs.add(shim);
            }
          }

          _log.info('Built: $outFile');
          return outputs;
        } finally {
          if (stagingDir.existsSync()) {
            stagingDir.deleteSync(recursive: true);
          }
        }
      },
    );
  }

  String _iosSdkPath() {
    final result = Process.runSync('xcrun', [
      '--sdk',
      'iphoneos',
      '--show-sdk-path',
    ]);
    if (result.exitCode != 0) {
      throw BuildException('Failed to locate the iOS SDK: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  String _iosClangPath() {
    final result = Process.runSync('xcrun', [
      '--sdk',
      'iphoneos',
      '--find',
      'clang',
    ]);
    if (result.exitCode != 0) {
      throw BuildException('Failed to locate the iOS clang: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  String _iosCgoFlags(String sdkPath, String arch, {String baseFlags = ''}) => [
    baseFlags.trim(),
    '-isysroot',
    sdkPath,
    '-miphoneos-version-min=14.0',
    '-arch',
    arch,
  ].where((value) => value.isNotEmpty).join(' ');

  Map<String, String> _buildEnvironment(Target target) {
    if (!target.isLib) {
      return {
        'GOOS': target.goos,
        'GOARCH': target.goarch,
        'CGO_ENABLED': '0',
      };
    }

    final sdkPath = _iosSdkPath();
    return {
      'GOOS': target.goos,
      'GOARCH': target.goarch,
      'CGO_ENABLED': '1',
      'CC': _iosClangPath(),
      'CGO_CFLAGS': _iosCgoFlags(sdkPath, target.goarch, baseFlags: '-O3'),
      'CGO_LDFLAGS': _iosCgoFlags(sdkPath, target.goarch),
    };
  }

  // Package-level vars in mihomo copy constant.Version during init, so only the
  // linker can set it for every reader.
  static const _versionSymbol = 'github.com/metacubex/mihomo/constant.Version';

  /// The iOS archives ship inside the app bundle, so their DWARF is dead
  /// weight: nothing symbolises a Go frame from an Apple crash report anyway.
  /// Only -w is applied; -s would drop the symbol table the linker needs to
  /// resolve the //export entries.
  String _ldflags(Target target) => [
    config.goLdflags,
    if (target.isLib) '-w',
    if (config.coreVersion.isNotEmpty)
      '-X $_versionSymbol=${config.coreVersion}',
  ].join(' ');

  /// The extension links a second archive built with with_low_memory so the
  /// Go heap stays under the ~50 MB extension cap.
  String _tagsFor(Target target) =>
      target.lowMemory ? '${config.tags} with_low_memory' : config.tags;

  List<String> _buildArguments(Target target, {String? outFile}) {
    final buildMode = target.isLib ? 'c-archive' : null;
    return [
      'build',
      '-ldflags=${_ldflags(target)}',
      '-tags=${_tagsFor(target)}',
      if (target.isLib) '-trimpath',
      if (buildMode != null) '-buildmode=$buildMode',
      if (outFile != null) ...['-o', outFile],
      _mainPackageFor(target),
    ];
  }

  Future<Fingerprint> _calculateFingerprint(Target target) async {
    final env = _buildEnvironment(target);
    final builder = FingerprintBuilder(rootDir: rootDir)
      ..addValue('cache_schema', BuildCache.schemaVersion)
      ..addValue('kind', 'go-core')
      ..addValue('target', {
        'goos': target.goos,
        'goarch': target.goarch,
        'abi': target.abi,
        'is_lib': target.isLib,
        'low_memory': target.lowMemory,
      })
      ..addValue('config', config.toFingerprintMap())
      ..addValue('environment', env)
      ..addValue('arguments', _buildArguments(target));

    final goEnvResult = runCommand(
      'go',
      [
        'env',
        '-json',
        'GOVERSION',
        'GOTOOLCHAIN',
        'GOFLAGS',
        'GOEXPERIMENT',
        'GOAMD64',
        'GOARM',
        'GO386',
        'GOMIPS',
        'GOMIPS64',
        'CGO_CFLAGS',
        'CGO_CPPFLAGS',
        'CGO_CXXFLAGS',
        'CGO_LDFLAGS',
        'GOWORK',
        'GOENV',
      ],
      workingDirectory: _corePath,
      environment: env,
    );
    final goEnv = jsonDecode((goEnvResult.stdout as String).trim());
    builder.addValue('go_env', goEnv);

    final inputs = _resolveGoInputs(env, target);
    final goWork = (goEnv as Map<String, dynamic>)['GOWORK'];
    if (goWork is String && goWork.isNotEmpty && goWork != 'off') {
      inputs.add(goWork);
      final goWorkSum = p.join(p.dirname(goWork), 'go.work.sum');
      if (File(goWorkSum).existsSync()) inputs.add(goWorkSum);
    }
    inputs.addAll(harnessInputs);

    builder.addFiles(inputs);
    return builder.finishWithInputs();
  }

  Set<String> _resolveGoInputs(Map<String, String> environment, Target target) {
    const template =
        r'''{{range .GoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CgoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CXXFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .MFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .HFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .FFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SwigFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SwigCXXFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SysoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .EmbedFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{with .Module}}{{if .GoMod}}{{.GoMod}}{{"\n"}}{{end}}{{end}}''';
    final result = runCommand(
      'go',
      [
        'list',
        '-deps',
        '-tags=${_tagsFor(target)}',
        '-f',
        template,
        _mainPackageFor(target),
      ],
      workingDirectory: _corePath,
      environment: environment,
    );
    final corePath = p.normalize(p.absolute(_corePath));
    final inputs = <String>{};
    for (final line in (result.stdout as String).split('\n')) {
      final value = line.trim();
      if (value.isEmpty) continue;
      final filePath = p.normalize(
        p.absolute(p.isAbsolute(value) ? value : p.join(_corePath, value)),
      );
      if (!p.isWithin(corePath, filePath) && !p.equals(corePath, filePath)) {
        continue;
      }
      if (!File(filePath).existsSync()) continue;
      inputs.add(filePath);
      if (p.basename(filePath) == 'go.mod') {
        final goSum = p.join(p.dirname(filePath), 'go.sum');
        if (File(goSum).existsSync()) inputs.add(goSum);
      }
    }

    for (final name in const ['go.mod', 'go.sum']) {
      final filePath = p.join(_corePath, name);
      if (File(filePath).existsSync()) inputs.add(filePath);
    }
    return inputs;
  }
}
