import 'dart:async';
import 'dart:io';

abstract class BaseHttpServer {
  HttpServer _server;

  String get address => _server?.address?.address ?? '';
  int get port => _server?.port ?? 0;
  bool get running => _server != null;
  Zone get zone => Zone.current;

  String encodeUrl(String url) => 'http://${this.address}:${this.port}/${Uri.encodeComponent(url)}';
  String decodeUrl(Uri uri) => Uri.decodeComponent(uri.path.startsWith('/') ? uri.path.substring(1) : uri.path);

  Future<BaseHttpServer> start([bool loopback = true, int port = 0]) async {
    return zone.run(() async {
      if (_server == null) {
        final address = loopback ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4;
        final server = _server = await HttpServer.bind(address, port);
        server.listen(handleRequest);
        print('HttpServer start: ${server.address.address}:${server.port}');
      }
      return this;
    });
  }

  Future<BaseHttpServer> stop() async {
    return zone.run(() async {
      final server = _server;
      _server = null;
      if (server != null) {
        print('HttpServer stop: ${server.address.address}:${server.port}');
        await server.close();
      }
      return this;
    });
  }

  void handleRequest(HttpRequest request);
}