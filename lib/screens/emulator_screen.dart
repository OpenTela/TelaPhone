import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../services/local_server.dart';
import '../services/ble_service.dart';

/// Результат работы эмулятора (для передачи ошибки обратно)
class EmulatorResult {
  final bool hasError;
  final String? errorMessage;
  final String? errorContext;
  
  EmulatorResult({this.hasError = false, this.errorMessage, this.errorContext});
}

class EmulatorScreen extends StatefulWidget {
  final String appName;
  final String code;

  const EmulatorScreen({
    super.key,
    required this.appName,
    required this.code,
  });

  @override
  State<EmulatorScreen> createState() => _EmulatorScreenState();
}

class _EmulatorScreenState extends State<EmulatorScreen> {
  WebViewController? _controller;
  bool _loading = true;
  String? _error;
  String? _serverUrl;
  StreamSubscription<String>? _logSubscription;
  
  final _server = LocalServer();
  final List<String> _logs = []; // Храним логи для контекста
  bool _errorDialogShown = false; // Защита от множественных диалогов
  bool _deploying = false;
  
  // Статус в title bar
  String? _statusText;
  Color? _statusColor;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _initServer();
    _listenLogs();
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }
  
  void _showStatus(String text, Color color, {int seconds = 3}) {
    _statusTimer?.cancel();
    setState(() {
      _statusText = text;
      _statusColor = color;
    });
    _statusTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) {
        setState(() {
          _statusText = null;
          _statusColor = null;
        });
      }
    });
  }

  void _listenLogs() {
    _logSubscription = _server.onLog.listen((log) {
      if (!mounted) return;
      
      // Сохраняем все логи
      _logs.add('[${DateTime.now().toString().substring(11, 19)}] $log');
      if (_logs.length > 50) _logs.removeAt(0); // Лимит
      
      // Показываем только внешние подключения (не 127.0.0.1) - pong зелёным
      if (log.contains('127.0.0.1')) return;
      
      _showStatus('← $log', const Color(0xFF22C55E), seconds: 3);
    });
  }

  Future<void> _initServer() async {
    try {
      // Читаем настройку удалённой отладки
      final prefs = await SharedPreferences.getInstance();
      final remoteDebug = prefs.getBool('remote_debug') ?? false;
      
      // Запускаем локальный сервер если не запущен
      if (!_server.isRunning) {
        await _server.start(port: 8842, localOnly: !remoteDebug);
      }
      
      // Загружаем код приложения в сервер
      _server.loadApp(widget.code);
      
      // Получаем URL сервера
      final urls = await _server.getServerUrls();
      _serverUrl = 'http://127.0.0.1:${_server.port}';
      
      if (urls.isNotEmpty) {
        debugPrint('[Emulator] Server URLs: $urls');
      }
      
      // Теперь инициализируем WebView
      await _initWebView();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Ошибка сервера: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _initWebView() async {
    if (_serverUrl == null) return;
    
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..addJavaScriptChannel(
          'FlutterError',
          onMessageReceived: (message) {
            _onRuntimeError(message.message);
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (url) {
              // runtime.html сам загрузит /app
              if (mounted) {
                setState(() => _loading = false);
              }
              // Инжектим перехватчик ошибок
              _injectErrorHandler();
            },
            onWebResourceError: (error) {
              if (mounted) {
                setState(() {
                  _error = error.description;
                  _loading = false;
                });
              }
            },
          ),
        );
      
      // Загружаем /app с локального сервера (автозагрузка кода)
      await controller.loadRequest(Uri.parse('$_serverUrl/app'));
      
      if (mounted) {
        setState(() {
          _controller = controller;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _injectErrorHandler() {
    _controller?.runJavaScript('''
      // Перехватываем console.error
      (function() {
        var originalError = console.error;
        console.error = function() {
          var msg = Array.prototype.slice.call(arguments).join(' ');
          originalError.apply(console, arguments);
          if (window.FlutterError) {
            FlutterError.postMessage(msg);
          }
        };
        
        // Ловим глобальные ошибки
        window.onerror = function(msg, url, line, col, error) {
          if (window.FlutterError) {
            FlutterError.postMessage('Error: ' + msg + ' (line ' + line + ')');
          }
        };
        
        // Ловим Lua ошибки через колбэк если есть
        if (typeof window.onLuaError === 'undefined') {
          window.onLuaError = function(err) {
            if (window.FlutterError) {
              FlutterError.postMessage('Lua: ' + err);
            }
          };
        }
      })();
    ''');
  }

  void _onRuntimeError(String errorMessage) {
    if (!mounted || _errorDialogShown) return;
    
    // Фильтруем шум
    if (errorMessage.contains('ResizeObserver') || 
        errorMessage.contains('Script error') ||
        errorMessage.length < 5) {
      return;
    }
    
    _logs.add('[ERROR] $errorMessage');
    _errorDialogShown = true;
    
    // Показываем диалог с предложением исправить
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 24),
            const SizedBox(width: 12),
            const Text('Ошибка выполнения', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                errorMessage.length > 200 
                    ? '${errorMessage.substring(0, 200)}...' 
                    : errorMessage,
                style: const TextStyle(
                  color: Color(0xFFEF4444),
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Исправить с помощью AI?',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
        actions: [
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx); // Закрыть диалог
              // Вернуться с ошибкой для AI
              Navigator.pop(context, EmulatorResult(
                hasError: true,
                errorMessage: errorMessage,
                errorContext: _logs.take(20).join('\n'),
              ));
            },
            icon: const Icon(Icons.auto_fix_high, size: 18),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
            label: const Text('Исправить'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _errorDialogShown = false; // Разрешаем новые диалоги
            },
            child: const Text('Игнорировать', style: TextStyle(color: Colors.white38)),
          ),
        ],
      ),
    );
  }

  void _reload() {
    setState(() {
      _loading = true;
      _controller = null;
      _error = null;
      _errorDialogShown = false;
    });
    _logs.clear();
    // Перезагружаем код
    _server.loadApp(widget.code);
    _initWebView();
  }

  Future<void> _deploy() async {
    final appName = widget.appName;
    
    // Проверяем имя
    if (appName.isEmpty || appName == 'preview') {
      _showNotification('Задайте имя приложения перед загрузкой', isError: true);
      return;
    }
    
    // Диалог подтверждения
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Загрузить на устройство?', style: TextStyle(color: Colors.white)),
        content: RichText(
          text: TextSpan(
            style: const TextStyle(color: Colors.white70, fontSize: 15),
            children: [
              const TextSpan(text: 'Приложение '),
              TextSpan(
                text: appName,
                style: const TextStyle(color: Color(0xFF22C55E), fontWeight: FontWeight.bold),
              ),
              const TextSpan(text: ' будет загружено на устройство.'),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF3B82F6)),
            child: const Text('Загрузить'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена', style: TextStyle(color: Colors.white38)),
          ),
        ],
      ),
    );
    
    if (confirmed != true) return;
    
    if (!mounted) return;
    setState(() => _deploying = true);
    
    try {
      final ble = context.read<BleService>();
      final ok = await ble.pushFile(appName, 'app.html', widget.code);
      
      if (mounted) {
        setState(() => _deploying = false);
        if (ok) {
          _showNotification('$appName загружен ✓');
        } else {
          _showNotification('Ошибка загрузки', isError: true);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _deploying = false);
        _showNotification('Ошибка: $e', isError: true);
      }
    }
  }
  
  void _showNotification(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 13)),
        backgroundColor: isError ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: MediaQuery.of(context).size.height - 140,
          left: 16,
          right: 16,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1117),
        title: _statusText != null
            ? Text(
                _statusText!,
                style: TextStyle(fontSize: 14, color: _statusColor, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              )
            : Row(
                children: [
                  const Icon(Icons.play_circle_outline, color: Color(0xFF22C55E), size: 20),
                  const SizedBox(width: 8),
                  Text(widget.appName, style: const TextStyle(fontSize: 16)),
                ],
              ),
        actions: [
          // Deploy на устройство
          IconButton(
            icon: _deploying 
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3B82F6)),
                  )
                : const Icon(Icons.cloud_upload_outlined),
            color: const Color(0xFF3B82F6),
            tooltip: 'Залить на устройство',
            onPressed: _deploying ? null : _deploy,
          ),
          // Показать URL сервера для отладки с ПК
          if (_serverUrl != null)
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'Server info',
              onPressed: _showServerInfo,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  void _showServerInfo() async {
    final urls = await _server.getServerUrls();
    if (!mounted) return;
    
    // Показываем первый URL (или localhost) в title bar
    final url = urls.isNotEmpty ? urls.first : 'localhost:8842';
    _showStatus(url, const Color(0xFF3B82F6), seconds: 5);
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text('Ошибка', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 18)),
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12), textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF22C55E)),
            SizedBox(height: 16),
            Text('Запуск сервера...', style: TextStyle(color: Colors.white38)),
          ],
        ),
      );
    }

    return Stack(
      children: [
        WebViewWidget(controller: controller),
        if (_loading)
          Container(
            color: Colors.black,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF22C55E)),
                  SizedBox(height: 16),
                  Text('Загрузка...', style: TextStyle(color: Colors.white38)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
