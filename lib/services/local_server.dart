import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

/// Локальный HTTP сервер для эмулятора
/// Отдаёт runtime.html, wasmoon.js, glue.wasm из assets
/// Принимает POST /app с кодом приложения
class LocalServer {
  static final LocalServer _instance = LocalServer._internal();
  factory LocalServer() => _instance;
  LocalServer._internal();

  HttpServer? _server;
  String? _currentAppCode;
  int _port = 8842;
  bool _localOnly = true;
  
  final _appCodeController = StreamController<String>.broadcast();
  Stream<String> get onAppCode => _appCodeController.stream;

  final _logController = StreamController<String>.broadcast();
  Stream<String> get onLog => _logController.stream;

  void _log(String message) {
    final time = DateTime.now().toString().substring(11, 19);
    final formatted = '[$time] $message';
    print('[LocalServer] $message');
    _logController.add(formatted);
  }

  bool get isRunning => _server != null;
  int get port => _port;
  bool get localOnly => _localOnly;
  
  /// IP адреса сервера для отладки
  Future<List<String>> getServerUrls() async {
    if (_server == null) return [];
    
    if (_localOnly) {
      return ['http://127.0.0.1:$_port'];
    }
    
    final urls = <String>[];
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4) {
          urls.add('http://${addr.address}:$_port');
        }
      }
    }
    return urls;
  }

  Future<void> start({int port = 8842, bool localOnly = true}) async {
    if (_server != null) {
      // Если меняем режим — перезапуск
      if (_localOnly != localOnly) {
        await stop();
      } else {
        _log('Сервер уже запущен');
        return;
      }
    }
    
    _port = port;
    _localOnly = localOnly;
    
    final router = Router();
    
    // GET / — форма ввода (editor)
    router.get('/', _handleRuntime);
    router.get('/runtime.html', _handleRuntime);
    
    // GET /app — страница приложения (autoload)
    router.get('/app', _handleRuntime);
    
    // Статика wasmoon
    router.get('/wasmoon.js', _handleWasmoonJs);
    router.get('/glue.wasm', _handleGlueWasm);
    
    // App code API
    router.get('/app/code', _handleGetAppCode);
    router.post('/app/code', _handlePostApp);
    router.post('/app', _handlePostApp);
    
    // Validation API
    router.get('/validate', _handleValidate);
    router.get('/validate.html', _handleValidate);
    
    // Console API
    router.get('/console', _handleGetConsole);
    router.post('/console', _handlePostConsole);
    router.delete('/console', _handleClearConsole);
    
    // Status
    router.get('/status', _handleStatus);
    
    final handler = const Pipeline()
        .addMiddleware(_corsMiddleware())
        .addMiddleware(_connectionLogMiddleware())
        .addHandler(router);
    
    try {
      final address = _localOnly ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4;
      _server = await shelf_io.serve(
        handler,
        address,
        _port,
      );
      
      final mode = _localOnly ? 'localhost' : 'WiFi';
      _log('🚀 Сервер запущен ($mode) :$_port');
      
      if (!_localOnly) {
        final urls = await getServerUrls();
        for (var url in urls) {
          if (!url.contains('127.0.0.1')) {
            _log('📡 Доступен: $url');
          }
        }
      }
    } catch (e) {
      _log('❌ Ошибка запуска: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _log('⏹️ Сервер остановлен');
  }

  /// Загрузить код приложения (программно из Flutter)
  void loadApp(String code) {
    _currentAppCode = code;
    _appCodeController.add(code);
    _log('📱 Приложение загружено (${code.length} байт)');
  }

  /// CORS middleware для доступа с внешних устройств
  Middleware _corsMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        if (request.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders);
        }
        final response = await handler(request);
        return response.change(headers: _corsHeaders);
      };
    };
  }

  static const _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };

  /// Логирование подключений
  Middleware _connectionLogMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        final ip = request.headers['x-forwarded-for'] ?? 
                   request.headers['x-real-ip'] ?? 
                   request.context['shelf.io.connection_info']?.toString() ??
                   'unknown';
        
        // Извлекаем IP из ConnectionInfo если есть
        String clientIp = ip;
        final connInfo = request.context['shelf.io.connection_info'];
        if (connInfo != null && connInfo is HttpConnectionInfo) {
          clientIp = connInfo.remoteAddress.address;
        }
        
        final method = request.method;
        final path = request.requestedUri.path;
        
        // Логируем заметные события
        if (path == '/app' && method == 'POST') {
          _log('📥 $clientIp загружает приложение');
        } else if (path == '/app' && method == 'GET') {
          _log('🖥️ $clientIp открыл приложение');
        } else if (path == '/' && method == 'GET') {
          _log('🔗 $clientIp подключился');
        }
        
        final response = await handler(request);
        return response;
      };
    };
  }

  // --- Handlers ---

  Future<Response> _handleRuntime(Request request) async {
    try {
      final content = await rootBundle.loadString('assets/server/runtime.html');
      return Response.ok(content, headers: {'Content-Type': 'text/html; charset=utf-8'});
    } catch (e) {
      return Response.notFound('runtime.html not found: $e');
    }
  }

  Future<Response> _handleWasmoonJs(Request request) async {
    try {
      final content = await rootBundle.loadString('assets/server/wasmoon.js');
      return Response.ok(content, headers: {'Content-Type': 'application/javascript; charset=utf-8'});
    } catch (e) {
      return Response.notFound('wasmoon.js not found: $e');
    }
  }

  Future<Response> _handleGlueWasm(Request request) async {
    try {
      final data = await rootBundle.load('assets/server/glue.wasm');
      return Response.ok(
        data.buffer.asUint8List(),
        headers: {'Content-Type': 'application/wasm'},
      );
    } catch (e) {
      return Response.notFound('glue.wasm not found: $e');
    }
  }

  Future<Response> _handleGetAppCode(Request request) async {
    if (_currentAppCode == null) {
      return Response.notFound('No app loaded');
    }
    return Response.ok(_currentAppCode, headers: {'Content-Type': 'text/html; charset=utf-8'});
  }

  Future<Response> _handlePostApp(Request request) async {
    try {
      final body = await request.readAsString();
      if (body.isEmpty) {
        return Response.badRequest(body: 'Empty body');
      }
      loadApp(body);
      return Response.ok(jsonEncode({'status': 'ok', 'size': body.length}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: 'Error: $e');
    }
  }

  Response _handleStatus(Request request) {
    return Response.ok(jsonEncode({
      'status': 'running',
      'port': _port,
      'hasApp': _currentAppCode != null,
      'appSize': _currentAppCode?.length ?? 0,
    }), headers: {'Content-Type': 'application/json'});
  }
  
  // Console buffer
  final List<Map<String, dynamic>> _consoleBuffer = [];
  
  void addConsoleLog(String msg, {String type = 'info'}) {
    _consoleBuffer.add({
      'time': DateTime.now().toIso8601String(),
      'type': type,
      'msg': msg,
    });
    if (_consoleBuffer.length > 500) _consoleBuffer.removeAt(0);
  }
  
  Future<Response> _handlePostConsole(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body);
      final msg = data['msg'] as String? ?? '';
      final type = data['type'] as String? ?? 'info';
      addConsoleLog(msg, type: type);
      return Response.ok(jsonEncode({'status': 'ok'}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: 'Error: $e');
    }
  }
  
  Future<Response> _handleValidate(Request request) async {
    try {
      final content = await rootBundle.loadString('assets/server/standalone/validate.html');
      return Response.ok(content, headers: {'Content-Type': 'text/html; charset=utf-8'});
    } catch (e) {
      return Response.ok('<h1>Validator</h1><p>Error loading: $e</p>', 
          headers: {'Content-Type': 'text/html; charset=utf-8'});
    }
  }
  
  Response _handleGetConsole(Request request) {
    final since = request.url.queryParameters['since'];
    List<Map<String, dynamic>> logs = _consoleBuffer;
    if (since != null) {
      logs = _consoleBuffer.where((e) => e['time'].compareTo(since) > 0).toList();
    }
    return Response.ok(jsonEncode({'logs': logs}),
        headers: {'Content-Type': 'application/json'});
  }
  
  Response _handleClearConsole(Request request) {
    _consoleBuffer.clear();
    return Response.ok(jsonEncode({'status': 'ok'}),
        headers: {'Content-Type': 'application/json'});
  }
}
