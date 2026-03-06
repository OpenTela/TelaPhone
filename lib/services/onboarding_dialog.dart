import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'foreground_service.dart';

/// Диалог первого запуска
class OnboardingDialog {
  static const _keyOnboardingShown = 'onboarding_shown';
  
  /// Показать диалог если ещё не показывался
  static Future<void> showIfNeeded(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool(_keyOnboardingShown) ?? false;
    
    if (!shown && context.mounted) {
      await _showDialog(context);
      await prefs.setBool(_keyOnboardingShown, true);
    }
  }
  
  /// Сбросить флаг (для тестирования)
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyOnboardingShown);
  }
  
  static Future<void> _showDialog(BuildContext context) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _OnboardingDialogContent(),
    );
  }
}

class _OnboardingDialogContent extends StatefulWidget {
  const _OnboardingDialogContent();

  @override
  State<_OnboardingDialogContent> createState() => _OnboardingDialogContentState();
}

class _OnboardingDialogContentState extends State<_OnboardingDialogContent> {
  int _step = 0;
  bool _batteryOptimizationOff = false;
  
  @override
  void initState() {
    super.initState();
    _checkBatteryOptimization();
  }
  
  Future<void> _checkBatteryOptimization() async {
    final isOff = await BleBackgroundService.isBatteryOptimizationOff;
    if (mounted) {
      setState(() => _batteryOptimizationOff = isOff);
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Заголовок
            const Icon(
              Icons.watch,
              size: 56,
              color: Color(0xFF6366F1),
            ),
            const SizedBox(height: 16),
            Text(
              'Добро пожаловать в TelaPhone',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            
            // Контент по шагам
            if (_step == 0) _buildStep0(),
            if (_step == 1) _buildStep1(),
            if (_step == 2) _buildStep2(),
            
            const SizedBox(height: 24),
            
            // Кнопки
            _buildButtons(),
          ],
        ),
      ),
    );
  }
  
  Widget _buildStep0() {
    return Column(
      children: [
        _buildFeatureItem(
          Icons.bluetooth,
          'Мост между часами и интернетом',
          'Часы отправляют HTTP запросы через телефон',
        ),
        const SizedBox(height: 12),
        _buildFeatureItem(
          Icons.notifications_active,
          'Работает в фоне',
          'Приложение остаётся активным даже когда свёрнуто',
        ),
        const SizedBox(height: 12),
        _buildFeatureItem(
          Icons.battery_saver,
          'Экономия батареи',
          'Просыпается только при запросах от часов',
        ),
      ],
    );
  }
  
  Widget _buildStep1() {
    return Column(
      children: [
        const Icon(
          Icons.notifications,
          size: 48,
          color: Color(0xFF22D3EE),
        ),
        const SizedBox(height: 16),
        const Text(
          'Для работы в фоне нужно разрешение на уведомления',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 8),
        Text(
          'Уведомление показывает статус подключения и не мешает',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13),
        ),
      ],
    );
  }
  
  Widget _buildStep2() {
    return Column(
      children: [
        Icon(
          _batteryOptimizationOff ? Icons.check_circle : Icons.battery_alert,
          size: 48,
          color: _batteryOptimizationOff ? Colors.green : const Color(0xFFF59E0B),
        ),
        const SizedBox(height: 16),
        Text(
          _batteryOptimizationOff 
              ? 'Оптимизация батареи отключена ✓'
              : 'Рекомендуем отключить оптимизацию батареи',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 8),
        Text(
          _batteryOptimizationOff
              ? 'Приложение будет стабильно работать в фоне'
              : 'Иначе Android может закрыть приложение для экономии батареи',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13),
        ),
        if (!_batteryOptimizationOff) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _requestBatteryOptimization,
            icon: const Icon(Icons.settings),
            label: const Text('Открыть настройки'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFF59E0B),
              side: const BorderSide(color: Color(0xFFF59E0B)),
            ),
          ),
        ],
      ],
    );
  }
  
  Widget _buildFeatureItem(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFF6366F1).withOpacity(0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: const Color(0xFF6366F1), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                subtitle,
                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  Widget _buildButtons() {
    if (_step == 0) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => setState(() => _step = 1),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6366F1),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Продолжить'),
        ),
      );
    }
    
    if (_step == 1) {
      return Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: () => setState(() => _step = 2),
              child: const Text('Пропустить'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: _requestNotifications,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Разрешить'),
            ),
          ),
        ],
      );
    }
    
    // Step 2
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: () => Navigator.of(context).pop(),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF6366F1),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: const Text('Начать'),
      ),
    );
  }
  
  Future<void> _requestNotifications() async {
    // Запрос разрешения через foreground service
    await BleBackgroundService.start();
    await BleBackgroundService.stop();
    
    if (mounted) {
      setState(() => _step = 2);
    }
  }
  
  Future<void> _requestBatteryOptimization() async {
    await BleBackgroundService.requestBatteryOptimizationOff();
    await _checkBatteryOptimization();
  }
}
