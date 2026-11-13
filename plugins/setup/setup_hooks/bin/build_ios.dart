import 'dart:io';

import 'package:setup_hooks/src/build.dart';
import 'package:setup_hooks/src/ios_build.dart';
import 'package:setup_hooks/src/logging.dart';

Future<void> main() async {
  initLogging();
  try {
    final env = Platform.environment;
    // NECore links the low-memory archive, Runner links the plain one, so both
    // have to exist before Xcode starts linking either target.
    await buildPlatform(iosBuildRequest(env));
    await buildPlatform(iosBuildRequest(env, lowMemory: true));
  } finally {
    closeLogging();
  }
}
