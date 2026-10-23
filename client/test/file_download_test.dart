import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggvion/data/file_download.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  for (final mode in [
    'exact',
    'declared-overflow',
    'chunked-overflow',
    'gzip-overflow',
  ]) {
    test('attachment stream limit: $mode', () async {
      final dir = await Directory.systemTemp.createTemp('yggvion-download-');
      addTearDown(() => dir.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        try {
          if (mode == 'exact') {
            request.response.contentLength = 8;
            request.response.write('12345678');
          } else if (mode == 'declared-overflow') {
            request.response.contentLength = 9;
            request.response.write('123456789');
          } else if (mode == 'gzip-overflow') {
            request.response.headers.set(
              HttpHeaders.contentEncodingHeader,
              'gzip',
            );
            request.response.add(gzip.encode(List.filled(100, 65)));
          } else {
            request.response.write('12345678');
            await request.response.flush();
            request.response.write('overflow');
          }
          await request.response.close();
        } on IOException {
          // Expected when the client cancels an oversized response.
        }
      });
      final client = Dio();
      addTearDown(() => client.close(force: true));
      final target = File('${dir.path}/attachment.part');
      final future = downloadLimitedFile(
        client,
        'http://127.0.0.1:${server.port}/file',
        target,
        maximumBytes: 8,
      );
      if (mode == 'exact') {
        await future;
        expect(await target.readAsString(), '12345678');
      } else {
        await expectLater(future, throwsFormatException);
        expect(await target.exists(), isFalse);
      }
    });
  }
}
