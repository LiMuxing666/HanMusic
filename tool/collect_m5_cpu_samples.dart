// External VM Service client: no Flutter/package dependency and no probe change.
// Start after the existing Profile EXE advertises its VM URL in a fresh log.
// This is a diagnostic run; CPU profiling overhead invalidates FPS comparisons.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _usage = '''
dart tool/collect_m5_cpu_samples.dart --stdout <fresh-profile-stdout.txt> --output <new-directory>
  Or replace --stdout with --service-url <http://127.0.0.1:port/auth-token/>.
  --delay-seconds 5      Delay after isolate/flags are ready (0..10).
  --duration-seconds 20  CPU sample interval (1..25); delay + interval <= 30.
  --connect-seconds 15   Wait for stdout/VM Service (1..30).
  --isolate-id <id>      Optional explicit application isolate.

Start the unchanged Profile probe, wait for its fresh VM URL, then start this
collector promptly. An empty startup isolate list is retried for up to 8 s.
The probe still warms up for 5 s and scrolls for 30 s. Collector timing is relative
to isolate/flags readiness, NOT the probe's exact frame window.
Outputs: cpu-samples.raw.json, cpu-summary.json, cpu-session.json.
Never reuse the diagnostic run's FrameTiming numbers as a clean FPS benchmark.
Exit codes: 0 captured nonempty samples; 1 capture failed/empty; 2 invalid usage.
The collector has a 55 s deadline and never stops or pauses the target process.
''';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help')) {
    stdout.write(_usage);
    return;
  }
  late final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.write(_usage);
    exitCode = 2;
    return;
  }
  final session = _Capture(options);
  try {
    await session.prepare();
  } catch (error) {
    stderr.writeln('Cannot prepare output: $error');
    exitCode = 2;
    return;
  }
  try {
    await session.run().timeout(const Duration(seconds: 55));
  } catch (error) {
    session.failure = session.redact('$error');
    stderr.writeln('CPU capture failed: ${session.failure}');
  } finally {
    await session.close();
    await session.saveSession();
  }
  // End any pending discovery/delay future after a deadline. Only this client
  // exits; the unchanged probe retains its own timers and exit behavior.
  exit(session.captured ? 0 : 1);
}

class _Options {
  _Options({
    required this.output,
    required this.log,
    required this.serviceUrl,
    required this.delay,
    required this.duration,
    required this.connect,
    required this.isolateId,
  });
  final Directory output;
  final File? log;
  final Uri? serviceUrl;
  final int delay;
  final int duration;
  final int connect;
  final String? isolateId;

  factory _Options.parse(List<String> args) {
    final values = <String, String>{};
    const names = {
      '--stdout',
      '--service-url',
      '--output',
      '--delay-seconds',
      '--duration-seconds',
      '--connect-seconds',
      '--isolate-id',
    };
    for (var index = 0; index < args.length; index += 2) {
      if (!names.contains(args[index]) ||
          index + 1 == args.length ||
          values.containsKey(args[index])) {
        throw const FormatException('Expected unique --name value arguments.');
      }
      values[args[index]] = args[index + 1];
    }
    if (!values.containsKey('--output') ||
        values.containsKey('--stdout') == values.containsKey('--service-url')) {
      throw const FormatException(
        'Provide --output and exactly one of --stdout / --service-url.',
      );
    }
    int number(String key, int fallback, int maximum, {int minimum = 1}) {
      final value = int.tryParse(values[key] ?? '$fallback');
      if (value == null || value < minimum || value > maximum) {
        throw FormatException('$key must be between $minimum and $maximum.');
      }
      return value;
    }

    final delay = number('--delay-seconds', 5, 10, minimum: 0);
    final duration = number('--duration-seconds', 20, 25);
    if (delay + duration > 30) {
      throw const FormatException(
        'Delay plus collection must not exceed 30 seconds.',
      );
    }
    return _Options(
      output: Directory(values['--output']!).absolute,
      log: values['--stdout'] == null
          ? null
          : File(values['--stdout']!).absolute,
      serviceUrl: values['--service-url'] == null
          ? null
          : _localServiceUri(values['--service-url']!),
      delay: delay,
      duration: duration,
      connect: number('--connect-seconds', 15, 30),
      isolateId: values['--isolate-id'],
    );
  }
}

Uri _localServiceUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'ws'}.contains(uri.scheme) ||
      !{'127.0.0.1', 'localhost', '::1'}.contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const FormatException('Expected a loopback HTTP/WS VM Service URL.');
  }
  return uri;
}

class _Capture {
  _Capture(this.options);
  final _Options options;
  final startedAt = DateTime.now().toUtc();
  final events = <Map<String, Object?>>[];
  _VmRpc? rpc;
  Uri? serviceUri;
  bool captured = false;
  bool closed = false;
  String? failure;
  String? originalProfiler;
  bool changedProfiler = false;
  Map<String, dynamic>? vm;
  Map<String, dynamic>? isolate;
  Map<String, Object?>? flags;
  int? startMicros;
  int? endMicros;
  int isolateStartupWaitMicros = 0;
  int isolateDiscoveryRequests = 0;

  File artifact(String name) => File('${options.output.path}/$name');

  Future<void> prepare() async {
    await options.output.create(recursive: true);
    for (final name in [
      'cpu-session.json',
      'cpu-samples.raw.json',
      'cpu-summary.json',
    ]) {
      if (await artifact(name).exists()) {
        throw FileSystemException(
          'Output already exists; choose a new diagnostic directory.',
          artifact(name).path,
        );
      }
    }
    await saveSession();
  }

  void event(String name) => events.add({
    'event': name,
    'utc': DateTime.now().toUtc().toIso8601String(),
  });

  Future<void> run() async {
    stdout.writeln(
      'WAITING for Profile VM Service; output: ${options.output.path}',
    );
    await stdout.flush();
    final deadline = DateTime.now().add(Duration(seconds: options.connect));
    Object? lastConnectionError;
    while (!closed && DateTime.now().isBefore(deadline)) {
      var uri = options.serviceUrl;
      final log = options.log;
      if (uri == null && log != null && await log.exists()) {
        // Profile stdout is tiny. Bound reads so an unrelated large log cannot
        // consume the diagnostic interval or be copied into artifacts.
        final handle = await log.open();
        late final String text;
        try {
          final bytes = await handle.read(64 * 1024);
          text = utf8
              .decode(bytes, allowMalformed: true)
              .replaceAll('\u0000', '');
        } finally {
          await handle.close();
        }
        final matches = RegExp(
          r'The Dart VM service is listening on (http://\S+)',
        ).allMatches(text).toList();
        if (matches.isNotEmpty) uri = _localServiceUri(matches.last.group(1)!);
      }
      if (uri != null) {
        serviceUri = uri;
        final path = uri.path.endsWith('/ws')
            ? uri.path
            : '${uri.path.endsWith('/') ? uri.path : '${uri.path}/'}ws';
        try {
          final socket = await WebSocket.connect(
            uri.replace(scheme: 'ws', path: path).toString(),
          ).timeout(const Duration(seconds: 2));
          if (closed) {
            await socket.close();
            return;
          }
          rpc = _VmRpc(socket);
          break;
        } catch (error) {
          lastConnectionError = error;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final client = rpc;
    if (client == null) {
      throw StateError(
        'No live VM Service within ${options.connect}s. Wait for a fresh VM URL, then start the collector promptly. ${lastConnectionError ?? ''}',
      );
    }
    event('connected');
    await _selectReadyIsolate(client);
    final flagResponse = await client.call('getFlagList');
    final relevant = <String, Object?>{};
    for (final flag in (flagResponse['flags'] as List<dynamic>? ?? [])) {
      if (flag is Map &&
          {'profiler', 'profile_period'}.contains(flag['name'])) {
        relevant['${flag['name']}'] = flag['valueAsString'];
      }
    }
    flags = relevant;
    originalProfiler = relevant['profiler']?.toString();
    if (originalProfiler == null) {
      throw StateError(
        'VM did not expose profiler flag; cannot safely restore profiling state.',
      );
    }
    if (originalProfiler != 'true') {
      final changed = await client.call(
        'setFlag',
        params: {'name': 'profiler', 'value': 'true'},
      );
      if (changed['type'] != 'Success') {
        throw StateError('VM refused profiler enable: ${changed['type']}');
      }
      changedProfiler = true;
    }
    // Keep the existing profile_period; changing sampling frequency would add
    // another variable. Profiling is enabled before the delay so buffers warm up.
    await saveSession();
    stdout.writeln(
      'CONNECTED to main isolate; diagnostic delay ${options.delay}s, samples ${options.duration}s.',
    );
    await Future<void>.delayed(Duration(seconds: options.delay));
    if (closed) return;
    startMicros =
        (await client.call('getVMTimelineMicros'))['timestamp'] as int;
    event('sample_window_started');
    await Future<void>.delayed(Duration(seconds: options.duration));
    if (closed) return;
    endMicros = (await client.call('getVMTimelineMicros'))['timestamp'] as int;
    event('sample_window_ended');
    final samples = await client.call(
      'getCpuSamples',
      params: {
        'isolateId': isolate!['id'],
        'timeOriginMicros': startMicros,
        'timeExtentMicros': endMicros! - startMicros!,
      },
      timeout: const Duration(seconds: 10),
    );
    if (samples['type'] != 'CpuSamples') {
      throw StateError('Unexpected CPU response: ${samples['type']}');
    }
    await artifact(
      'cpu-samples.raw.json',
    ).writeAsString(jsonEncode(samples), flush: true);
    final summary = _summarize(samples, startMicros!, endMicros!);
    await artifact('cpu-summary.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(summary),
      flush: true,
    );
    captured = (samples['sampleCount'] as num? ?? 0) > 0;
    if (!captured) {
      failure = 'VM returned zero samples. No hotspot conclusion can be drawn.';
    }
    event('artifacts_saved');
    stdout.writeln(
      'CPU samples: ${samples['sampleCount']}; raw and summary written to ${options.output.path}',
    );
  }

  Future<void> _selectReadyIsolate(_VmRpc client) async {
    const startupLimit = Duration(seconds: 8);
    final wait = Stopwatch()..start();
    var waitingForStartup = false;
    try {
      while (!closed) {
        final remaining = startupLimit - wait.elapsed;
        if (remaining <= Duration.zero) {
          event('isolate_startup_wait_timed_out');
          throw StateError(
            'VM remained without an application isolate for 8 seconds. Startup did not become ready; no sampling was attempted.',
          );
        }
        isolateDiscoveryRequests++;
        // A normal RPC remains capped at 5 s; near the startup deadline its
        // timeout is shortened, never enlarged.
        vm = await client.call(
          'getVM',
          timeout: remaining < const Duration(seconds: 5)
              ? remaining
              : const Duration(seconds: 5),
        );
        final entries = vm!['isolates'] as List<dynamic>? ?? [];
        if (entries.isNotEmpty) break;
        if (!waitingForStartup) {
          waitingForStartup = true;
          event('isolate_startup_wait_started');
        }
        final delay = startupLimit - wait.elapsed;
        if (delay > Duration.zero) {
          await Future<void>.delayed(
            delay < const Duration(milliseconds: 250)
                ? delay
                : const Duration(milliseconds: 250),
          );
        }
      }
    } finally {
      wait.stop();
      isolateStartupWaitMicros = wait.elapsedMicroseconds;
    }
    if (closed) {
      throw StateError(
        'Collector closed while waiting for application isolate.',
      );
    }
    final candidates = (vm!['isolates'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final matches = candidates
        .where(
          (entry) => options.isolateId == null
              ? entry['name'] == 'main' ||
                    '${entry['name']}'.contains('windows_m5_performance_probe')
              : entry['id'] == options.isolateId,
        )
        .toList();
    if (matches.length == 1) {
      isolate = matches.single;
    } else if (options.isolateId == null && candidates.length == 1) {
      isolate = candidates.single;
    } else {
      event('isolate_selection_ambiguous');
      throw StateError(
        'Cannot identify main isolate. Supply --isolate-id. Candidates: ${candidates.map((entry) => '${entry['id']}:${entry['name']}').join(', ')}',
      );
    }
    event(
      waitingForStartup ? 'isolate_startup_wait_completed' : 'isolate_selected',
    );
  }

  String redact(String message) {
    final uri = serviceUri;
    if (uri == null) return message;
    return message
        .replaceAll(
          uri.toString(),
          '${uri.scheme}://${uri.host}:${uri.port}/<redacted>/',
        )
        .replaceAll(uri.path, '/<redacted>/');
  }

  Future<void> close() async {
    closed = true;
    final client = rpc;
    if (client == null) return;
    if (changedProfiler) {
      try {
        final restored = await client.call(
          'setFlag',
          params: {'name': 'profiler', 'value': originalProfiler},
          timeout: const Duration(seconds: 2),
        );
        event(
          restored['type'] == 'Success'
              ? 'profiler_restored'
              : 'profiler_restore_rejected',
        );
      } catch (_) {
        // The 35-second probe may already have exited. Its process is never
        // kept alive or restarted by the collector.
        event('profiler_restore_unavailable_target_may_have_exited');
      }
    }
    await client.close();
  }

  Future<void> saveSession() => artifact('cpu-session.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'diagnosticRun': true,
      'captured': captured,
      'startedAtUtc': startedAt.toIso8601String(),
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'scope':
          'CPU samples from existing Profile probe. Profiling/RPC overhead means this run is not an uninstrumented FPS comparison. Probe workload and source are unchanged.',
      'timingAlignment':
          'Window follows main isolate selection and profiler setup, not exact probe warmup/measurement boundary.',
      'isolateStartupWaitLimitSeconds': 8,
      'isolateStartupWaitMicros': isolateStartupWaitMicros,
      'isolateDiscoveryRequests': isolateDiscoveryRequests,
      'delaySeconds': options.delay,
      'durationSeconds': options.duration,
      'deadlineSeconds': 55,
      'serviceHost': serviceUri?.host,
      'servicePort': serviceUri?.port,
      'vm': vm == null
          ? null
          : {
              'pid': vm!['pid'],
              'version': vm!['version'],
              'hostCPU': vm!['hostCPU'],
              'architectureBits': vm!['architectureBits'],
            },
      'isolate': isolate,
      'originalFlags': flags,
      'profilerTemporarilyEnabled': changedProfiler,
      'sampleStartMicros': startMicros,
      'sampleEndMicros': endMicros,
      'events': events,
      'failure': failure,
    }),
    flush: true,
  );
}

Map<String, Object?> _summarize(
  Map<String, dynamic> response,
  int start,
  int end,
) {
  final samples = (response['samples'] as List<dynamic>? ?? []);
  final functions = (response['functions'] as List<dynamic>? ?? []);
  final count = samples.length;
  final summaries = <Map<String, Object?>>[];
  for (var index = 0; index < functions.length; index++) {
    final entry = functions[index] as Map<String, dynamic>;
    final function = entry['function'] as Map<String, dynamic>? ?? {};
    final owner = function['owner'] as Map<String, dynamic>?;
    final name = '${function['name'] ?? '<unknown>'}';
    final self = entry['exclusiveTicks'] as num? ?? 0;
    final inclusive = entry['inclusiveTicks'] as num? ?? 0;
    summaries.add({
      'index': index,
      'name': name,
      'owner': owner?['name'],
      'kind': entry['kind'],
      'resolvedUrl': entry['resolvedUrl'],
      'exclusiveTicks': self,
      'inclusiveTicks': inclusive,
      'exclusivePercent': count == 0 ? null : 100 * self / count,
      'inclusivePercent': count == 0 ? null : 100 * inclusive / count,
    });
  }
  List<Map<String, Object?>> top(String field) {
    final sorted = summaries.toList()
      ..sort((a, b) => (b[field]! as num).compareTo(a[field]! as num));
    return sorted
        .where((entry) => (entry[field]! as num) > 0)
        .take(40)
        .toList();
  }

  final tags = <String, int>{};
  final threads = <String, int>{};
  var truncated = 0;
  for (final sample in samples.cast<Map<String, dynamic>>()) {
    final tag = '${sample['vmTag'] ?? 'unknown'}';
    final tid = '${sample['tid']}';
    tags[tag] = (tags[tag] ?? 0) + 1;
    threads[tid] = (threads[tid] ?? 0) + 1;
    if (sample['truncated'] == true) truncated++;
  }
  return {
    'schemaVersion': 1,
    'diagnosticRun': true,
    'sampleCount': response['sampleCount'],
    'returnedSampleRecords': count,
    'samplePeriodMicros': response['samplePeriod'],
    'maxStackDepth': response['maxStackDepth'],
    'requestedStartMicros': start,
    'requestedEndMicros': end,
    'responseTimeOriginMicros': response['timeOriginMicros'],
    'responseTimeExtentMicros': response['timeExtentMicros'],
    'truncatedStacks': truncated,
    'vmTags': tags,
    'threads': threads,
    'interpretation':
        'Ticks are statistical CPU samples, not milliseconds. Inclusive percentages overlap and must not be added. Use raw top-to-bottom sample stacks to distinguish build/layout/text/native costs; this summary does not automatically identify a root cause.',
    'topExclusive': top('exclusiveTicks'),
    'topInclusive': top('inclusiveTicks'),
  };
}

class _VmRpc {
  _VmRpc(this.socket) {
    subscription = socket.listen(
      (message) {
        final decoded = jsonDecode(message as String) as Map<String, dynamic>;
        final completion = pending.remove('${decoded['id']}');
        if (completion == null) return; // Notifications are not RPC replies.
        if (decoded['error'] != null) {
          completion.completeError(
            StateError('VM RPC error: ${decoded['error']}'),
          );
        } else {
          completion.complete(decoded['result'] as Map<String, dynamic>);
        }
      },
      onError: (Object error) => fail(error),
      onDone: () => fail(StateError('Target VM Service disconnected.')),
    );
  }
  final WebSocket socket;
  late final StreamSubscription<dynamic> subscription;
  final pending = <String, Completer<Map<String, dynamic>>>{};
  int nextId = 0;
  bool disconnected = false;

  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (disconnected) throw StateError('VM Service disconnected.');
    final id = '${++nextId}';
    final completion = Completer<Map<String, dynamic>>();
    pending[id] = completion;
    try {
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );
      return await completion.future.timeout(timeout);
    } finally {
      pending.remove(id);
    }
  }

  void fail(Object error) {
    disconnected = true;
    final waiting = pending.values.toList();
    pending.clear();
    for (final completion in waiting) {
      completion.completeError(error);
    }
  }

  Future<void> close() async {
    fail(StateError('CPU collector closed.'));
    await subscription.cancel();
    await socket.close().timeout(const Duration(seconds: 1), onTimeout: () {});
  }
}
