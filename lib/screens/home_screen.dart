import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';

class HomeScreen extends StatelessWidget {
  final void Function(int) onSwitchTab;

  const HomeScreen({super.key, required this.onSwitchTab});

  @override
  Widget build(BuildContext context) {
    return Consumer<BleService>(
      builder: (context, ble, _) {
        return SafeArea(
          child: CustomScrollView(
            slivers: [
              // Заголовок
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Theme.of(context).colorScheme.primary,
                              Theme.of(context).colorScheme.secondary,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.watch, color: Colors.white, size: 26),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TelaPhone',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.5,
                              ),
                            ),
                            Text(
                              'FutureClock Bridge',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.white38,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Карточка подключения
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: _ConnectionCard(ble: ble, onSwitchTab: onSwitchTab),
                ),
              ),

              // Сетка виджетов
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.1,
                  ),
                  delegate: SliverChildListDelegate([
                    _InfoTile(
                      icon: Icons.access_time,
                      label: 'Время',
                      value: ble.watchTime,
                      gradient: const [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                    ),
                    _InfoTile(
                      icon: Icons.battery_charging_full,
                      label: 'Батарея',
                      value: ble.isConnected ? '${ble.watchBattery}%' : '--%',
                      gradient: const [Color(0xFF22C55E), Color(0xFF16A34A)],
                    ),
                    _InfoTile(
                      icon: Icons.speed,
                      label: 'Статус',
                      value: ble.watchStatus,
                      gradient: const [Color(0xFF22D3EE), Color(0xFF0EA5E9)],
                      small: true,
                    ),
                    _InfoTile(
                      icon: Icons.swap_vert,
                      label: 'Запросов',
                      value: ble.requestCountFormatted,
                      gradient: const [Color(0xFFF59E0B), Color(0xFFD97706)],
                    ),
                  ]),
                ),
              ),

              // Быстрые действия
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'БЫСТРЫЕ ДЕЙСТВИЯ',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.white38,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _ActionButton(
                              icon: Icons.refresh,
                              label: 'Обновить',
                              onTap: ble.isConnected
                                  ? () => ble.requestScreenshot()
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _ActionButton(
                              icon: Icons.home,
                              label: 'На главную',
                              onTap: ble.isConnected
                                  ? () => ble.navigate('home')
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _ActionButton(
                              icon: Icons.screenshot,
                              label: 'Скриншот',
                              onTap: ble.isConnected
                                  ? () => onSwitchTab(3) // таб Show (Скриншот)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Последние события
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'ПОСЛЕДНИЕ СОБЫТИЯ',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.white38,
                          letterSpacing: 1.2,
                        ),
                      ),
                      if (ble.logs.isNotEmpty)
                        TextButton(
                          onPressed: () => onSwitchTab(2), // таб CMD (теперь с логами)
                          child: Text(
                            'Все →',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // Лог (последние 5)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                sliver: ble.logs.isEmpty
                    ? SliverToBoxAdapter(
                        child: Container(
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.05),
                            ),
                          ),
                          child: Column(
                            children: [
                              Icon(Icons.inbox_outlined,
                                  size: 48,
                                  color: Colors.white.withOpacity(0.1)),
                              const SizedBox(height: 12),
                              Text(
                                'Нет событий',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.3),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            if (index >= ble.logs.length || index >= 5) return null;
                            return _LogItem(log: ble.logs[index]);
                          },
                          childCount: ble.logs.length.clamp(0, 5),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Карточка подключения
class _ConnectionCard extends StatelessWidget {
  final BleService ble;
  final void Function(int) onSwitchTab;

  const _ConnectionCard({required this.ble, required this.onSwitchTab});

  @override
  Widget build(BuildContext context) {
    final isConnected = ble.isConnected;
    final isConnecting =
        ble.connectionState == BleConnectionState.connecting ||
            ble.connectionState == BleConnectionState.scanning;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: isConnected
            ? LinearGradient(
                colors: [
                  const Color(0xFF22C55E).withOpacity(0.1),
                  const Color(0xFF22C55E).withOpacity(0.05),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: isConnected ? null : Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isConnected
              ? const Color(0xFF22C55E).withOpacity(0.3)
              : Colors.white.withOpacity(0.05),
        ),
      ),
      child: Row(
        children: [
          // Иконка
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: isConnected
                  ? const Color(0xFF22C55E).withOpacity(0.2)
                  : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              isConnected
                  ? Icons.bluetooth_connected
                  : isConnecting
                      ? Icons.bluetooth_searching
                      : Icons.bluetooth_disabled,
              color: isConnected
                  ? const Color(0xFF22C55E)
                  : isConnecting
                      ? Colors.white54
                      : Colors.white24,
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isConnected
                      ? ble.deviceName ?? 'FutureClock'
                      : isConnecting
                          ? 'Подключение...'
                          : 'Не подключено',
                  style: TextStyle(
                    color: isConnected ? Colors.white : Colors.white54,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isConnected
                      ? ble.deviceAddress ?? ''
                      : 'Нажмите для подключения',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: isConnecting
                ? null
                : () {
                    if (isConnected) {
                      ble.disconnect();
                    } else {
                      // Перекидываем в Настройки (таб 4 - Config)
                      onSwitchTab(4);
                    }
                  },
            style: FilledButton.styleFrom(
              backgroundColor: isConnected
                  ? Colors.white.withOpacity(0.1)
                  : Theme.of(context).colorScheme.primary,
              foregroundColor: isConnected ? Colors.white70 : Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            child: Text(isConnected ? 'Откл.' : 'Подкл.'),
          ),
        ],
      ),
    );
  }
}

/// Плитка с информацией
class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final List<Color> gradient;
  final bool small;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.gradient,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: gradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: small ? 18 : 24,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white38,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Кнопка быстрого действия
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(enabled ? 0.05 : 0.02),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: Column(
            children: [
              Icon(icon, color: enabled ? Colors.white70 : Colors.white24, size: 24),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? Colors.white70 : Colors.white24,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Элемент лога
class _LogItem extends StatelessWidget {
  final LogEntry log;

  const _LogItem({required this.log});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (log.level) {
      LogLevel.success => (Icons.check_circle, const Color(0xFF22C55E)),
      LogLevel.warning => (Icons.warning, const Color(0xFFF59E0B)),
      LogLevel.error => (Icons.error, const Color(0xFFEF4444)),
      LogLevel.incoming => (Icons.arrow_downward, const Color(0xFF22D3EE)),
      LogLevel.outgoing => (Icons.arrow_upward, const Color(0xFF6366F1)),
      LogLevel.info => (Icons.info_outline, Colors.white38),
    };

    final time = '${log.timestamp.hour.toString().padLeft(2, '0')}:'
        '${log.timestamp.minute.toString().padLeft(2, '0')}:'
        '${log.timestamp.second.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(log.message,
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
                if (log.details != null)
                  Text(log.details!,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.3), fontSize: 11)),
              ],
            ),
          ),
          Text(
            time,
            style: TextStyle(
              color: Colors.white.withOpacity(0.2),
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
