import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Foreground Service для работы BLE в фоне
class BleBackgroundService {
  static bool _isInitialized = false;
  
  /// Инициализация (вызывать один раз при старте приложения)
  static Future<void> init() async {
    if (_isInitialized) return;
    
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'telaphone_foreground',
        channelName: 'TelaPhone Background Service',
        channelDescription: 'Поддерживает связь с часами в фоне',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    
    _isInitialized = true;
  }
  
  /// Запуск foreground сервиса
  static Future<bool> start({
    String? deviceName,
    int? battery,
    int? requests,
  }) async {
    if (!_isInitialized) await init();
    
    // Проверяем разрешения
    final notificationPermission = await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    
    // Формируем текст уведомления
    final title = deviceName != null 
        ? '🔗 $deviceName' 
        : 'TelaPhone';
    final body = _buildNotificationBody(battery, requests);
    
    final result = await FlutterForegroundTask.startService(
      notificationTitle: title,
      notificationText: body,
      callback: _startCallback,
    );
    return result is ServiceRequestSuccess;
  }
  
  /// Остановка foreground сервиса
  static Future<bool> stop() async {
    final result = await FlutterForegroundTask.stopService();
    return result is ServiceRequestSuccess;
  }
  
  /// Обновление уведомления
  static Future<void> updateNotification({
    String? deviceName,
    int? battery,
    int? requests,
    bool? isConnected,
  }) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    
    String title;
    String body;
    
    if (isConnected == false) {
      title = 'TelaPhone';
      body = 'Ожидание подключения...';
    } else {
      title = deviceName != null 
          ? '🔗 $deviceName' 
          : 'TelaPhone';
      body = _buildNotificationBody(battery, requests);
    }
    
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: body,
    );
  }
  
  static String _buildNotificationBody(int? battery, int? requests) {
    final parts = <String>[];
    if (battery != null) parts.add('Батарея: $battery%');
    if (requests != null) parts.add('Запросов: $requests');
    return parts.isEmpty ? 'Подключено' : parts.join(' | ');
  }
  
  /// Проверка: запущен ли сервис
  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;
  
  /// Запрос отключения оптимизации батареи
  static Future<bool> requestBatteryOptimizationOff() async {
    final isIgnoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!isIgnoring) {
      return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    return true;
  }
  
  /// Проверка: отключена ли оптимизация батареи
  static Future<bool> get isBatteryOptimizationOff => 
      FlutterForegroundTask.isIgnoringBatteryOptimizations;
}

/// Callback для foreground task (запускается в отдельном isolate)
@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_BleTaskHandler());
}

/// Handler для фоновых задач
class _BleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[ForegroundService] Started at $timestamp');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Не используем repeat events - BLE работает через notify
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[ForegroundService] Destroyed at $timestamp');
  }

  @override
  void onNotificationButtonPressed(String id) {
    debugPrint('[ForegroundService] Button pressed: $id');
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {
    // Уведомление нельзя смахнуть - это foreground service
  }
}
