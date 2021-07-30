import 'dart:async';

import 'package:dio/dio.dart';

import 'src/http_status_codes.dart';

typedef RetryEvaluator = FutureOr<bool> Function(DioError error, int attempt);

/// An interceptor that will try to send failed request again
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required this.dio,
    this.logPrint,
    this.retries = 3,
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 5),
    ],
    RetryEvaluator? retryEvaluator,
  }) : _retryEvaluator = retryEvaluator ?? defaultRetryEvaluator;

  /// The original dio
  final Dio dio;

  /// For logging purpose
  final Function(String message)? logPrint;

  /// The number of retry in case of an error
  final int retries;

  /// The delays between attempts.
  /// Empty [retryDelays] means no delay.
  ///
  /// If [retries] count more than [retryDelays] count,
  /// the last value of [retryDelays] will be used.
  final List<Duration> retryDelays;

  /// Evaluating if a retry is necessary.regarding the error.
  ///
  /// It can be a good candidate for additional operations too, like
  /// updating authentication token in case of a unauthorized error (be careful
  /// with concurrency though).
  ///
  /// Defaults to [defaultRetryEvaluator].
  final RetryEvaluator _retryEvaluator;

  /// Returns true only if the response hasn't been cancelled or got
  /// a bas status code.
  // ignore: avoid-unused-parameters
  static FutureOr<bool> defaultRetryEvaluator(DioError error, int attempt) {
    bool shouldRetry;
    if (error.type == DioErrorType.response) {
      final statusCode = error.response?.statusCode;
      shouldRetry = statusCode != null ? isRetryable(statusCode) : true;
    } else {
      shouldRetry = error.type != DioErrorType.cancel;
    }
    return shouldRetry;
  }

  @override
  Future onError(DioError err, ErrorInterceptorHandler handler) async {
    if(err.requestOptions.disableRetry) return super.onError(err, handler);
    var attempt = err.requestOptions._attempt + 1;
    // ignore: lines_longer_than_80_chars
    final shouldRetry =
        attempt <= retries && await _retryEvaluator(err, attempt);

    if (!shouldRetry) return super.onError(err, handler);

    err.requestOptions._attempt = attempt;
    final delay = _getDelay(attempt);
    logPrint?.call(
      '[${err.requestOptions.uri}] An error occurred during request, '
      'trying again '
      '(attempt: $attempt/$retries, '
      'wait ${delay.inMilliseconds} ms, '
      'error: ${err.error})',
    );

    if (delay != Duration.zero) await Future<void>.delayed(delay);

    // ignore: unawaited_futures
    dio.fetch<void>(err.requestOptions).then((value) => handler.resolve(value));
  }

  Duration _getDelay(int attempt) {
    if (retryDelays.isEmpty) return Duration.zero;
    return attempt - 1 < retryDelays.length
        ? retryDelays[attempt - 1]
        : retryDelays.last;
  }
}

extension RequestOptionsX on RequestOptions {
  static const _kAttemptKey = 'ro_attempt';
  static const _kDisableRetryKey = 'ro_disable_retry';

  int get _attempt => extra[_kAttemptKey] ?? 0;

  set _attempt(int value) => extra[_kAttemptKey] = value;

  bool get disableRetry => (extra[_kDisableRetryKey] as bool?) ?? false;

  set disableRetry(bool value) => extra[_kDisableRetryKey] = value;
}
