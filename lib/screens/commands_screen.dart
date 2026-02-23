import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';

class CommandsScreen extends StatefulWidget {
  const CommandsScreen({super.key});

  @override
  State<CommandsScreen> createState() => _CommandsScreenState();
}

class _CommandsScreenState extends State<CommandsScreen> {
  // Контроллеры для диалогов (создаются один раз)
  final _setVarController = TextEditingController();
  final _setValueController = TextEditingController();
  final _getVarController = TextEditingController();
  final _navController = TextEditingController();
  final _callController = TextEditingController();
  final _notifyTitleController = TextEditingController();
  final _notifyMessageController = TextEditingController();

  @override
  void dispose() {
    _setVarController.dispose();
    _setValueController.dispose();
    _getVarController.dispose();
    _navController.dispose();
    _callController.dispose();
    _notifyTitleController.dispose();
    _notifyMessageController.dispose();
    super.dispose();
  }

  // === DIALOGS ===

  Future<void> _showSetStateDialog(BleService ble) async {
    _setVarController.clear();
    _setValueController.clear();
    
    String? varName;
    String? varValue;
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('ui set', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _setVarController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Переменная',
                labelStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _setValueController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Значение',
                labelStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            onPressed: () {
              varName = _setVarController.text.trim();
              varValue = _setValueController.text;
              Navigator.pop(ctx);
            },
            child: const Text('SET'),
          ),
        ],
      ),
    );
    
    if (varName != null && varName!.isNotEmpty) {
      await ble.setState(varName!, varValue!);
    }
  }

  Future<void> _showGetStateDialog(BleService ble) async {
    _getVarController.clear();
    String? result;
    
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('ui get', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _getVarController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Переменная',
                  labelStyle: TextStyle(color: Colors.white38),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                ),
              ),
              if (result != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    result!,
                    style: const TextStyle(
                      color: Color(0xFF22C55E),
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Закрыть', style: TextStyle(color: Colors.white38)),
            ),
            FilledButton(
              onPressed: () async {
                final v = _getVarController.text.trim();
                if (v.isNotEmpty) {
                  final value = await ble.getState(v);
                  setDialogState(() => result = value ?? '(null)');
                }
              },
              child: const Text('GET'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showNavigateDialog(BleService ble) async {
    _navController.clear();
    String? page;
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('ui nav', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: _navController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Page ID (home, settings, ...)',
            labelStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            onPressed: () {
              page = _navController.text.trim();
              Navigator.pop(ctx);
            },
            child: const Text('GO'),
          ),
        ],
      ),
    );
    
    if (page != null && page!.isNotEmpty) {
      await ble.navigate(page!);
    }
  }

  Future<void> _showCallDialog(BleService ble) async {
    _callController.clear();
    String? func;
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('ui call', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: _callController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Lua функция',
            labelStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            onPressed: () {
              func = _callController.text.trim();
              Navigator.pop(ctx);
            },
            child: const Text('CALL'),
          ),
        ],
      ),
    );
    
    if (func != null && func!.isNotEmpty) {
      await ble.callFunction(func!);
    }
  }

  Future<void> _showNotifyDialog(BleService ble) async {
    _notifyTitleController.clear();
    _notifyMessageController.clear();
    
    String? title;
    String? message;
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('notify', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _notifyTitleController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Заголовок',
                labelStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notifyMessageController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Сообщение',
                labelStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            onPressed: () {
              title = _notifyTitleController.text.trim();
              message = _notifyMessageController.text;
              Navigator.pop(ctx);
            },
            child: const Text('SEND'),
          ),
        ],
      ),
    );
    
    if (title != null && title!.isNotEmpty) {
      await ble.sendNotification(title!, message ?? '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    final enabled = ble.isConnected;
    final logs = ble.logs;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Команды'),
        backgroundColor: Colors.transparent,
        actions: [
          // Clear logs
          if (logs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Очистить лог',
              onPressed: () {
                Future.microtask(() => context.read<BleService>().clearLogs());
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // Warning if not connected
          if (!enabled)
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFFF59E0B).withOpacity(0.3),
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning, color: Color(0xFFF59E0B), size: 18),
                  SizedBox(width: 10),
                  Text(
                    'Подключитесь к часам',
                    style: TextStyle(color: Color(0xFFF59E0B), fontSize: 13),
                  ),
                ],
              ),
            ),

          // Command buttons - Row 1: ping, info, notify
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: _CmdButton(
                    icon: Icons.network_ping,
                    label: 'ping',
                    enabled: enabled,
                    onPressed: () {
                      Future.microtask(() => context.read<BleService>().sysPing());
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CmdButton(
                    icon: Icons.info_outline,
                    label: 'info',
                    enabled: enabled,
                    onPressed: () {
                      Future.microtask(() => context.read<BleService>().sysInfo());
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CmdButton(
                    icon: Icons.notifications,
                    label: 'notify',
                    enabled: enabled,
                    onPressed: () => _showNotifyDialog(context.read<BleService>()),
                  ),
                ),
              ],
            ),
          ),
          
          // Command buttons - Row 2: set, get, nav, call
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: _CmdButton(
                    icon: Icons.upload,
                    label: 'set',
                    enabled: enabled,
                    onPressed: () => _showSetStateDialog(context.read<BleService>()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CmdButton(
                    icon: Icons.download,
                    label: 'get',
                    enabled: enabled,
                    onPressed: () => _showGetStateDialog(context.read<BleService>()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CmdButton(
                    icon: Icons.route,
                    label: 'nav',
                    enabled: enabled,
                    onPressed: () => _showNavigateDialog(context.read<BleService>()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CmdButton(
                    icon: Icons.functions,
                    label: 'call',
                    enabled: enabled,
                    onPressed: () => _showCallDialog(context.read<BleService>()),
                  ),
                ),
              ],
            ),
          ),

          // Divider
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  'ЛОГ',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.3),
                    fontSize: 11,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 1,
                    color: Colors.white.withOpacity(0.05),
                  ),
                ),
              ],
            ),
          ),

          // Log list
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.terminal,
                          size: 48,
                          color: Colors.white.withOpacity(0.1),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Лог пуст',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.3),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final log = logs[index];
                      return _LogTile(log: log);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// === Command Button ===

class _CmdButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  const _CmdButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled
          ? const Color(0xFF3B82F6).withOpacity(0.15)
          : Colors.white.withOpacity(0.05),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            children: [
              Icon(
                icon,
                size: 16,
                color: enabled ? const Color(0xFF3B82F6) : Colors.white24,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? Colors.white70 : Colors.white24,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// === Log Tile ===

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
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withOpacity(0.15),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  log.message,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
                if (log.details != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    log.details!,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.3),
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Text(
            time,
            style: TextStyle(
              color: Colors.white.withOpacity(0.2),
              fontSize: 10,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
