import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';

class LogScreen extends StatelessWidget {
  const LogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<BleService>(
      builder: (context, ble, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Лог'),
            backgroundColor: Colors.transparent,
            actions: [
              if (ble.logs.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => ble.clearLogs(),
                  tooltip: 'Очистить',
                ),
            ],
          ),
          body: ble.logs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.terminal,
                        size: 64,
                        color: Colors.white.withOpacity(0.1),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Лог пуст',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.3),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: ble.logs.length,
                  itemBuilder: (context, index) {
                    final log = ble.logs[index];
                    return _LogTile(log: log);
                  },
                ),
        );
      },
    );
  }
}

class _LogTile extends StatelessWidget {
  final LogEntry log;
  
  const _LogTile({required this.log});

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
    
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: color.withOpacity(0.2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  log.message,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                if (log.details != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    log.details!,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.3),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Text(
            time,
            style: TextStyle(
              color: Colors.white.withOpacity(0.25),
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
