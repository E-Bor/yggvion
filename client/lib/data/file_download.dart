import 'dart:io';
import 'package:dio/dio.dart';

// Allows every supported 300 MiB attachment, including encryption overhead.
const maxEncryptedAttachmentBytes = 301 * 1024 * 1024;

/// Checks the actual stream before writing each chunk, even without a length
/// header. A failed or cancelled download never leaves a partial file behind.
Future<void> downloadLimitedFile(
  Dio client,
  String url,
  File target, {
  required int maximumBytes,
  Options? options,
}) async {
  final cancellation = CancelToken();
  RandomAccessFile? output;
  var complete = false;
  try {
    final response = await client.get<ResponseBody>(
      url,
      options: (options ?? Options()).copyWith(
        responseType: ResponseType.stream,
      ),
      cancelToken: cancellation,
    );
    final body = response.data!;
    final declared = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (declared != null && declared > maximumBytes) {
      // Cancel an unread stream as well as the underlying HTTP request.
      cancellation.cancel();
      await body.stream.listen(null).cancel();
      throw const FormatException(
        'Скачиваемое вложение превышает допустимый размер',
      );
    }
    output = await target.open(mode: FileMode.write);
    var received = 0;
    await for (final chunk in body.stream) {
      if (chunk.length > maximumBytes - received) {
        throw const FormatException(
          'Скачиваемое вложение превышает допустимый размер',
        );
      }
      await output.writeFrom(chunk);
      received += chunk.length;
    }
    await output.flush();
    complete = true;
  } finally {
    cancellation.cancel();
    await output?.close();
    if (!complete && await target.exists()) await target.delete();
  }
}
