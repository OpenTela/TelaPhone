import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ble_service.dart';
import '../services/local_server.dart';
import '../services/foreground_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Map<String, String>> _devices = [];
  bool _scanning = false;

  bool _autoConnect = true;
  bool _autoRunOnBoot = false;
  bool _batteryOptimizationOff = false;
  bool _remoteDebug = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final batteryOff = await BleBackgroundService.isBatteryOptimizationOff;
    if (!mounted) return;
    setState(() {
      _remoteDebug = prefs.getBool('remote_debug') ?? false;
      _autoRunOnBoot = prefs.getBool('auto_run_on_boot') ?? false;
      _batteryOptimizationOff = batteryOff;
    });
  }

  Future<void> _saveAutoRunOnBoot(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_run_on_boot', value);
    setState(() => _autoRunOnBoot = value);
  }

  Future<void> _saveRemoteDebug(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('remote_debug', value);
  }

  Future<void> _toggleRemoteDebug(bool enable) async {
    if (enable) {
      // Показываем предупреждение
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Row(
            children: [
              Icon(Icons.wifi_tethering, color: Color(0xFFFBBF24), size: 24),
              SizedBox(width: 12),
              Text('Удалённый доступ', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: const Text(
            'Устройства в вашей WiFi сети смогут:\n\n'
            '• Просматривать эмулятор\n'
            '• Загружать приложения\n\n'
            'Включайте только в доверенных сетях.',
            style: TextStyle(color: Colors.white70, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFBBF24),
                foregroundColor: Colors.black,
              ),
              child: const Text('Включить'),
            ),
          ],
        ),
      );
      
      if (confirmed != true) return;
    }
    
    setState(() => _remoteDebug = enable);
    await _saveRemoteDebug(enable);
    
    // Перезапускаем сервер с новыми настройками
    final server = LocalServer();
    if (server.isRunning) {
      await server.stop();
      await server.start(localOnly: !enable);
    }
  }

  Future<void> _scan() async {
    final ble = context.read<BleService>();
    setState(() => _scanning = true);
    final devices = await ble.scanDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _scanning = false;
    });
  }

  // === Добавление сервиса ===
  void _showAddServiceDialog(BuildContext context) {
    final domainCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Добавить сервис'),
        content: TextField(
          controller: domainCtrl,
          style: const TextStyle(color: Colors.white),
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Домен',
            hintText: 'api.example.com',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
            labelStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final domain = domainCtrl.text.trim();
              if (domain.isNotEmpty) {
                context.read<BleService>().setServiceConfig(domain, {
                  'query': {},
                });
                Navigator.pop(ctx);
              }
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
  }

  // === Редактирование сервиса (полноэкранный JSON) ===
  void _showEditServiceDialog(
      BuildContext context, String domain, Map<String, dynamic> config) {
    final encoder = const JsonEncoder.withIndent('  ');
    final ctrl = TextEditingController(text: encoder.convert(config));
    String? error;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0A0A0F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
              left: 20,
              right: 20,
              top: 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Заголовок
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(domain,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text('JSON конфигурация',
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.3),
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        context.read<BleService>().removeServiceConfig(domain);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.red, size: 22),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // JSON редактор
                Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.45,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: error != null
                          ? Colors.red.withOpacity(0.5)
                          : Colors.white.withOpacity(0.05),
                    ),
                  ),
                  child: TextField(
                    controller: ctrl,
                    maxLines: null,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.5,
                    ),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.all(16),
                      border: InputBorder.none,
                      hintText: '{\n  "query": {\n    "key": "value"\n  }\n}',
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.15),
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                    onChanged: (_) {
                      if (error != null) {
                        setSheetState(() => error = null);
                      }
                    },
                  ),
                ),

                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!,
                      style:
                          const TextStyle(color: Colors.red, fontSize: 12)),
                ],

                const SizedBox(height: 16),

                // Кнопки
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Отмена'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          try {
                            final parsed = json.decode(ctrl.text.trim());
                            if (parsed is! Map) {
                              setSheetState(
                                  () => error = 'Должен быть JSON объект {}');
                              return;
                            }
                            context.read<BleService>().setServiceConfig(
                                domain,
                                Map<String, dynamic>.from(parsed));
                            Navigator.pop(ctx);
                          } on FormatException catch (e) {
                            setSheetState(
                                () => error = 'JSON ошибка: ${e.message}');
                          }
                        },
                        child: const Text('Сохранить'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BleService>(
      builder: (context, ble, _) {
        final services = ble.servicesConfig;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Настройки'),
            backgroundColor: Colors.transparent,
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // === Устройство ===
              _SectionHeader(
                title: 'УСТРОЙСТВО',
                trailing: TextButton.icon(
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search, size: 18),
                  label: Text(_scanning ? 'Поиск...' : 'Сканировать'),
                ),
              ),
              const SizedBox(height: 8),

              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Column(
                  children: [
                    // Подключённое устройство
                    if (ble.isConnected)
                      ListTile(
                        leading: const Icon(
                          Icons.bluetooth_connected,
                          color: Color(0xFF22C55E),
                        ),
                        title: Text(
                          ble.deviceName ?? 'FutureClock',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          ble.deviceAddress ?? '',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.3),
                            fontSize: 12,
                          ),
                        ),
                        trailing: IconButton(
                          onPressed: () {
                            ble.disconnect();
                            setState(() => _devices = []);
                          },
                          icon: const Icon(Icons.close, size: 20),
                          color: const Color(0xFFEF4444),
                          tooltip: 'Отключиться',
                        ),
                      )
                    // Подключение в процессе
                    else if (ble.connectionState == BleConnectionState.connecting)
                      ListTile(
                        leading: const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Color(0xFFFBBF24)),
                        ),
                        title: Text(
                          ble.deviceName ?? 'Подключение...',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: Text(
                          ble.deviceAddress ?? '',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.3),
                            fontSize: 12,
                          ),
                        ),
                        trailing: IconButton(
                          onPressed: () {
                            ble.disconnect();
                            setState(() => _devices = []);
                          },
                          icon: const Icon(Icons.close, size: 20),
                          color: Colors.white38,
                          tooltip: 'Отменить',
                        ),
                      )
                    // Не подключено — список или плейсхолдер
                    else if (_devices.isEmpty && !_scanning)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(Icons.bluetooth_searching,
                                size: 32,
                                color: Colors.white.withOpacity(0.1)),
                            const SizedBox(height: 12),
                            Text('Нажмите "Сканировать"',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.3))),
                            const SizedBox(height: 4),
                            Text('Покажем только устройства FutureClock',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.15),
                                    fontSize: 11)),
                          ],
                        ),
                      )
                    else
                      ...ListTile.divideTiles(
                        context: context,
                        color: Colors.white.withOpacity(0.05),
                        tiles: _devices.map((device) {
                          return ListTile(
                            leading: const Icon(
                              Icons.bluetooth,
                              color: Colors.white38,
                            ),
                            title: Text(
                              device['name'] ?? 'Unknown',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            subtitle: Text(
                              '${device['address'] ?? ''} (${device['rssi']}dBm)',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.3),
                                fontSize: 12,
                              ),
                            ),
                            trailing: FilledButton(
                              onPressed: () => ble.connect(
                                device['address']!,
                                name: device['name'],
                              ),
                              child: const Text('Подкл.'),
                            ),
                          );
                        }),
                      ).toList(),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // === ИИ Провайдеры ===
              const _SectionHeader(title: 'ИИ'),
              const SizedBox(height: 4),
              Text(
                'Выберите провайдера для ИИ-конструктора приложений',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.2), fontSize: 11),
              ),
              const SizedBox(height: 8),

              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: _AiProvidersSection(
                  providers: ble.aiProviders,
                  loadOpenaiModels: () => ble.getOpenaiModels(),
                  loadAnthropicModels: () => ble.getAnthropicModels(),
                  onSelect: (provider) {
                    // Выключаем все, включаем выбранный
                    ble.setAiProvider('openai', enabled: provider == 'openai');
                    ble.setAiProvider('anthropic', enabled: provider == 'anthropic');
                  },
                  onApiKeyChanged: (provider, key) {
                    ble.clearModelsCache(provider);
                    ble.setAiProvider(provider, apiKey: key);
                  },
                  onModelChanged: (provider, model) {
                    ble.setAiProvider(provider, model: model);
                  },
                ),
              ),
              
              // Прокси для AI
              const SizedBox(height: 12),
              _ProxyField(
                proxy: ble.aiProxy,
                onChanged: (proxy) => ble.setAiProxy(proxy),
              ),

              const SizedBox(height: 24),

              // === Сервисы ===
              _SectionHeader(
                title: 'СЕРВИСЫ',
                trailing: TextButton.icon(
                  onPressed: () => _showAddServiceDialog(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Добавить'),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Конфиг для authorize=true. Часы шлют домен — приложение подставляет параметры.',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.2), fontSize: 11),
              ),
              const SizedBox(height: 8),

              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: services.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(Icons.cloud_off,
                                size: 32,
                                color: Colors.white.withOpacity(0.1)),
                            const SizedBox(height: 12),
                            Text('Нет сервисов',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.3))),
                          ],
                        ),
                      )
                    : Column(
                        children: ListTile.divideTiles(
                          context: context,
                          color: Colors.white.withOpacity(0.05),
                          tiles: services.entries.map((entry) {
                            final domain = entry.key;
                            final config = entry.value;
                            final paramCount = _countParams(config);
                            final hasSecrets = _hasLongValues(config);

                            return ListTile(
                              leading: Icon(
                                Icons.cloud_outlined,
                                color: hasSecrets
                                    ? const Color(0xFF22C55E)
                                    : const Color(0xFFF59E0B),
                                size: 22,
                              ),
                              title: Text(
                                domain,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                hasSecrets
                                    ? '$paramCount параметров ✓'
                                    : '$paramCount параметров · нет ключей',
                                style: TextStyle(
                                  color: hasSecrets
                                      ? const Color(0xFF22C55E).withOpacity(0.6)
                                      : const Color(0xFFF59E0B).withOpacity(0.6),
                                  fontSize: 11,
                                ),
                              ),
                              trailing: const Icon(Icons.edit_outlined,
                                  color: Colors.white24, size: 18),
                              onTap: () => _showEditServiceDialog(
                                  context, domain, config),
                            );
                          }),
                        ).toList(),
                      ),
              ),

              const SizedBox(height: 24),

              // === Поведение ===
              const _SectionHeader(title: 'ПОВЕДЕНИЕ'),
              const SizedBox(height: 8),

              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('Автоподключение',
                          style: TextStyle(color: Colors.white70)),
                      subtitle: Text('Подключаться при запуске',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.3),
                              fontSize: 12)),
                      value: _autoConnect,
                      onChanged: (v) => setState(() => _autoConnect = v),
                    ),
                    Divider(height: 1, color: Colors.white.withOpacity(0.05)),
                    SwitchListTile(
                      title: const Text('Запуск при загрузке',
                          style: TextStyle(color: Colors.white70)),
                      subtitle: Text('Запускать при включении телефона',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.3),
                              fontSize: 12)),
                      value: _autoRunOnBoot,
                      onChanged: (v) => _saveAutoRunOnBoot(v),
                    ),
                    Divider(height: 1, color: Colors.white.withOpacity(0.05)),
                    ListTile(
                      title: const Text('Оптимизация батареи',
                          style: TextStyle(color: Colors.white70)),
                      subtitle: Text(
                          _batteryOptimizationOff
                              ? 'Отключена — приложение работает стабильно'
                              : 'Включена — Android может закрыть приложение',
                          style: TextStyle(
                              color: _batteryOptimizationOff
                                  ? const Color(0xFF22C55E).withOpacity(0.8)
                                  : const Color(0xFFF59E0B).withOpacity(0.8),
                              fontSize: 12)),
                      trailing: _batteryOptimizationOff
                          ? const Icon(Icons.check_circle, color: Color(0xFF22C55E))
                          : TextButton(
                              onPressed: () async {
                                await BleBackgroundService.requestBatteryOptimizationOff();
                                final isOff = await BleBackgroundService.isBatteryOptimizationOff;
                                if (mounted) setState(() => _batteryOptimizationOff = isOff);
                              },
                              child: const Text('Отключить'),
                            ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // === Отладка ===
              const _SectionHeader(title: 'ОТЛАДКА'),
              const SizedBox(height: 8),

              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('Удалённый доступ',
                          style: TextStyle(color: Colors.white70)),
                      subtitle: Text(
                          _remoteDebug 
                            ? 'Доступ с других устройств в WiFi сети'
                            : 'Только локально на этом устройстве',
                          style: TextStyle(
                              color: _remoteDebug 
                                ? const Color(0xFFFBBF24).withOpacity(0.8)
                                : Colors.white.withOpacity(0.3),
                              fontSize: 12)),
                      value: _remoteDebug,
                      onChanged: (v) => _toggleRemoteDebug(v),
                      activeColor: const Color(0xFFFBBF24),
                    ),
                    if (_remoteDebug) ...[
                      Divider(height: 1, color: Colors.white.withOpacity(0.05)),
                      FutureBuilder<List<String>>(
                        future: LocalServer().getServerUrls(),
                        builder: (context, snapshot) {
                          final urls = snapshot.data ?? [];
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Доступные адреса:',
                                    style: TextStyle(
                                        color: Colors.white.withOpacity(0.4),
                                        fontSize: 11)),
                                const SizedBox(height: 8),
                                ...urls.map((url) => Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: SelectableText(
                                    url,
                                    style: const TextStyle(
                                      color: Color(0xFF22C55E),
                                      fontFamily: 'monospace',
                                      fontSize: 13,
                                    ),
                                  ),
                                )),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // === О приложении ===
              const _SectionHeader(title: 'О ПРИЛОЖЕНИИ'),
              const SizedBox(height: 8),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [
                              Theme.of(context).colorScheme.primary,
                              Theme.of(context).colorScheme.secondary,
                            ]),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.watch, color: Colors.white),
                        ),
                        const SizedBox(width: 16),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('TelaPhone',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600)),
                            Text('Версия 1.0.0',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.3),
                                    fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Двусторонний мост между FutureClock и интернетом через BLE.',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.4), fontSize: 12),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 80),
            ],
          ),
        );
      },
    );
  }

  /// Считает общее количество параметров в конфиге
  int _countParams(Map<String, dynamic> config) {
    int count = 0;
    for (final section in config.values) {
      if (section is Map) count += section.length;
    }
    return count;
  }

  /// Есть ли значения длиннее 8 символов (вероятно ключи)
  bool _hasLongValues(Map<String, dynamic> config) {
    for (final section in config.values) {
      if (section is Map) {
        for (final v in section.values) {
          if (v is String && v.length > 8) return true;
        }
      }
    }
    return false;
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white38,
                letterSpacing: 1.2,
              ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

// === Секция выбора AI провайдера ===

class _AiProvidersSection extends StatefulWidget {
  final Map<String, Map<String, dynamic>> providers;
  final Future<List<String>> Function() loadOpenaiModels;
  final Future<List<String>> Function() loadAnthropicModels;
  final void Function(String? provider) onSelect;
  final void Function(String provider, String key) onApiKeyChanged;
  final void Function(String provider, String model) onModelChanged;

  const _AiProvidersSection({
    required this.providers,
    required this.loadOpenaiModels,
    required this.loadAnthropicModels,
    required this.onSelect,
    required this.onApiKeyChanged,
    required this.onModelChanged,
  });

  @override
  State<_AiProvidersSection> createState() => _AiProvidersSectionState();
}

class _AiProvidersSectionState extends State<_AiProvidersSection> {
  String? _expandedProvider;
  
  // Модели
  List<String>? _openaiModels;
  List<String>? _anthropicModels;
  bool _loadingOpenai = false;
  bool _loadingAnthropic = false;
  
  // Контроллеры
  final _openaiKeyController = TextEditingController();
  final _anthropicKeyController = TextEditingController();
  bool _obscureOpenai = true;
  bool _obscureAnthropic = true;

  @override
  void initState() {
    super.initState();
    _openaiKeyController.text = widget.providers['openai']?['apiKey'] ?? '';
    _anthropicKeyController.text = widget.providers['anthropic']?['apiKey'] ?? '';
  }

  @override
  void didUpdateWidget(_AiProvidersSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providers['openai']?['apiKey'] != widget.providers['openai']?['apiKey']) {
      _openaiKeyController.text = widget.providers['openai']?['apiKey'] ?? '';
    }
    if (oldWidget.providers['anthropic']?['apiKey'] != widget.providers['anthropic']?['apiKey']) {
      _anthropicKeyController.text = widget.providers['anthropic']?['apiKey'] ?? '';
    }
  }

  @override
  void dispose() {
    _openaiKeyController.dispose();
    _anthropicKeyController.dispose();
    super.dispose();
  }

  String? get _activeProvider {
    if (widget.providers['openai']?['enabled'] == true) return 'openai';
    if (widget.providers['anthropic']?['enabled'] == true) return 'anthropic';
    return null;
  }

  Future<void> _loadModels(String provider) async {
    if (provider == 'openai') {
      if (_openaiModels != null || _loadingOpenai) return;
      setState(() => _loadingOpenai = true);
      try {
        final models = await widget.loadOpenaiModels();
        if (mounted) setState(() { _openaiModels = models; _loadingOpenai = false; });
      } catch (_) {
        if (mounted) setState(() => _loadingOpenai = false);
      }
    } else {
      if (_anthropicModels != null || _loadingAnthropic) return;
      setState(() => _loadingAnthropic = true);
      try {
        final models = await widget.loadAnthropicModels();
        if (mounted) setState(() { _anthropicModels = models; _loadingAnthropic = false; });
      } catch (_) {
        if (mounted) setState(() => _loadingAnthropic = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildProviderTile(
          provider: 'openai',
          name: 'OpenAI',
          icon: '🤖',
          config: widget.providers['openai']!,
          keyController: _openaiKeyController,
          obscure: _obscureOpenai,
          onToggleObscure: () => setState(() => _obscureOpenai = !_obscureOpenai),
          models: _openaiModels,
          loading: _loadingOpenai,
        ),
        Divider(height: 1, color: Colors.white.withOpacity(0.05)),
        _buildProviderTile(
          provider: 'anthropic',
          name: 'Anthropic',
          icon: '🧠',
          config: widget.providers['anthropic']!,
          keyController: _anthropicKeyController,
          obscure: _obscureAnthropic,
          onToggleObscure: () => setState(() => _obscureAnthropic = !_obscureAnthropic),
          models: _anthropicModels,
          loading: _loadingAnthropic,
        ),
      ],
    );
  }

  Widget _buildProviderTile({
    required String provider,
    required String name,
    required String icon,
    required Map<String, dynamic> config,
    required TextEditingController keyController,
    required bool obscure,
    required VoidCallback onToggleObscure,
    required List<String>? models,
    required bool loading,
  }) {
    final isActive = _activeProvider == provider;
    final hasKey = (config['apiKey'] as String?)?.isNotEmpty == true;
    final currentModel = config['model'] as String? ?? '';
    final isExpanded = _expandedProvider == provider;

    return Column(
      children: [
        ListTile(
          leading: Text(icon, style: const TextStyle(fontSize: 24)),
          title: Text(
            name,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.white54,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            isActive
                ? (hasKey ? currentModel : 'Нужен API ключ')
                : 'Не активен',
            style: TextStyle(
              color: isActive
                  ? (hasKey ? const Color(0xFF22C55E) : const Color(0xFFF59E0B))
                  : Colors.white24,
              fontSize: 12,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Radio<String>(
                value: provider,
                groupValue: _activeProvider,
                onChanged: (v) => widget.onSelect(v),
                activeColor: const Color(0xFF22C55E),
              ),
              Icon(
                isExpanded ? Icons.expand_less : Icons.expand_more,
                color: Colors.white24,
                size: 20,
              ),
            ],
          ),
          onTap: () {
            setState(() {
              _expandedProvider = isExpanded ? null : provider;
            });
            if (!isExpanded) _loadModels(provider);
          },
        ),
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // API Key
                TextField(
                  controller: keyController,
                  obscureText: obscure,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    labelStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white24,
                        size: 20,
                      ),
                      onPressed: onToggleObscure,
                    ),
                  ),
                  onChanged: (v) {
                    widget.onApiKeyChanged(provider, v);
                    // Сброс моделей при смене ключа
                    if (provider == 'openai') {
                      _openaiModels = null;
                    } else {
                      _anthropicModels = null;
                    }
                    _loadModels(provider);
                  },
                ),
                const SizedBox(height: 12),

                // Model selector
                Text('Модель',
                    style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12)),
                const SizedBox(height: 6),
                
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (models != null && models.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: models.map((m) {
                      final selected = m == currentModel;
                      final shortName = m
                          .replaceAll('gpt-', '')
                          .replaceAll('claude-', '')
                          .replaceAll(RegExp(r'-\d{8}$'), '');
                      return ChoiceChip(
                        label: Text(shortName),
                        selected: selected,
                        onSelected: (_) => widget.onModelChanged(provider, m),
                        selectedColor: const Color(0xFF3B82F6),
                        backgroundColor: Colors.white.withOpacity(0.05),
                        labelStyle: TextStyle(
                          color: selected ? Colors.white : Colors.white54,
                          fontSize: 11,
                        ),
                        side: BorderSide.none,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      );
                    }).toList(),
                  )
                else
                  Text(
                    hasKey ? 'Не удалось загрузить' : 'Введите API ключ',
                    style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// === Proxy Field ===
class _ProxyField extends StatefulWidget {
  final String proxy;
  final void Function(String) onChanged;

  const _ProxyField({
    required this.proxy,
    required this.onChanged,
  });

  @override
  State<_ProxyField> createState() => _ProxyFieldState();
}

class _ProxyFieldState extends State<_ProxyField> {
  late TextEditingController _controller;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.proxy);
  }

  @override
  void didUpdateWidget(_ProxyField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.proxy != widget.proxy && _controller.text != widget.proxy) {
      _controller.text = widget.proxy;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasProxy = widget.proxy.isNotEmpty;
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: [
          ListTile(
            dense: true,
            leading: Icon(
              Icons.vpn_key_outlined,
              color: hasProxy ? const Color(0xFF22C55E) : Colors.white24,
              size: 20,
            ),
            title: Text(
              'Прокси',
              style: TextStyle(
                color: hasProxy ? Colors.white70 : Colors.white38,
                fontSize: 13,
              ),
            ),
            subtitle: Text(
              hasProxy ? _formatProxy(widget.proxy) : 'Не настроен',
              style: TextStyle(
                color: hasProxy ? const Color(0xFF22C55E).withOpacity(0.7) : Colors.white24,
                fontSize: 11,
              ),
            ),
            trailing: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              color: Colors.white24,
              size: 18,
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _controller,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'socks5://host:port или http://user:pass@host:port',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 12),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.03),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF3B82F6)),
                      ),
                      suffixIcon: _controller.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 16),
                              color: Colors.white24,
                              onPressed: () {
                                _controller.clear();
                                widget.onChanged('');
                              },
                            )
                          : null,
                    ),
                    onChanged: widget.onChanged,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Форматы: socks5://host:port, http://host:port, socks5://user:pass@host:port',
                    style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 10),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
  
  String _formatProxy(String proxy) {
    // Парсим прокси для маскировки
    // socks5://user:pass@192.168.1.100:1080 → socks5://**:**@**.**.1.100:1080
    try {
      final uri = Uri.parse(proxy);
      final scheme = uri.scheme; // socks5, http
      final host = uri.host;
      final port = uri.port;
      
      // Маскируем хост (первые два октета)
      String maskedHost = host;
      if (host.contains('.')) {
        final parts = host.split('.');
        if (parts.length == 4) {
          // 192.168.1.100 → **.**.1.100
          maskedHost = '**.**.${parts[2]}.${parts[3]}';
        } else if (parts.length >= 2) {
          // domain.example.com → **.example.com
          parts[0] = '**';
          maskedHost = parts.join('.');
        }
      }
      
      // Если есть credentials
      if (uri.userInfo.isNotEmpty) {
        return '$scheme://**:**@$maskedHost:$port';
      }
      
      return '$scheme://$maskedHost:$port';
    } catch (e) {
      return '**';
    }
  }
}
