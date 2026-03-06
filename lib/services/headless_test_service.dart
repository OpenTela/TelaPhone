import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'local_server.dart';

/// Результат тестирования кода
class TestResult {
  final bool success;
  final List<String> errors;
  final List<String> warnings;
  final int testedFunctions;
  final Duration duration;
  
  TestResult({
    required this.success,
    this.errors = const [],
    this.warnings = const [],
    this.testedFunctions = 0,
    required this.duration,
  });
  
  @override
  String toString() => success 
      ? 'PASS: $testedFunctions functions tested' 
      : 'FAIL: ${errors.length} errors';
}

/// Headless WebView для тестирования кода в фоне
/// Прогревается при старте, готов к быстрому тестированию
class HeadlessTestService {
  static final HeadlessTestService _instance = HeadlessTestService._internal();
  factory HeadlessTestService() => _instance;
  HeadlessTestService._internal();
  
  HeadlessInAppWebView? _headless;
  bool _ready = false;
  bool _warming = false;
  
  final _readyCompleter = Completer<void>();
  Future<void> get whenReady => _readyCompleter.future;
  
  bool get isReady => _ready;
  
  // Console messages buffer
  final List<String> _consoleBuffer = [];
  
  // Test completion signal
  Completer<TestResult>? _testCompleter;
  Stopwatch? _testStopwatch;
  
  /// Прогреть WebView (вызывать при открытии редактора)
  Future<void> warmup() async {
    if (_ready || _warming) return;
    _warming = true;
    
    debugPrint('[HeadlessTest] Warming up...');
    
    final server = LocalServer();
    if (!server.isRunning) {
      await server.start();
    }
    
    final port = server.port;
    
    _headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://127.0.0.1:$port/'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        allowFileAccess: true,
        allowContentAccess: true,
      ),
      onWebViewCreated: (controller) {
        debugPrint('[HeadlessTest] WebView created');
      },
      onLoadStop: (controller, url) async {
        debugPrint('[HeadlessTest] Loaded: $url');
        
        // Проверяем готовность Lua
        await Future.delayed(const Duration(milliseconds: 500));
        
        final luaReady = await controller.evaluateJavascript(
          source: 'typeof luaReady !== "undefined" && luaReady'
        );
        
        if (luaReady == true) {
          _ready = true;
          _warming = false;
          if (!_readyCompleter.isCompleted) {
            _readyCompleter.complete();
          }
          debugPrint('[HeadlessTest] Ready!');
        } else {
          // Ждём ещё
          await Future.delayed(const Duration(seconds: 1));
          _ready = true;
          _warming = false;
          if (!_readyCompleter.isCompleted) {
            _readyCompleter.complete();
          }
          debugPrint('[HeadlessTest] Ready (delayed)');
        }
      },
      onConsoleMessage: (controller, message) {
        final msg = message.message;
        _consoleBuffer.add(msg);
        
        // Проверяем завершение autotest
        if (msg.startsWith('[autotest-done]')) {
          _handleTestComplete(msg);
        }
      },
      onReceivedError: (controller, request, error) {
        debugPrint('[HeadlessTest] Error: ${error.type} - ${error.description}');
      },
    );
    
    await _headless!.run();
  }
  
  /// Тестировать код
  Future<TestResult> test(String code, {Duration timeout = const Duration(seconds: 10)}) async {
    // Убеждаемся что WebView готов
    if (!_ready) {
      await warmup();
      await whenReady.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw Exception('WebView warmup timeout'),
      );
    }
    
    final server = LocalServer();
    final port = server.port;
    
    _consoleBuffer.clear();
    _testCompleter = Completer<TestResult>();
    _testStopwatch = Stopwatch()..start();
    
    try {
      // Очищаем console на сервере
      await http.delete(Uri.parse('http://127.0.0.1:$port/console'));
      
      // Загружаем код
      await http.post(
        Uri.parse('http://127.0.0.1:$port/app'),
        headers: {'Content-Type': 'text/plain'},
        body: code,
      );
      
      // Переходим на страницу с autotest
      await _headless!.webViewController?.loadUrl(
        urlRequest: URLRequest(
          url: WebUri('http://127.0.0.1:$port/app?autotest=1'),
        ),
      );
      
      // Ждём завершения теста или таймаут
      final result = await _testCompleter!.future.timeout(
        timeout,
        onTimeout: () => _buildResultFromConsole(),
      );
      
      return result;
      
    } catch (e) {
      _testStopwatch?.stop();
      return TestResult(
        success: false,
        errors: ['Test exception: $e'],
        duration: _testStopwatch?.elapsed ?? Duration.zero,
      );
    }
  }
  
  void _handleTestComplete(String msg) {
    _testStopwatch?.stop();
    
    try {
      // Parse: [autotest-done] {"success":true,...}
      final jsonStr = msg.replaceFirst('[autotest-done] ', '');
      final data = jsonDecode(jsonStr);
      
      final errors = <String>[];
      if (data['errors'] != null) {
        for (final e in data['errors']) {
          errors.add(e.toString());
        }
      }
      
      final result = TestResult(
        success: data['success'] == true,
        errors: errors,
        testedFunctions: data['tested'] ?? 0,
        duration: _testStopwatch?.elapsed ?? Duration.zero,
      );
      
      if (_testCompleter != null && !_testCompleter!.isCompleted) {
        _testCompleter!.complete(result);
      }
    } catch (e) {
      debugPrint('[HeadlessTest] Parse error: $e');
      if (_testCompleter != null && !_testCompleter!.isCompleted) {
        _testCompleter!.complete(_buildResultFromConsole());
      }
    }
  }
  
  TestResult _buildResultFromConsole() {
    _testStopwatch?.stop();
    
    final errors = <String>[];
    final warnings = <String>[];
    int tested = 0;
    
    for (final msg in _consoleBuffer) {
      if (msg.contains('[autotest-error]')) {
        errors.add(msg.replaceAll(RegExp(r'\[autotest-error\]\s*'), ''));
      } else if (msg.contains('[lua-err]')) {
        errors.add(msg.replaceAll(RegExp(r'\[lua-err\]\s*'), ''));
      } else if (msg.contains('[error]') || msg.contains('Error:')) {
        errors.add(msg);
      } else if (msg.contains('[warn]')) {
        warnings.add(msg);
      }
      
      // Count tested
      if (msg.contains('[autotest] PASS:')) {
        final match = RegExp(r'(\d+) functions').firstMatch(msg);
        if (match != null) tested = int.tryParse(match.group(1)!) ?? 0;
      }
    }
    
    return TestResult(
      success: errors.isEmpty,
      errors: errors,
      warnings: warnings,
      testedFunctions: tested,
      duration: _testStopwatch?.elapsed ?? Duration.zero,
    );
  }
  
  /// Освободить ресурсы
  Future<void> dispose() async {
    await _headless?.dispose();
    _headless = null;
    _ready = false;
    _warming = false;
  }
}
