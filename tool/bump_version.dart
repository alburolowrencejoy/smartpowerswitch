import 'dart:io';

enum BumpPart { major, minor, patch, build }

void main(List<String> args) {
  var write = false;
  var part = BumpPart.patch;

  for (final arg in args) {
    if (arg == '--write') {
      write = true;
      continue;
    }
    if (arg.startsWith('--part=')) {
      final raw = arg.substring('--part='.length).trim().toLowerCase();
      part = switch (raw) {
        'major' => BumpPart.major,
        'minor' => BumpPart.minor,
        'patch' => BumpPart.patch,
        'build' => BumpPart.build,
        _ => throw ArgumentError('Unsupported part "$raw".'),
      };
      continue;
    }
  }

  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln('pubspec.yaml not found in current directory.');
    exitCode = 1;
    return;
  }

  final source = pubspec.readAsStringSync();
  final lines = source.split('\n');
  final versionIndex = lines.indexWhere((line) => line.trimLeft().startsWith('version:'));

  if (versionIndex < 0) {
    stderr.writeln('No version: entry found in pubspec.yaml.');
    exitCode = 1;
    return;
  }

  final versionLine = lines[versionIndex].trim();
  final value = versionLine.substring('version:'.length).trim();
  final parsed = _parseVersion(value);
  if (parsed == null) {
    stderr.writeln(
      'Unable to parse version "$value". Expected format x.y.z+b.',
    );
    exitCode = 1;
    return;
  }

  var major = parsed.major;
  var minor = parsed.minor;
  var patch = parsed.patch;
  var build = parsed.build;

  switch (part) {
    case BumpPart.major:
      major += 1;
      minor = 0;
      patch = 0;
      build += 1;
      break;
    case BumpPart.minor:
      minor += 1;
      patch = 0;
      build += 1;
      break;
    case BumpPart.patch:
      patch += 1;
      build += 1;
      break;
    case BumpPart.build:
      build += 1;
      break;
  }

  final nextVersion = '$major.$minor.$patch+$build';
  final leadingWhitespace = RegExp(r'^\s*').stringMatch(lines[versionIndex]) ?? '';
  lines[versionIndex] = '${leadingWhitespace}version: $nextVersion';

  if (write) {
    pubspec.writeAsStringSync(lines.join('\n'));
  }

  stdout.writeln(nextVersion);
}

({int major, int minor, int patch, int build})? _parseVersion(String raw) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)\+(\d+)$').firstMatch(raw);
  if (match == null) return null;
  return (
    major: int.parse(match.group(1)!),
    minor: int.parse(match.group(2)!),
    patch: int.parse(match.group(3)!),
    build: int.parse(match.group(4)!),
  );
}