import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socks5_proxy/socks_client.dart';
import 'foreground_service.dart';

// UUIDs — должны совпадать с ESP32
const String serviceUuid = "12345678-1234-5678-1234-56789abcdef0";
const String txCharUuid = "12345678-1234-5678-1234-56789abcdef1"; // часы → телефон (JSON)
const String rxCharUuid = "12345678-1234-5678-1234-56789abcdef2"; // телефон → часы
const String binCharUuid = "12345678-1234-5678-1234-56789abcdef3"; // часы → телефон (binary)
const int maxBleSize = 180;

/// Запись в логе
class LogEntry {
  final DateTime timestamp;
  final String message;
  final LogLevel level;
  final String? details;

  LogEntry({
    required this.message,
    this.level = LogLevel.info,
    this.details,
  }) : timestamp = DateTime.now();
}

/// Ошибка fetch для toast уведомлений
class FetchError {
  final String code;      // offline, timeout, server, denied, not_found
  final String message;
  final int? http;        // HTTP код если есть

  FetchError(this.code, this.message, this.http);
  
  @override
  String toString() => http != null ? '$message (HTTP $http)' : message;
}

enum LogLevel { info, success, warning, error, incoming, outgoing }

/// Состояние подключения
enum BleConnectionState { disconnected, scanning, connecting, connected }

/// BLE Сервис — BLE подключение + HTTP прокси + бинарный скриншот
class BleService extends ChangeNotifier {
  // === BLE ===
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  BluetoothCharacteristic? _rxChar;
  BluetoothCharacteristic? _binChar;
  StreamSubscription? _txSubscription;
  StreamSubscription? _binSubscription;
  StreamSubscription? _connectionSubscription;
  List<ScanResult> _scanResults = [];

  // === Состояние ===
  BleConnectionState _connectionState = BleConnectionState.disconnected;
  String? _deviceName;
  String? _deviceAddress;
  final List<LogEntry> _logs = [];

  // === Автореконнект ===
  Timer? _reconnectTimer;
  int _reconnectDelay = 2; // секунды, растёт экспоненциально
  bool _manualDisconnect = false; // флаг ручного отключения

  // === Request/Response ===
  int _requestId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pendingRequests = {};

  // === API (убрано — ключи хранятся в services config) ===

  // === Services config (аналог services.yml) ===
  Map<String, Map<String, dynamic>> _servicesConfig = {};

  // === AI Providers (централизованная конфигурация) ===
  static const defaultModels = {
    'openai': 'gpt-5.2',
    'anthropic': 'claude-sonnet-4-5',
  };
  
  static const fallbackModels = {
    'openai': ['gpt-4.1-nano', 'gpt-5.2', 'o3'],
    'anthropic': ['claude-haiku-4-5', 'claude-sonnet-4-5', 'claude-opus-4-6'],
  };
  
  // Миграция устаревших имён моделей
  static const _modelMigrations = {
    'gpt-4o': 'gpt-5.2',
    'gpt-4o-mini': 'gpt-4.1-nano',
    'gpt-4-turbo': 'gpt-5.2',
    'gpt-3.5-turbo': 'gpt-4.1-nano',
    'claude-sonnet-4-20250514': 'claude-sonnet-4-5',
    'claude-3-5-sonnet-20241022': 'claude-sonnet-4-5',
    'claude-3-5-haiku-20241022': 'claude-haiku-4-5',
    'claude-opus-4-20250514': 'claude-opus-4-6',
    'claude-3-opus-20240229': 'claude-opus-4-6',
  };
  
  Map<String, Map<String, dynamic>> _aiProviders = {
    'openai': {'enabled': false, 'apiKey': '', 'model': defaultModels['openai']},
    'anthropic': {'enabled': false, 'apiKey': '', 'model': defaultModels['anthropic']},
  };
  
  // Прокси настройки
  // Форматы: socks5://host:port, socks5://user:pass@host:port, http://host:port
  String _proxyUrl = '';
  bool _proxyForAi = true;      // Использовать для AI API
  bool _proxyForWeb = false;    // Использовать для веб-запросов от часов
  
  String get proxyUrl => _proxyUrl;
  bool get proxyForAi => _proxyForAi;
  bool get proxyForWeb => _proxyForWeb;
  
  /// Прокси для AI (если включён)
  String get aiProxy => _proxyForAi ? _proxyUrl : '';
  /// Прокси для веб-запросов (если включён)
  String get webProxy => _proxyForWeb ? _proxyUrl : '';
  
  // Кэш моделей
  List<String>? _cachedOpenaiModels;
  List<String>? _cachedAnthropicModels;
  
  Map<String, Map<String, dynamic>> get aiProviders => Map.unmodifiable(_aiProviders);
  
  /// Получить модели OpenAI (с кэшированием)
  Future<List<String>> getOpenaiModels({bool forceRefresh = false}) async {
    if (_cachedOpenaiModels != null && !forceRefresh) return _cachedOpenaiModels!;
    
    final apiKey = _aiProviders['openai']?['apiKey'] as String?;
    if (apiKey == null || apiKey.isEmpty) {
      log('OpenAI: нет API ключа', level: LogLevel.warning);
      return fallbackModels['openai']!;
    }
    
    final client = _createHttpClient(aiProxy);
    
    try {
      log('OpenAI: загружаю модели...', level: LogLevel.info);
      final response = await client.get(
        Uri.parse('https://api.openai.com/v1/models'),
        headers: {'Authorization': 'Bearer $apiKey'},
      ).timeout(const Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final allModels = (data['data'] as List).map((m) => m['id'] as String).toList();
        log('OpenAI: получено ${allModels.length} моделей', level: LogLevel.info);
        
        final models = allModels
            // Whitelist: только чат-модели gpt-4+, o1+
            .where((id) => 
                id.startsWith('gpt-4') ||
                id.startsWith('gpt-5') ||
                id.startsWith('gpt-6') ||
                id.startsWith('gpt-7') ||
                id.startsWith('gpt-8') ||
                id.startsWith('gpt-9') ||
                RegExp(r'^o\d').hasMatch(id))  // o1, o3, o4...
            // Blacklist
            .where((id) => 
                !id.contains('audio') &&
                !id.contains('tts') &&
                !id.contains('transcribe') &&
                !id.contains('whisper') &&
                !id.contains('realtime') &&
                !id.contains('moderation') &&
                !id.contains('embedding') &&
                !id.contains('preview') &&        // preview версии
                !id.contains('image') &&          // image generation
                !id.contains('search') &&         // search-preview
                !id.contains('deep-research') &&  // deep-research
                !RegExp(r'-\d{4}-\d{2}-\d{2}$').hasMatch(id))  // dated snapshots
            .toList();
        
        log('OpenAI: после фильтрации ${models.length}', level: LogLevel.info);
        
        // Сортировка: по версии (от меньшей к большей)
        models.sort((a, b) {
          double version(String m) {
            final oMatch = RegExp(r'^o(\d+)').firstMatch(m);
            if (oMatch != null) return 100.0 + int.parse(oMatch.group(1)!);
            
            final vMatch = RegExp(r'(\d+)\.(\d+)').firstMatch(m);
            if (vMatch != null) {
              return double.parse('${vMatch.group(1)}.${vMatch.group(2)}');
            }
            
            final majorMatch = RegExp(r'gpt-(\d+)').firstMatch(m);
            if (majorMatch != null) return double.parse(majorMatch.group(1)!);
            
            return 0.0;
          }
          
          final vA = version(a);
          final vB = version(b);
          if (vA != vB) return vA.compareTo(vB);
          return a.compareTo(b);
        });
        
        _cachedOpenaiModels = models.isNotEmpty ? models : fallbackModels['openai']!;
        log('OpenAI модели: ${_cachedOpenaiModels!.length}', level: LogLevel.success);
        return _cachedOpenaiModels!;
      } else {
        log('OpenAI API ошибка: ${response.statusCode}', level: LogLevel.error);
      }
    } catch (e) {
      log('OpenAI исключение: $e', level: LogLevel.error);
    } finally {
      client.close();
    }
    return fallbackModels['openai']!;
  }
  
  /// Создать HTTP клиент с прокси
  http.Client _createHttpClient(String proxy) {
    if (proxy.isEmpty) {
      return http.Client();
    }
    
    try {
      final uri = Uri.parse(proxy);
      final scheme = uri.scheme.toLowerCase();
      
      if (scheme == 'socks5' || scheme == 'socks') {
        final host = uri.host;
        final port = uri.port != 0 ? uri.port : 1080;
        final client = HttpClient();
        
        if (uri.userInfo.isNotEmpty) {
          final parts = uri.userInfo.split(':');
          SocksTCPClient.assignToHttpClient(client, [
            ProxySettings(
              InternetAddress(host),
              port,
              username: parts[0],
              password: parts.length > 1 ? parts[1] : '',
            ),
          ]);
        } else {
          SocksTCPClient.assignToHttpClient(client, [
            ProxySettings(InternetAddress(host), port),
          ]);
        }
        return IOClient(client);
      } else if (scheme == 'http' || scheme == 'https') {
        final client = HttpClient();
        client.findProxy = (url) => 'PROXY ${uri.host}:${uri.port}';
        if (uri.userInfo.isNotEmpty) {
          final parts = uri.userInfo.split(':');
          client.addProxyCredentials(
            uri.host,
            uri.port,
            'Basic',
            HttpClientBasicCredentials(parts[0], parts.length > 1 ? parts[1] : ''),
          );
        }
        return IOClient(client);
      }
    } catch (e) {
      debugPrint('Ошибка прокси: $e');
    }
    return http.Client();
  }
  
  /// Получить модели Anthropic (с кэшированием)
  Future<List<String>> getAnthropicModels({bool forceRefresh = false}) async {
    if (_cachedAnthropicModels != null && !forceRefresh) return _cachedAnthropicModels!;
    
    final apiKey = _aiProviders['anthropic']?['apiKey'] as String?;
    if (apiKey == null || apiKey.isEmpty) {
      log('Anthropic: нет API ключа', level: LogLevel.warning);
      return fallbackModels['anthropic']!;
    }
    
    final client = _createHttpClient(aiProxy);
    
    try {
      log('Anthropic: загружаю модели...', level: LogLevel.info);
      final response = await client.get(
        Uri.parse('https://api.anthropic.com/v1/models'),
        headers: {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
      ).timeout(const Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final models = (data['data'] as List)
            .map((m) => m['id'] as String)
            .where((id) => id.startsWith('claude-'))
            .toList();
        
        log('Anthropic: получено ${models.length} моделей', level: LogLevel.info);
        
        // Сортировка по мощности: haiku < sonnet < opus
        int modelRank(String m) {
          if (m.contains('haiku')) return 0;
          if (m.contains('sonnet')) return 1;
          if (m.contains('opus')) return 2;
          return 3;
        }
        models.sort((a, b) => modelRank(a).compareTo(modelRank(b)));
        
        _cachedAnthropicModels = models.isNotEmpty ? models : fallbackModels['anthropic']!;
        log('Anthropic модели: ${_cachedAnthropicModels!.length}', level: LogLevel.success);
        return _cachedAnthropicModels!;
      } else {
        log('Anthropic API ошибка: ${response.statusCode}', level: LogLevel.error);
      }
    } catch (e) {
      log('Anthropic исключение: $e', level: LogLevel.error);
    } finally {
      client.close();
    }
    return fallbackModels['anthropic']!;
  }
  
  /// Сбросить кэш моделей (при смене API ключа)
  void clearModelsCache(String provider) {
    if (provider == 'openai') _cachedOpenaiModels = null;
    if (provider == 'anthropic') _cachedAnthropicModels = null;
  }

  // === Данные с часов ===
  String _watchTime = '--:--';
  int _watchBattery = 0;
  String _watchStatus = 'Нет данных';
  int _requestCount = 0;
  
  // === Device info (from sync) ===
  String _deviceProtocol = '';
  String _deviceOs = '';
  String _deviceChip = '';
  int _deviceUptime = 0;
  
  // === Time tracking ===
  int _lastSyncEpoch = 0;  // epoch from last sync
  DateTime? _lastSyncLocal;  // local time when sync happened
  Timer? _timeUpdateTimer;
  Timer? _periodicSyncTimer;

  // === Screenshot ===
  bool screenshotInProgress = false;
  bool transferTimeout = false;
  Timer? _transferTimeoutTimer;
  int screenshotProgress = 0;
  int screenshotTotal = 0;
  final Map<int, List<int>> _screenshotChunks = {};
  int _screenshotWidth = 0;
  int _screenshotHeight = 0;
  String _screenshotFormat = "rgb565";
  String _screenshotColor = "rgb16";
  int _screenshotRawSize = 0;
  List<int>? lastScreenshotData;
  
  void _resetTransferTimeout() {
    _transferTimeoutTimer?.cancel();
    transferTimeout = false;
    _transferTimeoutTimer = Timer(const Duration(seconds: 8), () {
      if (screenshotInProgress) {
        debugPrint('[SCREENSHOT] Timeout!');
        transferTimeout = true;
        screenshotInProgress = false;
        _screenshotChunks.clear();
        _expectedBytes = null;
        _receivedBytes = 0;
        notifyListeners();
      }
    });
  }
  
  void _cancelTransferTimeout() {
    _transferTimeoutTimer?.cancel();
    _transferTimeoutTimer = null;
    transferTimeout = false;
  }

  // === Fetch errors stream (для toast) ===
  final _fetchErrorController = StreamController<FetchError>.broadcast();
  Stream<FetchError> get fetchErrors => _fetchErrorController.stream;

  // === Apps (список приложений на часах) ===
  List<String> _apps = [];
  bool _appsLoading = false;
  List<String> get apps => _apps;
  bool get appsLoading => _appsLoading;

  // === Конструктор ===
  BleService() {
    _loadServicesConfig();
    _loadAiProviders();
    _tryAutoConnect();
  }

  /// Автоподключение к последнему устройству
  Future<void> _tryAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final lastAddress = prefs.getString('last_device_address');
    final lastName = prefs.getString('last_device_name');
    
    if (lastAddress == null) return;
    
    log('Автоподключение к $lastName...', level: LogLevel.info);
    
    // Небольшая задержка чтобы BLE стек инициализировался
    await Future.delayed(const Duration(milliseconds: 500));
    
    try {
      await connect(lastAddress, name: lastName);
    } catch (e) {
      log('Автоподключение не удалось: $e', level: LogLevel.warning);
    }
  }

  /// Сохранить последнее устройство
  Future<void> _saveLastDevice(String address, String? name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_device_address', address);
    if (name != null) {
      await prefs.setString('last_device_name', name);
    }
  }

  /// Очистить последнее устройство (при явном отключении)
  Future<void> _clearLastDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('last_device_address');
    await prefs.remove('last_device_name');
  }

  // === Геттеры ===
  BleConnectionState get connectionState => _connectionState;
  String? get deviceName => _deviceName;
  String? get deviceAddress => _deviceAddress;
  List<LogEntry> get logs => List.unmodifiable(_logs);
  bool get isConnected => _connectionState == BleConnectionState.connected;

  String get watchTime => _watchTime;
  int get watchBattery => _watchBattery;
  String get watchStatus => _watchStatus;
  int get requestCount => _requestCount;
  
  String get requestCountFormatted {
    if (_requestCount >= 1000000) {
      return '${(_requestCount / 1000000).toStringAsFixed(1)}M';
    } else if (_requestCount >= 1000) {
      return '${(_requestCount / 1000).toStringAsFixed(1)}k';
    }
    return _requestCount.toString();
  }
  
  // Device info getters
  String get deviceProtocol => _deviceProtocol;
  String get deviceOs => _deviceOs;
  String get deviceChip => _deviceChip;
  int get deviceUptime => _deviceUptime;
  
  Map<String, Map<String, dynamic>> get servicesConfig =>
      Map.unmodifiable(_servicesConfig);
  int get screenshotWidth => _screenshotWidth;
  int get screenshotHeight => _screenshotHeight;
  String get screenshotColorFormat => _screenshotColor;

  // =====================================================
  //  ЛОГИРОВАНИЕ
  // =====================================================

  void log(String message, {LogLevel level = LogLevel.info, String? details}) {
    _logs.insert(0, LogEntry(message: message, level: level, details: details));
    if (_logs.length > 500) {
      _logs.removeLast();
    }
    // Console output for adb logcat
    debugPrint('[BLE] $message${details != null ? " | $details" : ""}');
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  // =====================================================
  //  SERVICES CONFIG (домен → JSON конфиг с реальными значениями)
  // =====================================================

  Future<void> _loadServicesConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configJson = prefs.getString('services_config');
      if (configJson != null) {
        final decoded = json.decode(configJson) as Map<String, dynamic>;
        _servicesConfig = decoded.map((key, value) =>
            MapEntry(key, Map<String, dynamic>.from(value as Map)));
      } else {
        // Дефолт — пустой конфиг погоды (пользователь впишет ключ)
        _servicesConfig = {
          'api.openweathermap.org': {
            'query': {
              'appid': '',
              'units': 'metric',
              'lang': 'ru',
            }
          },
        };
        await _saveServicesConfig();
      }
    } catch (e) {
      debugPrint('Ошибка загрузки services config: $e');
    }
  }

  Future<void> _saveServicesConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('services_config', json.encode(_servicesConfig));
  }

  Future<void> setServiceConfig(String domain, Map<String, dynamic> config) async {
    _servicesConfig[domain] = config;
    await _saveServicesConfig();
    notifyListeners();
  }

  Future<void> removeServiceConfig(String domain) async {
    _servicesConfig.remove(domain);
    await _saveServicesConfig();
    notifyListeners();
  }

  // =====================================================
  //  AI PROVIDERS CONFIG
  // =====================================================

  Future<void> _loadAiProviders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configJson = prefs.getString('ai_providers');
      if (configJson != null) {
        final decoded = json.decode(configJson) as Map<String, dynamic>;
        _aiProviders = decoded.map((key, value) =>
            MapEntry(key, Map<String, dynamic>.from(value as Map)));
        
        // Миграция старых имён моделей
        bool needsSave = false;
        for (final provider in _aiProviders.keys) {
          final model = _aiProviders[provider]?['model'] as String?;
          if (model != null && _modelMigrations.containsKey(model)) {
            _aiProviders[provider]!['model'] = _modelMigrations[model];
            needsSave = true;
            debugPrint('Мигрировал модель $model → ${_modelMigrations[model]}');
          }
        }
        if (needsSave) await _saveAiProviders();
      }
      
      // Загружаем прокси
      _proxyUrl = prefs.getString('proxy_url') ?? '';
      _proxyForAi = prefs.getBool('proxy_for_ai') ?? true;
      _proxyForWeb = prefs.getBool('proxy_for_web') ?? false;
    } catch (e) {
      debugPrint('Ошибка загрузки AI providers: $e');
    }
  }

  Future<void> _saveAiProviders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_providers', json.encode(_aiProviders));
  }
  
  Future<void> setProxy({String? url, bool? forAi, bool? forWeb}) async {
    final prefs = await SharedPreferences.getInstance();
    if (url != null) {
      _proxyUrl = url;
      await prefs.setString('proxy_url', url);
    }
    if (forAi != null) {
      _proxyForAi = forAi;
      await prefs.setBool('proxy_for_ai', forAi);
    }
    if (forWeb != null) {
      _proxyForWeb = forWeb;
      await prefs.setBool('proxy_for_web', forWeb);
    }
    notifyListeners();
  }

  Future<void> setAiProvider(String provider, {bool? enabled, String? apiKey, String? model}) async {
    final current = _aiProviders[provider] ?? {'enabled': false, 'apiKey': '', 'model': ''};
    if (enabled != null) current['enabled'] = enabled;
    if (apiKey != null) current['apiKey'] = apiKey;
    if (model != null) current['model'] = model;
    _aiProviders[provider] = current;
    await _saveAiProviders();
    notifyListeners();
  }
  
  /// Получить активного AI провайдера (первый включённый с ключом)
  Map<String, dynamic>? getActiveAiProvider() {
    for (final entry in _aiProviders.entries) {
      if (entry.value['enabled'] == true && 
          (entry.value['apiKey'] as String?)?.isNotEmpty == true) {
        return {'provider': entry.key, ...entry.value};
      }
    }
    return null;
  }

  /// Подставляет параметры из services config в запрос
  _ServiceResult _injectServiceConfig(
      String url, String method, Map<String, String> headers, String? body) {
    final uri = Uri.parse(url);
    final domain = uri.host;

    final config = _servicesConfig[domain];
    if (config == null) {
      log('Домен "$domain" не в конфиге', level: LogLevel.warning);
      return _ServiceResult(url: url, headers: headers, body: body);
    }

    log('Конфиг: $domain', level: LogLevel.info);

    // Query параметры — значения напрямую
    final queryConfig = config['query'] as Map<String, dynamic>?;
    if (queryConfig != null) {
      final queryParams = Map<String, String>.from(uri.queryParameters);

      for (final entry in queryConfig.entries) {
        final value = entry.value.toString();
        if (value.isEmpty) {
          return _ServiceResult(
            url: url,
            headers: headers,
            body: body,
            error: "Параметр '${entry.key}' пуст для $domain. Заполните в Настройки → Сервисы",
          );
        }
        queryParams[entry.key] = value;
      }

      url = uri.replace(queryParameters: queryParams).toString();
    }

    // Headers — значения напрямую
    final headersConfig = config['headers'] as Map<String, dynamic>?;
    if (headersConfig != null) {
      for (final entry in headersConfig.entries) {
        headers[entry.key] = entry.value.toString();
      }
    }

    return _ServiceResult(url: url, headers: headers, body: body);
  }

  // =====================================================
  //  СКАНИРОВАНИЕ
  // =====================================================

  Future<List<Map<String, String>>> scanDevices() async {
    _connectionState = BleConnectionState.scanning;
    notifyListeners();
    log('Сканирование BLE...');

    try {
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (e) {
          log('Включите Bluetooth!', level: LogLevel.error);
          _connectionState = BleConnectionState.disconnected;
          notifyListeners();
          return [];
        }
      }

      _scanResults = [];
      final subscription = FlutterBluePlus.scanResults.listen((results) {
        _scanResults = results;
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      await Future.delayed(const Duration(seconds: 5));
      subscription.cancel();

      // Фильтруем: наш SERVICE_UUID в advertised services, или имя содержит "Clock"
      final targetGuid = Guid(serviceUuid);
      final compatible = _scanResults.where((r) {
        // По advertised service UUID
        if (r.advertisementData.serviceUuids.contains(targetGuid)) return true;
        // По имени (fallback если UUID не в advertising)
        final name = r.device.platformName.toLowerCase();
        if (name.contains('clock') || name.contains('future') ||
            name.contains('eos') || name.contains('evolution') ||
            name.contains('blank')) return true;
        return false;
      }).toList();

      final devices = compatible
          .map((r) => {
                'name': r.device.platformName.isNotEmpty
                    ? r.device.platformName
                    : 'Unknown (${r.device.remoteId.str.substring(0, 8)}...)',
                'address': r.device.remoteId.str,
                'rssi': r.rssi.toString(),
              })
          .toList();

      devices.sort(
          (a, b) => int.parse(b['rssi']!).compareTo(int.parse(a['rssi']!)));

      log('Найдено ${devices.length} из ${_scanResults.length} (фильтр)',
          level: LogLevel.success);
      _connectionState = BleConnectionState.disconnected;
      notifyListeners();
      return devices;
    } catch (e) {
      log('Ошибка сканирования: $e', level: LogLevel.error);
      _connectionState = BleConnectionState.disconnected;
      notifyListeners();
      return [];
    }
  }

  // =====================================================
  //  ПОДКЛЮЧЕНИЕ
  // =====================================================

  Future<bool> connect(String address, {String? name}) async {
    // Сбрасываем состояние реконнекта
    _manualDisconnect = false;
    _cancelReconnect();
    
    _connectionState = BleConnectionState.connecting;
    notifyListeners();
    log('Подключение к ${name ?? address}...');

    try {
      BluetoothDevice device;
      final found =
          _scanResults.where((r) => r.device.remoteId.str == address);
      if (found.isNotEmpty) {
        device = found.first.device;
      } else {
        device = BluetoothDevice.fromId(address);
      }

      await device.connect(timeout: const Duration(seconds: 10));
      _device = device;

      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      List<BluetoothService> services = await device.discoverServices();

      BluetoothService? targetService;
      for (var s in services) {
        if (s.uuid == Guid(serviceUuid)) {
          targetService = s;
          break;
        }
      }

      if (targetService == null) {
        log('Сервис FutureClock не найден!', level: LogLevel.error);
        await device.disconnect();
        _connectionState = BleConnectionState.disconnected;
        notifyListeners();
        return false;
      }

      // Находим характеристики — TX (JSON), RX, BIN (binary)
      for (var c in targetService.characteristics) {
        if (c.uuid == Guid(txCharUuid)) {
          _txChar = c;
        } else if (c.uuid == Guid(rxCharUuid)) {
          _rxChar = c;
        } else if (c.uuid == Guid(binCharUuid)) {
          _binChar = c;
        }
      }

      if (_txChar == null || _rxChar == null) {
        log('TX/RX характеристики не найдены!', level: LogLevel.error);
        await device.disconnect();
        _connectionState = BleConnectionState.disconnected;
        notifyListeners();
        return false;
      }

      // Подписываемся на JSON-нотификации
      await _txChar!.setNotifyValue(true);
      _txSubscription = _txChar!.onValueReceived.listen(_onWatchMessage);

      // Подписываемся на бинарные данные (скриншот)
      if (_binChar != null) {
        await _binChar!.setNotifyValue(true);
        _binSubscription = _binChar!.onValueReceived.listen(_onBinaryData);
        log('BIN характеристика ✓', level: LogLevel.success);
      } else {
        log('BIN характеристика не найдена', level: LogLevel.warning);
      }

      _connectionState = BleConnectionState.connected;
      _deviceName = name ?? device.platformName;
      _deviceAddress = address;
      _watchStatus = 'Ready';
      _reconnectDelay = 2; // Сброс при успехе
      
      // Чистый transfer state при новом подключении
      _activeTransferId = null;
      _transferChunks.clear();
      _transferCallbacks.clear();
      _expectedBytes = null;
      _receivedBytes = 0;
      screenshotInProgress = false;
      _screenshotChunks.clear();

      notifyListeners();
      log('Подключено: $_deviceName', level: LogLevel.success);
      
      // Сохраняем для автоподключения
      _saveLastDevice(address, _deviceName);
      
      // Синхронизация протокола и времени
      await sysSync();
      
      // Запуск foreground service
      await BleBackgroundService.start(
        deviceName: _deviceName,
        battery: _watchBattery,
        requests: _requestCount,
      );
      
      // Автозагрузка списка приложений
      _loadAppsInBackground();
      
      return true;
    } catch (e) {
      log('Ошибка подключения: $e', level: LogLevel.error);
      _connectionState = BleConnectionState.disconnected;
      notifyListeners();
      return false;
    }
  }

  void _onDisconnected() {
    // Сохраняем данные для реконнекта ДО очистки
    final lastAddress = _deviceAddress;
    final lastName = _deviceName;
    
    _txSubscription?.cancel();
    _binSubscription?.cancel();
    _connectionSubscription?.cancel();
    _txChar = null;
    _rxChar = null;
    _binChar = null;
    _device = null;
    _connectionState = BleConnectionState.disconnected;
    _deviceName = null;
    _deviceAddress = null;
    _watchStatus = 'Нет данных';
    _watchTime = '--:--';
    _watchBattery = 0;
    _apps = [];
    _appsLoading = false;
    _pendingRequests.forEach((_, c) {
      if (!c.isCompleted) c.completeError('Disconnected');
    });
    _pendingRequests.clear();
    
    // Очищаем transfer state
    _activeTransferId = null;
    _transferChunks.clear();
    _transferCallbacks.clear();
    _expectedBytes = null;
    _receivedBytes = 0;
    screenshotInProgress = false;
    _screenshotChunks.clear();
    
    // Stop timers and reset time tracking
    _stopTimers();
    _lastSyncEpoch = 0;
    _lastSyncLocal = null;
    
    notifyListeners();
    log('Соединение потеряно', level: LogLevel.warning);
    
    // Обновляем уведомление foreground service
    BleBackgroundService.updateNotification(isConnected: false);
    
    // Автореконнект если не было ручного отключения
    if (!_manualDisconnect && lastAddress != null) {
      _scheduleReconnect(lastAddress, lastName);
    }
  }
  
  void _scheduleReconnect(String address, String? name) {
    _reconnectTimer?.cancel();
    
    log('Реконнект через ${_reconnectDelay}с...', level: LogLevel.info);
    
    _reconnectTimer = Timer(Duration(seconds: _reconnectDelay), () async {
      if (_connectionState != BleConnectionState.disconnected) return;
      if (_manualDisconnect) return;
      
      log('Попытка реконнекта к $name...', level: LogLevel.info);
      final ok = await connect(address, name: name);
      
      if (!ok && !_manualDisconnect) {
        // Увеличиваем delay (max 60 сек)
        _reconnectDelay = (_reconnectDelay * 2).clamp(2, 60);
        _scheduleReconnect(address, name);
      }
    });
  }
  
  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectDelay = 2;
  }

  Future<void> disconnect() async {
    log('Отключение...');
    _manualDisconnect = true;
    _cancelReconnect();
    
    _txSubscription?.cancel();
    _binSubscription?.cancel();
    _connectionSubscription?.cancel();

    try {
      if (_device != null) {
        await _device!.disconnect();
      }
    } catch (_) {}

    _device = null;
    _txChar = null;
    _rxChar = null;
    _binChar = null;
    _connectionState = BleConnectionState.disconnected;
    _deviceName = null;
    _deviceAddress = null;
    _watchStatus = 'Нет данных';
    _pendingRequests.clear();
    
    // Очищаем transfer state
    _activeTransferId = null;
    _transferChunks.clear();
    _transferCallbacks.clear();
    _expectedBytes = null;
    _receivedBytes = 0;
    screenshotInProgress = false;
    _screenshotChunks.clear();
    
    notifyListeners();
    log('Отключено', level: LogLevel.success);
  }

  // =====================================================
  //  JSON СООБЩЕНИЯ ОТ ЧАСОВ (TX characteristic)
  //  С поддержкой reassembly для больших ответов
  // =====================================================

  // JSON ответы от часов (TX characteristic)

  void _onWatchMessage(List<int> data) {
    try {
      final jsonStr = utf8.decode(data);
      log('RX raw: $jsonStr', level: LogLevel.incoming);
      final parsed = json.decode(jsonStr);
      _routeMessage(parsed);
    } catch (e) {
      log('RX JSON error (${data.length}b): $e', level: LogLevel.error);
      log('RX raw bytes: ${data.take(100).toList()}', level: LogLevel.error);
    }
  }

  /// Роутер: array = v2 протокол, object = legacy (только fetch)
  void _routeMessage(dynamic parsed) {
    if (parsed is List) {
      _processArrayMessage(parsed);
    } else if (parsed is Map<String, dynamic>) {
      _processLegacyMessage(parsed);
    } else {
      log('RX unknown type: ${parsed.runtimeType}', level: LogLevel.warning);
    }
  }

  /// v2 протокол: [id, status, data]
  void _processArrayMessage(List msg) {
    if (msg.length < 2) return;

    final id = msg[0] as int;
    final status = msg[1] as String;
    final data = msg.length > 2 ? msg[2] : <String, dynamic>{};

    final result = <String, dynamic>{
      'status': status,
      if (data is Map) ...Map<String, dynamic>.from(data),
    };

    log('RESP #$id: $status ${data is Map ? json.encode(data) : data}', 
        level: LogLevel.incoming);

    final completer = _pendingRequests.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    } else {
      log('No pending request for #$id', level: LogLevel.warning);
    }
  }

  /// Legacy: только fetch запросы от часов {method, url} и screenshot {cmd}
  void _processLegacyMessage(Map<String, dynamic> msg) {
    if (msg['cmd'] == 'screenshot') {
      _handleScreenshotMessage(msg);
    } else if (msg.containsKey('method') && msg.containsKey('url')) {
      final msgId = msg['id'] ?? '?';
      log('FETCH #$msgId: ${msg['method']} ${msg['url']}',
          level: LogLevel.incoming);
      if (msg['headers'] != null) {
        log('  headers: ${json.encode(msg['headers'])}', level: LogLevel.info);
      }
      if (msg['body'] != null) {
        log('  body: ${msg['body']}', level: LogLevel.info);
      }
      if (msg['authorize'] == true) {
        log('  authorize: true, fields: ${msg['fields']}', level: LogLevel.info);
      }
      _handleHttpProxy(msg);
    } else {
      log('RX legacy: ${json.encode(msg)}', level: LogLevel.incoming);
    }
  }

  // =====================================================
  //  БИНАРНЫЕ ДАННЫЕ (BIN characteristic)
  //  Формат: [2B chunk_id LE][raw data]
  // =====================================================

  // =====================================================
  //  BINARY TRANSFER (BIN_CHAR) — v2.2
  //  Size-based завершение + fallback на end marker
  // =====================================================

  // Активные трансферы: transfer_id → callback
  final Map<int, void Function(Uint8List data)> _transferCallbacks = {};
  int? _activeTransferId;
  final Map<int, List<int>> _transferChunks = {};
  
  // v2.2: size-based завершение
  int? _expectedBytes;
  int _receivedBytes = 0;

  void _onBinaryData(List<int> data) {
    if (data.length < 2) {
      debugPrint('[BIN] SKIP: too short');
      return;
    }

    final chunkIdx = data[0] | (data[1] << 8);
    final chunkData = data.sublist(2);

    // Логируем
    if (chunkIdx % 10 == 0 || chunkIdx < 3 || chunkIdx == 0xFFFF) {
      debugPrint('[BIN] #$chunkIdx: ${chunkData.length}b, recv=$_receivedBytes, expect=${_expectedBytes ?? "?"}');
    }

    // End marker (fallback для v2.1)
    if (chunkIdx == 0xFFFF) {
      debugPrint('[BIN] End marker');
      _finishTransfer();
      return;
    }

    // Screenshot path
    if (screenshotInProgress && _activeTransferId == null) {
      _screenshotChunks[chunkIdx] = chunkData;
      _receivedBytes += chunkData.length;
      screenshotProgress = _screenshotChunks.length;
      _resetTransferTimeout();
      notifyListeners();
      
      // v2.2: завершение по размеру
      if (_expectedBytes != null && _receivedBytes >= _expectedBytes!) {
        debugPrint('[BIN] Screenshot complete by size: $_receivedBytes >= $_expectedBytes');
        _finishScreenshotBySize();
      }
      return;
    }

    // Generic transfer
    if (_activeTransferId != null) {
      _transferChunks[chunkIdx] = chunkData;
      _receivedBytes += chunkData.length;

      // v2.2: завершение по размеру
      if (_expectedBytes != null && _receivedBytes >= _expectedBytes!) {
        debugPrint('[BIN] Transfer complete by size: $_receivedBytes >= $_expectedBytes');
        _finishTransfer();
      }
    }
  }
  
  void _finishScreenshotBySize() {
    // Собираем по порядку
    final assembled = <int>[];
    final keys = _screenshotChunks.keys.toList()..sort();
    for (final k in keys) {
      assembled.addAll(_screenshotChunks[k]!);
    }
    
    log('Screenshot done: ${assembled.length}b, ${keys.length} chunks', level: LogLevel.success);
    
    // Декомпрессия
    List<int> rawData;
    if (_screenshotFormat == 'lz4') {
      try {
        rawData = _decompressLz4Block(Uint8List.fromList(assembled));
        log('LZ4: ${assembled.length} → ${rawData.length}b', level: LogLevel.success);
      } catch (e) {
        log('LZ4 error: $e', level: LogLevel.error);
        rawData = assembled;
      }
    } else {
      rawData = assembled;
    }

    lastScreenshotData = rawData;
    _screenshotChunks.clear();
    _cancelTransferTimeout();
    screenshotInProgress = false;
    _expectedBytes = null;
    _receivedBytes = 0;
    notifyListeners();
  }

  void _finishTransfer() {
    debugPrint('[BIN] _finishTransfer called: screenshot=$screenshotInProgress, activeId=$_activeTransferId, chunks=${_transferChunks.length}, recv=$_receivedBytes, expect=$_expectedBytes');
    
    // Screenshot path (для end marker)
    if (screenshotInProgress && _activeTransferId == null) {
      _finishScreenshotBySize();
      return;
    }

    // Generic transfer — собираем по порядку
    final assembled = <int>[];
    final sortedKeys = _transferChunks.keys.toList()..sort();
    for (final key in sortedKeys) {
      assembled.addAll(_transferChunks[key]!);
    }
    _transferChunks.clear();

    log('Transfer done: ${assembled.length}b, ${sortedKeys.length} chunks',
        level: LogLevel.success);

    final tid = _activeTransferId;
    _activeTransferId = null;
    _expectedBytes = null;
    _receivedBytes = 0;

    if (tid != null && _transferCallbacks.containsKey(tid)) {
      debugPrint('[BIN] Completing transfer #$tid with ${assembled.length}b');
      _transferCallbacks.remove(tid)!(Uint8List.fromList(assembled));
    } else {
      debugPrint('[BIN] WARNING: No callback for transfer #$tid, callbacks=${_transferCallbacks.keys}');
    }
  }

  /// Ждём binary transfer с данным transfer_id
  Future<Uint8List?> _awaitTransfer(int transferId,
      {Duration timeout = const Duration(seconds: 15)}) {
    final completer = Completer<Uint8List>();
    _activeTransferId = transferId;
    _transferChunks.clear();
    _expectedBytes = null;
    _receivedBytes = 0;
    _transferCallbacks[transferId] = (data) {
      if (!completer.isCompleted) completer.complete(data);
    };

    return completer.future.timeout(timeout, onTimeout: () {
      _transferCallbacks.remove(transferId);
      _activeTransferId = null;
      _transferChunks.clear();
      _expectedBytes = null;
      _receivedBytes = 0;
      log('Transfer #$transferId timeout', level: LogLevel.error);
      return Uint8List(0);
    });
  }

  /// Подготовить приём binary ДО отправки команды.
  Future<Uint8List> _prepareBinaryTransfer(
      {Duration timeout = const Duration(seconds: 15)}) {
    final completer = Completer<Uint8List>();
    _activeTransferId = 0; // sentinel — включаем generic accumulation
    _transferChunks.clear();
    _expectedBytes = null;
    _receivedBytes = 0;
    _transferCallbacks[0] = (data) {
      if (!completer.isCompleted) completer.complete(data);
    };

    return completer.future.timeout(timeout, onTimeout: () {
      _transferCallbacks.remove(0);
      _activeTransferId = null;
      _transferChunks.clear();
      _expectedBytes = null;
      _receivedBytes = 0;
      log('Binary transfer timeout', level: LogLevel.error);
      return Uint8List(0);
    });
  }
  
  /// v2.2: установить ожидаемый размер после получения JSON
  void _setExpectedBytes(int bytes) {
    _expectedBytes = bytes;
    debugPrint('[BIN] Expected: $bytes, have: $_receivedBytes');
    
    // Уже набрали?
    if (_receivedBytes >= bytes) {
      _finishTransfer();
    }
  }

  void _cancelBinaryTransfer() {
    _transferCallbacks.remove(0);
    _activeTransferId = null;
    _transferChunks.clear();
    _expectedBytes = null;
    _receivedBytes = 0;
  }

  // =====================================================
  //  HTTP ПРОКСИ (с authorize + services config)
  // =====================================================

  Future<void> _handleHttpProxy(Map<String, dynamic> request) async {
    final msgId = request['id'] ?? 0;
    final method = (request['method'] ?? 'GET').toString().toUpperCase();
    String url = request['url'];
    Map<String, String> headers = {};
    if (request['headers'] != null) {
      headers = Map<String, String>.from(request['headers']);
    }
    String? body = request['body']?.toString();
    final authorize = request['authorize'] == true;
    final fmt = request['format'];
    final fields = (request['fields'] as List?)?.cast<String>() ?? [];

    // 1. Авторизация через services config
    if (authorize) {
      final result = _injectServiceConfig(url, method, headers, body);
      if (result.error != null) {
        await _sendErrorResponse(msgId, 'invalid', result.error!);
        return;
      }
      url = result.url;
      headers = result.headers;
      body = result.body;
    }

    log('HTTP $method $url', level: LogLevel.info);
    if (headers.isNotEmpty) {
      log('  req headers: ${json.encode(headers)}', level: LogLevel.info);
    }
    if (body != null && body.isNotEmpty) {
      log('  req body: $body', level: LogLevel.info);
    }

    try {
      http.Response response;
      final uri = Uri.parse(url);

      switch (method) {
        case 'POST':
          response = await http
              .post(uri, headers: headers, body: body)
              .timeout(const Duration(seconds: 10));
          break;
        case 'PUT':
          response = await http
              .put(uri, headers: headers, body: body)
              .timeout(const Duration(seconds: 10));
          break;
        default:
          response = await http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 10));
      }

      final status = response.statusCode;
      log('HTTP resp $status (${response.body.length}b)',
          level: status == 200 ? LogLevel.success : LogLevel.warning);
      log('  resp body: ${response.body}', level: LogLevel.info);

      if (status != 200) {
        final code = _httpToErrorCode(status);
        await _sendErrorResponse(msgId, code, 'API вернул $status', http: status);
        _fetchErrorController.add(FetchError(code, 'HTTP $status', status));
        return;
      }

      String responseBody = response.body;

      // Извлечение полей
      if (fmt == 'json' && fields.isNotEmpty) {
        try {
          final data = json.decode(responseBody);
          final extracted = _extractFields(data, fields);
          if (extracted != null) {
            responseBody = json.encode(extracted);
            log('Извлечено полей: ${fields.length}', level: LogLevel.success);
          } else {
            await _sendErrorResponse(msgId, 'not_found', 'Поля не найдены');
            return;
          }
        } catch (e) {
          await _sendErrorResponse(msgId, 'invalid', 'JSON ошибка: $e');
          return;
        }
      }

      // Формируем ответ
      final resp = {'id': msgId, 'status': status, 'body': responseBody};
      final respJson = json.encode(resp);

      if (respJson.length > maxBleSize) {
        await _sendErrorResponse(
          msgId,
          'memory',
          'Ответ ${respJson.length}b > ${maxBleSize}b. Используй fields!',
          http: 413,
        );
        return;
      }

      await sendToWatch(resp);
      _requestCount++;
      notifyListeners();
      
      // Обновляем уведомление
      BleBackgroundService.updateNotification(
        deviceName: _deviceName,
        battery: _watchBattery,
        requests: _requestCount,
      );
      
      log('→ ответ на часы: ${respJson.length}b', level: LogLevel.outgoing);
    } on TimeoutException {
      await _sendErrorResponse(msgId, 'timeout', 'HTTP таймаут', http: 408);
    } on SocketException catch (e) {
      // Нет интернета
      await _sendErrorResponse(msgId, 'offline', 'Нет подключения к интернету');
      _fetchErrorController.add(FetchError('offline', 'Нет интернета', null));
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('SocketException') || msg.contains('Network is unreachable')) {
        await _sendErrorResponse(msgId, 'offline', 'Нет подключения к интернету');
        _fetchErrorController.add(FetchError('offline', 'Нет интернета', null));
      } else {
        await _sendErrorResponse(msgId, 'server', 'HTTP ошибка: $e', http: 500);
        _fetchErrorController.add(FetchError('server', msg, 500));
      }
    }
  }

  /// Отправляет ошибку на часы в формате v2.1
  /// code: offline, timeout, server, denied, not_found, invalid, busy, memory
  Future<void> _sendErrorResponse(int msgId, String code, String message, {int? http}) async {
    log('ОШИБКА [$code]: $message${http != null ? ' (HTTP $http)' : ''}', level: LogLevel.error);
    
    final error = <String, dynamic>{
      'id': msgId,
      'status': 'error',
      'code': code,
      'message': message,
    };
    if (http != null) {
      error['http'] = http;
    }
    
    await sendToWatch(error);
  }
  
  /// Маппинг HTTP кода в error code
  String _httpToErrorCode(int status) {
    if (status == 401 || status == 403) return 'denied';
    if (status == 404) return 'not_found';
    if (status == 408 || status == 504) return 'timeout';
    if (status >= 500) return 'server';
    return 'server';
  }

  String _maskUrl(String url) {
    // Маскируем длинные query-значения (вероятно ключи)
    String masked = url;
    try {
      final uri = Uri.parse(url);
      for (final entry in uri.queryParameters.entries) {
        if (entry.value.length > 8) {
          final safe = '${entry.value.substring(0, 3)}***';
          masked = masked.replaceFirst(entry.value, safe);
        }
      }
    } catch (_) {}
    if (masked.length > 80) masked = '${masked.substring(0, 80)}...';
    return masked;
  }

  Map<String, dynamic>? _extractFields(dynamic data, List<String> fields) {
    final result = <String, dynamic>{};
    for (final field in fields) {
      final value = _extractField(data, field);
      if (value == null) return null;
      result[field] = value;
    }
    return result;
  }

  dynamic _extractField(dynamic data, String path) {
    // "main.temp" → ["main", "temp"]
    // "weather[0].description" → ["weather", "0", "description"]
    final tokens = <String>[];
    final buf = StringBuffer();
    for (int i = 0; i < path.length; i++) {
      final c = path[i];
      if (c == '.' || c == '[') {
        if (buf.isNotEmpty) { tokens.add(buf.toString()); buf.clear(); }
      } else if (c == ']') {
        if (buf.isNotEmpty) { tokens.add(buf.toString()); buf.clear(); }
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) tokens.add(buf.toString());

    dynamic current = data;
    for (final token in tokens) {
      if (current == null) return null;
      final idx = int.tryParse(token);
      if (idx != null && current is List) {
        if (idx >= current.length) return null;
        current = current[idx];
      } else if (current is Map) {
        current = current[token];
      } else {
        return null;
      }
    }
    return current;
  }

  // =====================================================
  //  SCREENSHOT
  // =====================================================

  void _handleScreenshotMessage(Map<String, dynamic> msg) {
    final status = msg['status'];
    debugPrint('[SCREENSHOT MSG] status=$status, msg=$msg');

    if (status == 'start') {
      screenshotInProgress = true;
      _screenshotWidth = msg['w'] ?? 480;
      _screenshotHeight = msg['h'] ?? 480;
      screenshotTotal = msg['chunks'] ?? 0;
      _screenshotFormat = msg['format'] ?? 'rgb565';
      _screenshotColor = msg['color'] ?? 'rgb16';
      _screenshotRawSize = msg['raw_size'] ?? 0;
      screenshotProgress = 0;
      _screenshotChunks.clear();

      String info =
          '${_screenshotWidth}x$_screenshotHeight, $screenshotTotal chunks';
      if (_screenshotFormat == 'lz4') info += ', LZ4';
      if (_screenshotColor != 'rgb16') info += ', $_screenshotColor';
      log('Screenshot: $info', level: LogLevel.incoming);
      notifyListeners();
    } else if (status == 'done') {
      final received = _screenshotChunks.length;
      debugPrint('[SCREENSHOT MSG] done: received=$received, expected=$screenshotTotal');
      log('Screenshot done: $received/$screenshotTotal',
          level: received == screenshotTotal
              ? LogLevel.success
              : LogLevel.warning);

      if (received == screenshotTotal) {
        _assembleScreenshot();
      } else {
        log('Пропущено ${screenshotTotal - received} чанков!',
            level: LogLevel.error);
      }

      screenshotInProgress = false;
      notifyListeners();
    } else if (status == 'cancelled') {
      log('Screenshot отменён', level: LogLevel.warning);
      screenshotInProgress = false;
      _screenshotChunks.clear();
      notifyListeners();
    }
  }

  void _assembleScreenshot() {
    // Собираем данные по порядку чанков
    final compressedData = <int>[];
    for (int i = 0; i < screenshotTotal; i++) {
      if (_screenshotChunks.containsKey(i)) {
        compressedData.addAll(_screenshotChunks[i]!);
      }
    }

    log('Данные: ${compressedData.length} bytes', level: LogLevel.info);

    List<int> rawData;

    // LZ4 декомпрессия
    if (_screenshotFormat == 'lz4') {
      try {
        rawData = _decompressLz4Block(Uint8List.fromList(compressedData));
        log('LZ4: ${compressedData.length} → ${rawData.length} bytes',
            level: LogLevel.success);
      } catch (e) {
        log('LZ4 ошибка: $e', level: LogLevel.error);
        rawData = compressedData;
      }
    } else {
      rawData = compressedData;
    }

    lastScreenshotData = rawData;
    log('Screenshot: ${rawData.length}b, ${_screenshotWidth}x$_screenshotHeight, $_screenshotColor',
        level: LogLevel.success);
    _screenshotChunks.clear();
  }

  /// LZ4 block decompressor (без frame header)
  List<int> _decompressLz4Block(Uint8List src) {
    final maxOut = _screenshotRawSize > 0
        ? _screenshotRawSize
        : _screenshotWidth * _screenshotHeight * 2 * 2;
    final dst = Uint8List(maxOut);
    int si = 0, di = 0;

    while (si < src.length && di < maxOut) {
      final token = src[si++];

      // Literal length
      int litLen = (token >> 4) & 0x0F;
      if (litLen == 15) {
        int s;
        do {
          if (si >= src.length) break;
          s = src[si++];
          litLen += s;
        } while (s == 255);
      }

      // Copy literals
      final litEnd = si + litLen;
      while (si < litEnd && si < src.length && di < maxOut) {
        dst[di++] = src[si++];
      }

      if (si >= src.length) break;

      // Match offset
      if (si + 1 >= src.length) break;
      final offset = src[si] | (src[si + 1] << 8);
      si += 2;
      if (offset == 0) break;

      // Match length
      int matchLen = (token & 0x0F) + 4;
      if ((token & 0x0F) == 15) {
        int s;
        do {
          if (si >= src.length) break;
          s = src[si++];
          matchLen += s;
        } while (s == 255);
      }

      // Copy match (byte-by-byte for overlap)
      int mp = di - offset;
      for (int i = 0; i < matchLen && di < maxOut; i++) {
        dst[di++] = (mp >= 0 && mp < di) ? dst[mp] : 0;
        mp++;
      }
    }

    return dst.sublist(0, di);
  }

  // =====================================================
  //  ОТПРАВКА НА ЧАСЫ
  // =====================================================

  Future<bool> sendToWatch(dynamic data) async {
    if (!isConnected || _rxChar == null) {
      log('Не подключено!', level: LogLevel.error);
      return false;
    }

    try {
      final jsonStr = json.encode(data);
      log('TX raw: $jsonStr', level: LogLevel.outgoing);
      final payload = utf8.encode(jsonStr);

      if (payload.length <= maxBleSize) {
        await _rxChar!.write(payload, withoutResponse: false);
      } else {
        // Chunked send для больших payload
        final chunks = (payload.length / maxBleSize).ceil();
        log('TX chunked: ${payload.length}b → $chunks parts',
            level: LogLevel.info);
        for (int offset = 0; offset < payload.length; offset += maxBleSize) {
          int end = offset + maxBleSize;
          if (end > payload.length) end = payload.length;
          await _rxChar!.write(
            payload.sublist(offset, end),
            withoutResponse: false,
          );
        }
      }
      return true;
    } catch (e) {
      log('TX ошибка: $e', level: LogLevel.error);
      return false;
    }
  }

  // =====================================================
  //  КОМАНДЫ → ЧАСЫ  (протокол v2: [id, subsystem, cmd, args])
  // =====================================================

  Future<Map<String, dynamic>?> sendCommand(
    String subsystem,
    String cmd,
    List<dynamic> args, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    _requestId++;
    final id = _requestId;

    final msg = [id, subsystem, cmd, args];

    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    if (!await sendToWatch(msg)) {
      _pendingRequests.remove(id);
      return {'status': 'error', 'msg': 'Failed to send'};
    }

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pendingRequests.remove(id);
      return {'status': 'error', 'msg': 'Timeout'};
    }
  }

  // --- sys ---

  Future<Map<String, dynamic>?> sysPing() async {
    final sw = Stopwatch()..start();
    final response = await sendCommand('sys', 'ping', []);
    sw.stop();
    final ok = response?['status'] == 'ok';
    final ms = sw.elapsedMilliseconds;
    log(
      ok ? 'pong! ${ms}ms' : 'Ping failed: ${response?['msg'] ?? '?'}',
      level: ok ? LogLevel.success : LogLevel.error,
    );
    return {...?response, 'ms': ms};
  }

  Future<Map<String, dynamic>?> sysInfo() async {
    final response = await sendCommand('sys', 'info', []);
    if (response?['status'] == 'ok') {
      // Выводим все поля кроме status
      for (final entry in response!.entries) {
        if (entry.key == 'status') continue;
        
        final value = entry.value;
        String formatted;
        if (value is int && (entry.key.contains('heap') || entry.key.contains('psram') || entry.key.contains('flash') || entry.key.contains('mem'))) {
          formatted = _fmtBytes(value);
        } else if (value is String) {
          formatted = value;
        } else {
          formatted = value.toString();
        }
        log('${entry.key}: $formatted', level: LogLevel.info);
      }
    } else {
      log('sys info failed: ${response?['msg'] ?? '?'}', level: LogLevel.error);
    }
    return response;
  }

  /// Синхронизация с устройством — отправляет протокол, время, timezone
  /// Получает: protocol, os, chip, time, uptime
  Future<Map<String, dynamic>?> sysSync({String? lang}) async {
    final now = DateTime.now();
    final datetime = now.toUtc().toIso8601String();  // UTC время
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final tzHours = offset.inHours.abs();
    final tz = '$sign$tzHours';
    
    final args = ['2.7', datetime, tz];
    if (lang != null) args.add(lang);
    
    final response = await sendCommand('sys', 'sync', args);
    if (response?['status'] == 'ok') {
      _deviceProtocol = response?['protocol']?.toString() ?? '';
      _deviceOs = response?['os']?.toString() ?? '';
      _deviceChip = response?['chip']?.toString() ?? '';
      _deviceUptime = response?['uptime'] is int ? response!['uptime'] : 0;
      
      // Battery
      if (response?['battery'] != null) {
        _watchBattery = response!['battery'] is int ? response['battery'] : 0;
      }
      
      // Time (epoch → HH:MM) + save for local updates
      if (response?['time'] != null) {
        final epoch = response!['time'] is int ? response['time'] : 0;
        if (epoch > 0) {
          _lastSyncEpoch = epoch;
          _lastSyncLocal = DateTime.now();
          final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
          _watchTime = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        }
      }
      
      // Update watch status with OS version
      _watchStatus = 'OS $_deviceOs';
      
      // Start timers
      _startTimeUpdateTimer();
      _startPeriodicSyncTimer();
      
      log('Sync OK: protocol=$_deviceProtocol, os=$_deviceOs', level: LogLevel.success);
      log('  chip=$_deviceChip, uptime=${_deviceUptime}s', level: LogLevel.info);
      log('  battery=$_watchBattery%, time=$_watchTime', level: LogLevel.info);
      notifyListeners();
    } else {
      log('sys sync failed: ${response?['msg'] ?? '?'}', level: LogLevel.error);
    }
    return response;
  }
  
  void _startTimeUpdateTimer() {
    _timeUpdateTimer?.cancel();
    _timeUpdateTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _updateLocalTime();
    });
  }
  
  void _updateLocalTime() {
    if (_lastSyncEpoch == 0 || _lastSyncLocal == null) return;
    
    // Calculate current epoch based on time passed since last sync
    final elapsed = DateTime.now().difference(_lastSyncLocal!);
    final currentEpoch = _lastSyncEpoch + elapsed.inSeconds;
    final dt = DateTime.fromMillisecondsSinceEpoch(currentEpoch * 1000);
    _watchTime = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    notifyListeners();
  }
  
  void _startPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(const Duration(hours: 1), (_) {
      if (isConnected) {
        sysSync();
      }
    });
  }
  
  void _stopTimers() {
    _timeUpdateTimer?.cancel();
    _timeUpdateTimer = null;
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }

  String _fmtBytes(dynamic v) {
    final n = (v is int) ? v : int.tryParse(v.toString()) ?? 0;
    if (n >= 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)}M';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(0)}K';
    return '${n}B';
  }

  // --- ui ---

  Future<bool> uiSet(String name, String value) async {
    final response = await sendCommand('ui', 'set', [name, value]);
    final ok = response?['status'] == 'ok';
    if (!ok) log('Ошибка: ${response?['msg'] ?? '?'}', level: LogLevel.error);
    return ok;
  }

  Future<String?> uiGet(String name) async {
    final response = await sendCommand('ui', 'get', [name]);
    if (response?['status'] == 'ok') {
      final value = response?['value']?.toString() ?? '?';
      log('$name = $value', level: LogLevel.incoming);
      return value;
    } else {
      log('Ошибка: ${response?['msg'] ?? '?'}', level: LogLevel.error);
      return null;
    }
  }

  Future<bool> uiNav(String pageId) async {
    final response = await sendCommand('ui', 'nav', [pageId]);
    final ok = response?['status'] == 'ok';
    log(
      ok ? '→ $pageId' : 'Ошибка: ${response?['msg'] ?? '?'}',
      level: ok ? LogLevel.success : LogLevel.error,
    );
    return ok;
  }

  Future<bool> uiCall(String funcName, [List<String>? args]) async {
    final response = await sendCommand(
        'ui', 'call', [funcName, ...?args]);
    final ok = response?['status'] == 'ok';
    log(
      ok ? '$funcName() OK' : 'Ошибка: ${response?['msg'] ?? '?'}',
      level: ok ? LogLevel.success : LogLevel.error,
    );
    return ok;
  }

  // --- backward compat aliases ---

  Future<bool> setState(String name, String value) => uiSet(name, value);
  Future<String?> getState(String name) => uiGet(name);
  Future<bool> navigate(String pageId) => uiNav(pageId);
  Future<bool> callFunction(String funcName, [List<String>? args]) =>
      uiCall(funcName, args);

  // setText → uiSet (биндинг через state)
  Future<bool> setText(String widget, String value) => uiSet(widget, value);

  // sendNotification → uiCall
  Future<bool> sendNotification(String title, String message) async {
    final response = await sendCommand(
        'ui', 'call', ['showNotification', title, message]);
    final ok = response?['status'] == 'ok';
    log(
      ok ? 'Notify: $title' : 'Ошибка: ${response?['msg'] ?? '?'}',
      level: ok ? LogLevel.success : LogLevel.error,
    );
    return ok;
  }

  Future<void> requestScreenshot(
      {int scale = 0, String color = 'rgb16'}) async {
    log('Запрос скриншота (scale=$scale, color=$color)...',
        level: LogLevel.outgoing);
    
    // Reset state
    lastScreenshotData = null;
    screenshotInProgress = true;
    screenshotProgress = 0;
    screenshotTotal = 0;
    _screenshotChunks.clear();
    _expectedBytes = null;
    _receivedBytes = 0;
    _resetTransferTimeout();
    notifyListeners();

    final response = await sendCommand(
      'sys', 'screen', [color, scale.toString()],
    );
    
    if (response?['status'] != 'ok') {
      log('Ошибка: ${response?['msg'] ?? '?'}', level: LogLevel.error);
      _cancelTransferTimeout();
      screenshotInProgress = false;
      notifyListeners();
      return;
    }
    
    // v2.2: параметры из JSON ответа
    _screenshotWidth = response?['w'] ?? 480;
    _screenshotHeight = response?['h'] ?? 480;
    _screenshotFormat = response?['format'] ?? 'raw';
    _screenshotColor = response?['color'] ?? color;
    _screenshotRawSize = response?['raw_size'] ?? 0;
    
    final bytes = response?['bytes'] as int?;
    if (bytes != null && bytes > 0) {
      _expectedBytes = bytes;
      screenshotTotal = (bytes / 250).ceil();
      debugPrint('[SCREENSHOT] Expected $bytes bytes');
    }
    
    String info = '${_screenshotWidth}x$_screenshotHeight';
    if (_screenshotFormat == 'lz4') info += ', LZ4 ${bytes}b';
    if (_screenshotColor != 'rgb16') info += ', $_screenshotColor';
    log('Screenshot: $info', level: LogLevel.incoming);
    notifyListeners();
  }

  // =====================================================
  //  APP — управление приложениями
  // =====================================================

  Future<List<String>> listApps() async {
    // Начинаем слушать binary ДО отправки — часы шлют сразу после JSON
    final binFuture = _prepareBinaryTransfer(
        timeout: const Duration(seconds: 10));

    final response = await sendCommand('app', 'list', [],
        timeout: const Duration(seconds: 5));
    
    debugPrint('[listApps] response: $response');
    
    if (response?['status'] != 'ok') {
      _cancelBinaryTransfer();
      log('Ошибка: ${response?['msg'] ?? '?'}', level: LogLevel.error);
      return [];
    }

    final count = response?['count'] ?? 0;
    final bytes = response?['bytes'] as int?;
    
    debugPrint('[listApps] count=$count, bytes=$bytes');
    
    if (count == 0) {
      _cancelBinaryTransfer();
      log('Приложений: 0', level: LogLevel.success);
      _apps = [];
      _appsLoading = false;
      notifyListeners();
      return [];
    }

    // v2.2: устанавливаем ожидаемый размер
    if (bytes != null && bytes > 0) {
      _setExpectedBytes(bytes);
    } else {
      debugPrint('[listApps] WARNING: no bytes in response, waiting for end marker');
    }

    // Ждём binary data: "weather\0calculator\0timer\0"
    final data = await binFuture;
    debugPrint('[listApps] received ${data.length} bytes');
    
    if (data.isEmpty) {
      log('Transfer пустой', level: LogLevel.error);
      return [];
    }

    // Парсим null-separated имена из binary
    final items = <String>[];
    int start = 0;
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 0) {
        if (i > start) {
          items.add(utf8.decode(data.sublist(start, i)));
        }
        start = i + 1;
      }
    }
    if (start < data.length) {
      items.add(utf8.decode(data.sublist(start)));
    }
    log('Приложений: ${items.length}', level: LogLevel.success);
    
    // Кэшируем результат
    _apps = items;
    _appsLoading = false;
    notifyListeners();
    
    return items;
  }

  /// Фоновая загрузка приложений при подключении
  Future<void> _loadAppsInBackground() async {
    _appsLoading = true;
    notifyListeners();
    await listApps();
  }

  /// Принудительное обновление списка apps
  Future<void> refreshApps() async {
    _appsLoading = true;
    notifyListeners();
    await listApps();
  }

  /// app info: {title, size, files}
  Future<Map<String, dynamic>?> appInfo(String appName) async {
    final response = await sendCommand('app', 'info', [appName],
        timeout: const Duration(seconds: 5));
    if (response?['status'] == 'ok') {
      final files = response?['files'];
      final fileCount = files is Map ? files.length : (files is List ? files.length : 0);
      log('$appName: ${response?['title']} (${response?['size']}b, $fileCount files)',
          level: LogLevel.success);
      return response;
    } else {
      log('Ошибка: ${response?['msg'] ?? '?'}', level: LogLevel.error);
      return null;
    }
  }

  /// Pull файл через BIN_CHAR.
  /// Возвращает содержимое файла как строку или null при ошибке.
  Future<String?> pullFile(String appName,
      {String file = 'app.html'}) async {
    // Готовим приёмник ДО команды
    final binFuture = _prepareBinaryTransfer(
        timeout: const Duration(seconds: 15));

    final response = await sendCommand(
      'app', 'pull', [appName, file],
      timeout: const Duration(seconds: 5),
    );
    if (response?['status'] != 'ok') {
      _cancelBinaryTransfer();
      log('Ошибка: ${response?['msg'] ?? '?'}', level: LogLevel.error);
      return null;
    }

    final size = response?['size'] ?? 0;
    final bytes = response?['bytes'] as int? ?? size;
    log('Pull $appName/$file ($bytes b)...', level: LogLevel.info);

    // v2.2: устанавливаем ожидаемый размер
    if (bytes > 0) {
      _setExpectedBytes(bytes);
    }

    // Ждём binary data
    final data = await binFuture;
    if (data.isEmpty) {
      log('Transfer пустой', level: LogLevel.error);
      return null;
    }

    final content = utf8.decode(data, allowMalformed: true);
    log('Pull OK: ${content.length} chars', level: LogLevel.success);
    return content;
  }

  /// Push файл через BIN_CHAR.
  /// Протокол:
  /// 1. [id, "app", "push", [name, size, filename]]
  /// 2. ← [id, "ok", {"ready": true}]
  /// 3. → чанки через BIN_CHAR write
  /// 4. → [0xFF, 0xFF] end marker
  Future<bool> pushFile(String appName, String fileName, String content) async {
    if (_binChar == null) {
      log('BIN_CHAR не доступен', level: LogLevel.error);
      return false;
    }

    final contentBytes = utf8.encode(content);
    final size = contentBytes.length;

    log('Push $appName/$fileName ($size bytes)...', level: LogLevel.info);

    // 1. Отправляем команду с размером (порядок: name, filename, size)
    final response = await sendCommand(
      'app', 'push', [appName, fileName, size.toString()],
      timeout: const Duration(seconds: 5),
    );

    if (response?['status'] != 'ok') {
      log('Ошибка: ${response?['msg'] ?? 'no response'}', level: LogLevel.error);
      return false;
    }

    // 2. Небольшая пауза для готовности устройства
    await Future.delayed(const Duration(milliseconds: 100));

    // 3. Отправляем чанками через BIN_CHAR
    const chunkDataSize = 180; // MTU - 2 bytes for chunk_id
    int chunkId = 0;
    int offset = 0;

    try {
      while (offset < contentBytes.length) {
        final end = (offset + chunkDataSize > contentBytes.length)
            ? contentBytes.length
            : offset + chunkDataSize;
        final chunkData = contentBytes.sublist(offset, end);

        // Формируем пакет: [chunk_id_low, chunk_id_high, data...]
        final packet = Uint8List(2 + chunkData.length);
        packet[0] = chunkId & 0xFF;
        packet[1] = (chunkId >> 8) & 0xFF;
        packet.setRange(2, 2 + chunkData.length, chunkData);

        await _binChar!.write(packet.toList(), withoutResponse: true);

        if (chunkId % 10 == 0) {
          log('TX chunk #$chunkId (${chunkData.length}b)', level: LogLevel.info);
        }

        chunkId++;
        offset = end;

        // Небольшая пауза между чанками чтобы не переполнить буфер
        if (chunkId % 5 == 0) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      // 4. End marker
      final endMarker = Uint8List.fromList([0xFF, 0xFF]);
      await _binChar!.write(endMarker.toList(), withoutResponse: true);

      log('Push OK: $chunkId chunks', level: LogLevel.success);
      return true;

    } catch (e) {
      log('Push error: $e', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> deleteApp(String appName) async {
    final response = await sendCommand('app', 'rm', [appName]);
    final ok = response?['status'] == 'ok';
    log(
      ok ? '$appName удален' : 'Ошибка: ${response?['msg'] ?? '?'}',
      level: ok ? LogLevel.success : LogLevel.error,
    );
    return ok;
  }

  Future<bool> runApp(String appName) async {
    final response = await sendCommand('app', 'run', [appName]);
    final ok = response?['status'] == 'ok';
    log(
      ok ? 'Запущено: $appName' : 'Ошибка: ${response?['msg'] ?? '?'}',
      level: ok ? LogLevel.success : LogLevel.error,
    );
    return ok;
  }

  // =====================================================
  //  CLEANUP
  // =====================================================

  @override
  void dispose() {
    _txSubscription?.cancel();
    _binSubscription?.cancel();
    _connectionSubscription?.cancel();
    _reconnectTimer?.cancel();
    _fetchErrorController.close();
    _device?.disconnect();
    super.dispose();
  }
}

class _ServiceResult {
  final String url;
  final Map<String, String> headers;
  final String? body;
  final String? error;

  _ServiceResult({
    required this.url,
    required this.headers,
    this.body,
    this.error,
  });
}
