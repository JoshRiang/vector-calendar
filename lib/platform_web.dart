const bool kIsWeb = true;

class SocketException implements Exception {
  SocketException(this.message);
  final String message;
  @override
  String toString() => message;
}

class HandshakeException implements Exception {
  HandshakeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class HttpClient {
  Duration? connectionTimeout;
  Future<HttpClientRequest> postUrl(Uri url) async => HttpClientRequest();
  void close() {}
}

class HttpHeaders {
  final Map<String, String> _h = {};
  void set(String key, String value) => _h[key] = value;
  String? operator [](String key) => _h[key];
}

class HttpClientRequest {
  final HttpHeaders headers = HttpHeaders();
  void write(Object? data) {}
  Future<HttpClientResponse> close() async => HttpClientResponse();
}

class HttpClientResponse {
  int get statusCode => 200;
}
