import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks_client.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/ble_service.dart';
import '../services/local_server.dart';
import 'emulator_screen.dart';

/// Доступные ресурсы для промптов
const _promptResources = [
  'rules.md',
  'calc.xml',
  'timer.xml',
  'weather.xml',
  'counter.xml',
  // runtime.html не показываем в списке - он для эмулятора
];

/// Случайные фразы при загрузке
const _loadingPhrases = [
  'Думаю и пишу код...',
  'Тут есть над чем поработать...',
  'Хм, секундочку...',
  'Интересно, сейчас кое-что попробуем...',
  'Так, тут надо внимательно...',
  'Понял, приступим...',
  'Почти готово, минутку...',
  'Кое-что попробуем...',
  'Да, я уже приступил...',
  'Сначала подумаю...',
  'Выбираю оптимальное решение...',
  'Есть пара мыслей...',
];

const _longWaitPhrases = [
  'Осталось немножко, секундочку...',
  'Уже почти, потерпи чуть-чуть...',
  'Скоро будет готово...',
  'Заканчиваю, буквально момент...',
  'Финальные штрихи...',
  'Последняя проверка...',
  'Дописываю, не уходи...',
  'Почти, ещё капельку...',
  'Вот-вот закончу...',
  'Ты там? Я заканчиваю...',
  'Осталось совсем немного...',
  'Терпение, мой друг...',
];

final _random = Random();

/// Расширение файла приложения
const _appExtension = 'bax';

/// Генерация имени файла: calc -> calc.bax
String _appFileName(String name) => '$name.$_appExtension';

/// Генерация полного пути: calc -> calc/calc.bax  
String _appFilePath(String name) => '$name/${_appFileName(name)}';

class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  String? _pullingApp;
  String? _pullingAction; // 'run' or 'edit'

  Future<void> _refresh() async {
    final ble = context.read<BleService>();
    if (!ble.isConnected) return;
    await ble.refreshApps();
  }

  /// Извлекает список имён файлов из ответа (Map или List)
  List<String> _parseFiles(dynamic files) {
    if (files is Map) {
      return files.keys.cast<String>().toList();
    } else if (files is List) {
      return files.cast<String>();
    }
    return [];
  }

  /// Находит главный файл приложения по приоритету: .bax → .xml → .html
  String? _findMainFile(List<String> files) {
    // Приоритет расширений
    const priorities = ['.bax', '.xml', '.html'];
    
    for (final ext in priorities) {
      final found = files.where((f) => f.toLowerCase().endsWith(ext)).toList();
      if (found.length == 1) {
        return found.first;
      } else if (found.length > 1) {
        // Несколько файлов с одним расширением — ошибка
        return null;
      }
    }
    return null;
  }

  Future<void> _run(String appName) async {
    setState(() {
      _pullingApp = appName;
      _pullingAction = 'run';
    });
    
    final ble = context.read<BleService>();
    
    // Сначала получаем список файлов
    final info = await ble.appInfo(appName);
    final files = _parseFiles(info?['files']);
    final mainFile = _findMainFile(files.isNotEmpty ? files : ['app.html']) ?? 'app.html';
    
    // Загружаем код приложения
    final code = await ble.pullFile(appName, file: mainFile);
    
    if (mounted) setState(() {
      _pullingApp = null;
      _pullingAction = null;
    });
    if (code == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось загрузить приложение'),
            backgroundColor: Color(0xFFEF4444),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    
    // Открываем эмулятор
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmulatorScreen(
          appName: appName,
          code: code,
        ),
      ),
    );
  }

  Future<void> _edit(String appName, {String? file}) async {
    setState(() {
      _pullingApp = appName;
      _pullingAction = 'edit';
    });

    final ble = context.read<BleService>();
    
    // Если файл не указан — ищем главный
    String targetFile = file ?? 'app.html';
    if (file == null) {
      final info = await ble.appInfo(appName);
      final files = _parseFiles(info?['files']);
      
      if (files.isNotEmpty) {
        final mainFile = _findMainFile(files);
        if (mainFile == null && files.length > 1) {
          // Несколько файлов с одним расширением
          if (mounted) {
            setState(() {
              _pullingApp = null;
              _pullingAction = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Найдено несколько главных файлов. Выберите в меню ⋮'),
                backgroundColor: Color(0xFFFBBF24),
              ),
            );
          }
          return;
        }
        targetFile = mainFile ?? files.first;
      }
    }

    final content = await ble.pullFile(appName, file: targetFile);

    if (!mounted) return;
    setState(() {
      _pullingApp = null;
      _pullingAction = null;
    });
    if (content == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EditorPage(
          appName: appName,
          initialContent: content,
          isNew: false,
        ),
      ),
    );
  }

  Future<void> _delete(String appName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить приложение?'),
        content: Text('$appName будет удалено с часов.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final ble = context.read<BleService>();
    final ok = await ble.deleteApp(appName);
    if (ok) _refresh();
  }

  void _newApp() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const _EditorPage(
          appName: '',
          initialContent: '''<app>
  <ui default="/main">
    <page id="main">
      <label align="center" y="35%" color="#fff" font="32">{text}</label>
      
      <button x="10%" y="70%" w="35%" h="44" bgcolor="#3B82F6" onclick="start">
        Start
      </button>
      <button x="55%" y="70%" w="35%" h="44" bgcolor="#6B7280" onclick="reset">
        Reset
      </button>
    </page>
  </ui>
  
  <state>
    <string name="text" default="Hello World"/>
    <string name="original" default="Hello World"/>
  </state>
  
  <script language="lua">
    function start()
      state.text = string.reverse(state.text)
      
      -- UPPERCASE
      -- state.text = string.upper(state.text)
      
      -- lowercase  
      -- state.text = string.lower(state.text)
      
      -- first 5 chars
      -- state.text = string.sub(state.text, 1, 5)
      
      -- length
      -- state.text = string.len(state.text)
    end
    
    function reset()
      state.text = state.original
    end
  </script>
</app>''',
          isNew: true,
        ),
      ),
    ).then((_) => _refresh());
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BleService>(
      builder: (context, ble, _) {
        final connected = ble.isConnected;
        final _apps = ble.apps;
        final _loading = ble.appsLoading;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Apps'),
            backgroundColor: Colors.transparent,
            actions: [
              IconButton(
                onPressed: connected && !_loading ? _refresh : null,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          body: _apps.isEmpty && !_loading
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        connected ? Icons.apps : Icons.rocket_launch_outlined,
                        size: 48, 
                        color: Colors.white.withOpacity(0.1),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        connected ? 'Нет приложений' : 'Создайте приложение',
                        style: TextStyle(color: Colors.white.withOpacity(0.3)),
                      ),
                      if (!connected) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Подключение не требуется',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.2),
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _newApp,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Создать'),
                      ),
                    ],
                  ),
                )
              : ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        // Новое приложение — первым
                        _NewAppCard(onTap: _newApp),
                        const SizedBox(height: 16),
                        
                        // Список приложений
                        ..._apps.map((app) => _AppCard(
                              name: app,
                              pullingRun: _pullingApp == app && _pullingAction == 'run',
                              pullingEdit: _pullingApp == app && _pullingAction == 'edit',
                              onRun: () => _run(app),
                              onEditFile: (file) => _edit(app, file: file),
                              onDelete: () => _delete(app),
                            )),
                        const SizedBox(height: 80),
                      ],
                    ),
        );
      },
    );
  }
}

// === Карточка приложения (раскрывается → info + файлы) ===

class _AppCard extends StatefulWidget {
  final String name;
  final bool pullingRun;
  final bool pullingEdit;
  final VoidCallback onRun;
  final void Function(String? file) onEditFile;
  final VoidCallback onDelete;

  const _AppCard({
    required this.name,
    required this.pullingRun,
    required this.pullingEdit,
    required this.onRun,
    required this.onEditFile,
    required this.onDelete,
  });

  @override
  State<_AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<_AppCard> {
  
  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  void _showMenu() {
    final RenderBox button = context.findRenderObject() as RenderBox;
    final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final Offset position = button.localToGlobal(
      Offset(button.size.width - 48, button.size.height / 2),
      ancestor: overlay,
    );
    
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      color: const Color(0xFF252525),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem(
          value: 'info',
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: Colors.white.withOpacity(0.6)),
              const SizedBox(width: 12),
              const Text('Информация', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: const Color(0xFFEF4444).withOpacity(0.8)),
              const SizedBox(width: 12),
              Text('Удалить', style: TextStyle(color: const Color(0xFFEF4444).withOpacity(0.8))),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'info') {
        _showInfoDialog();
      } else if (value == 'delete') {
        widget.onDelete();
      }
    });
  }
  
  Future<void> _showInfoDialog() async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(widget.name, style: const TextStyle(color: Colors.white)),
        content: FutureBuilder<Map<String, dynamic>?>(
          future: context.read<BleService>().appInfo(widget.name),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 60,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            
            final info = snapshot.data!;
            final title = info['title'] as String?;
            final size = info['size'] as int?;
            final filesRaw = info['files'];
            final files = filesRaw is Map 
                ? filesRaw.keys.cast<String>().toList() 
                : (filesRaw is List ? filesRaw.cast<String>() : <String>[]);
            
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null && title != widget.name)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(title, style: TextStyle(color: Colors.white.withOpacity(0.6))),
                  ),
                if (size != null)
                  Text('Размер: ${_fmtSize(size)}', 
                      style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13)),
                if (files.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Файлы:', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13)),
                  const SizedBox(height: 6),
                  ...files.map((f) => Padding(
                    padding: const EdgeInsets.only(left: 8, top: 4),
                    child: Text('• $f', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12)),
                  )),
                ],
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // App icon
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.widgets_outlined, color: Colors.white38, size: 20),
            ),
            const SizedBox(width: 12),
            
            // Name
            Expanded(
              child: Text(
                widget.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            
            // Run
            _ActionButton(
              icon: Icons.play_arrow_rounded,
              color: const Color(0xFF22C55E),
              loading: widget.pullingRun,
              onTap: widget.onRun,
              tooltip: 'Запустить',
            ),
            const SizedBox(width: 4),
            
            // Edit
            _ActionButton(
              icon: Icons.edit_outlined,
              color: const Color(0xFF3B82F6),
              loading: widget.pullingEdit,
              onTap: () => widget.onEditFile(null),
              tooltip: 'Редактировать',
            ),
            const SizedBox(width: 4),
            
            // Menu
            _ActionButton(
              icon: Icons.more_vert,
              color: Colors.white38,
              onTap: _showMenu,
              tooltip: 'Меню',
            ),
          ],
        ),
      ),
    );
  }
}

// Компактная кнопка действия
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String? tooltip;
  final bool loading;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.tooltip,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: loading ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: loading
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}

// === Карточка "Новое приложение" ===

class _NewAppCard extends StatelessWidget {
  final VoidCallback onTap;

  const _NewAppCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.4)),
          color: const Color(0xFF3B82F6).withOpacity(0.08),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.rocket_launch,
                size: 20, color: Color(0xFF60A5FA)),
            SizedBox(width: 10),
            Text(
              'Создать приложение',
              style: TextStyle(
                color: Color(0xFF60A5FA),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================
//  XML Syntax Highlighting Controller
// =========================================================

class _XmlHighlightController extends TextEditingController {
  _XmlHighlightController({String? text}) : super(text: text);

  // Theme — GitHub Dark inspired
  static const _cTag = Color(0xFFEF4444);      // red — tag names
  static const _cBracket = Color(0xFF9CA3AF);   // gray — < > / =
  static const _cAttr = Color(0xFFFBBF24);      // yellow — attributes
  static const _cValue = Color(0xFF34D399);      // green — "values"
  static const _cComment = Color(0xFF6B7280);    // dim — comments
  static const _cLua = Color(0xFFC4B5FD);        // lavender — lua code
  static const _cText = Color(0xFFD1D5DB);       // light — text
  static const _cBinding = Color(0xFF60A5FA);    // blue — {bindings}

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final src = text;
    if (src.isEmpty) return TextSpan(style: base, text: '');

    final mono = base.copyWith(
        fontFamily: 'monospace', fontSize: 13, height: 1.5);
    final spans = <TextSpan>[];
    int i = 0;
    bool inScript = false;

    while (i < src.length) {
      // <!-- comment -->
      if (src.startsWith('<!--', i)) {
        final end = src.indexOf('-->', i + 4);
        final close = end == -1 ? src.length : end + 3;
        spans.add(TextSpan(
          text: src.substring(i, close),
          style: mono.copyWith(
              color: _cComment, fontStyle: FontStyle.italic),
        ));
        i = close;
        continue;
      }

      // <tag ...>
      if (src[i] == '<') {
        final close = _findTagEnd(src, i);
        final tagSrc = src.substring(i, close);
        final tagLower = tagSrc.toLowerCase();

        if (tagLower.contains('<script')) inScript = true;
        if (tagLower.contains('</script')) inScript = false;

        spans.addAll(_highlightTag(tagSrc, mono));
        i = close;
        continue;
      }

      // Lua code between <script> and </script>
      if (inScript) {
        final next = src.indexOf('<', i);
        final end = next == -1 ? src.length : next;
        final luaCode = src.substring(i, end);
        spans.addAll(_highlightLua(luaCode, mono));
        i = end;
        continue;
      }

      // {binding} in text
      if (src[i] == '{') {
        final close = src.indexOf('}', i);
        if (close != -1 && close - i < 80) {
          spans.add(TextSpan(
            text: src.substring(i, close + 1),
            style: mono.copyWith(color: _cBinding),
          ));
          i = close + 1;
          continue;
        }
      }

      // Plain text
      int end = i + 1;
      while (end < src.length && src[end] != '<' && src[end] != '{') end++;
      spans.add(TextSpan(
        text: src.substring(i, end),
        style: mono.copyWith(color: _cText),
      ));
      i = end;
    }

    return TextSpan(style: base, children: spans);
  }

  int _findTagEnd(String s, int start) {
    int i = start + 1;
    while (i < s.length) {
      if (s[i] == '"') {
        i = s.indexOf('"', i + 1);
        if (i == -1) return s.length;
        i++;
        continue;
      }
      if (s[i] == "'") {
        i = s.indexOf("'", i + 1);
        if (i == -1) return s.length;
        i++;
        continue;
      }
      if (s[i] == '>') return i + 1;
      i++;
    }
    return s.length;
  }

  List<TextSpan> _highlightTag(String tag, TextStyle m) {
    final spans = <TextSpan>[];
    int i = 0;

    // < or </
    if (tag.startsWith('</')) {
      spans.add(TextSpan(text: '</', style: m.copyWith(color: _cBracket)));
      i = 2;
    } else {
      spans.add(TextSpan(text: '<', style: m.copyWith(color: _cBracket)));
      i = 1;
    }

    // Tag name
    int ne = i;
    while (ne < tag.length && !' \t\n\r/>'.contains(tag[ne])) ne++;
    spans.add(TextSpan(
      text: tag.substring(i, ne),
      style: m.copyWith(color: _cTag, fontWeight: FontWeight.w600),
    ));
    i = ne;

    // Attributes + close
    while (i < tag.length) {
      // Whitespace
      if (' \t\n\r'.contains(tag[i])) {
        int w = i;
        while (w < tag.length && ' \t\n\r'.contains(tag[w])) w++;
        spans.add(TextSpan(text: tag.substring(i, w), style: m));
        i = w;
        continue;
      }

      // />
      if (tag[i] == '/' && i + 1 < tag.length && tag[i + 1] == '>') {
        spans.add(TextSpan(text: '/>', style: m.copyWith(color: _cBracket)));
        i += 2;
        continue;
      }
      // >
      if (tag[i] == '>') {
        spans.add(TextSpan(text: '>', style: m.copyWith(color: _cBracket)));
        i++;
        continue;
      }

      // Attr name
      int ae = i;
      while (ae < tag.length && !' \t\n\r=/>'.contains(tag[ae])) ae++;
      if (ae > i) {
        spans.add(TextSpan(
            text: tag.substring(i, ae),
            style: m.copyWith(color: _cAttr)));
        i = ae;
      }

      // =
      if (i < tag.length && tag[i] == '=') {
        spans.add(TextSpan(text: '=', style: m.copyWith(color: _cBracket)));
        i++;
      }

      // "value" or 'value'
      if (i < tag.length && (tag[i] == '"' || tag[i] == "'")) {
        final q = tag[i];
        final ve = tag.indexOf(q, i + 1);
        final end = ve == -1 ? tag.length : ve + 1;
        final val = tag.substring(i, end);

        if (val.contains('{')) {
          _addValueWithBindings(spans, val, m);
        } else {
          spans.add(TextSpan(text: val, style: m.copyWith(color: _cValue)));
        }
        i = end;
        continue;
      }

      // Fallback
      if (ae == i && i < tag.length) {
        spans.add(TextSpan(text: tag[i], style: m.copyWith(color: _cText)));
        i++;
      }
    }
    return spans;
  }

  void _addValueWithBindings(
      List<TextSpan> spans, String val, TextStyle m) {
    int i = 0;
    while (i < val.length) {
      final bs = val.indexOf('{', i);
      if (bs == -1) {
        spans.add(TextSpan(
            text: val.substring(i), style: m.copyWith(color: _cValue)));
        break;
      }
      if (bs > i) {
        spans.add(TextSpan(
            text: val.substring(i, bs), style: m.copyWith(color: _cValue)));
      }
      final be = val.indexOf('}', bs);
      if (be == -1) {
        spans.add(TextSpan(
            text: val.substring(bs), style: m.copyWith(color: _cBinding)));
        break;
      }
      spans.add(TextSpan(
        text: val.substring(bs, be + 1),
        style: m.copyWith(color: _cBinding),
      ));
      i = be + 1;
    }
  }

  /// Подсветка Lua кода — комментарии отдельным цветом
  List<TextSpan> _highlightLua(String lua, TextStyle m) {
    final spans = <TextSpan>[];
    int i = 0;

    while (i < lua.length) {
      // Многострочный комментарий --[[ ... ]]
      if (lua.startsWith('--[[', i)) {
        final end = lua.indexOf(']]', i + 4);
        final close = end == -1 ? lua.length : end + 2;
        spans.add(TextSpan(
          text: lua.substring(i, close),
          style: m.copyWith(color: _cComment, fontStyle: FontStyle.italic),
        ));
        i = close;
        continue;
      }

      // Однострочный комментарий -- ...
      if (lua.startsWith('--', i)) {
        final nl = lua.indexOf('\n', i);
        final end = nl == -1 ? lua.length : nl;
        spans.add(TextSpan(
          text: lua.substring(i, end),
          style: m.copyWith(color: _cComment, fontStyle: FontStyle.italic),
        ));
        i = end;
        continue;
      }

      // Строка "..." или '...'
      if (lua[i] == '"' || lua[i] == "'") {
        final q = lua[i];
        final end = lua.indexOf(q, i + 1);
        final close = end == -1 ? lua.length : end + 1;
        spans.add(TextSpan(
          text: lua.substring(i, close),
          style: m.copyWith(color: _cValue),
        ));
        i = close;
        continue;
      }

      // Обычный Lua код до следующего спецсимвола
      int end = i + 1;
      while (end < lua.length &&
             !lua.startsWith('--', end) &&
             lua[end] != '"' &&
             lua[end] != "'") {
        end++;
      }
      spans.add(TextSpan(
        text: lua.substring(i, end),
        style: m.copyWith(color: _cLua),
      ));
      i = end;
    }

    return spans;
  }
}

// =========================================================
//  Редактор (полноэкранный)
// =========================================================

class _EditorPage extends StatefulWidget {
  final String appName;
  final String initialContent;
  final bool isNew;

  const _EditorPage({
    required this.appName,
    required this.initialContent,
    required this.isNew,
  });

  @override
  State<_EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<_EditorPage> with SingleTickerProviderStateMixin {
  // Максимальное количество автоматических попыток исправления
  static const int kMaxAutoFixAttempts = 5;
  
  late TabController _tabController;
  late TextEditingController _nameController;
  late _XmlHighlightController _contentController;
  final ScrollController _chatScrollController = ScrollController();
  bool _pushing = false;
  String? _error;
  int _lines = 0;
  int _bytes = 0;
  
  // Для отслеживания несохранённых изменений
  late String _initialContent;
  late String _initialName;
  
  // Chat state
  final List<_ChatMessage> _messages = [];
  final TextEditingController _chatController = TextEditingController();
  bool _chatLoading = false;
  String _loadingPhrase = '';
  Timer? _longWaitTimer;
  Timer? _warmupTimer;
  
  // Pending code from AI (for popup)
  String? _pendingCode;
  
  // Счётчик попыток автоисправления
  int _autoFixAttempts = 0;
  
  // Уже отправленные warnings (не дублируем)
  final Set<String> _sentWarnings = {};
  
  // Автоименовка: false = можно автоматически менять имя из title
  bool _nameManuallyEdited = false;
  
  // Voice input
  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;
  bool _speechAvailable = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _nameController = TextEditingController(text: widget.appName);
    _contentController = _XmlHighlightController(text: widget.initialContent);
    _updateStats();
    
    // Сохраняем начальные значения для отслеживания изменений
    _initialContent = widget.initialContent;
    _initialName = widget.appName;
    
    // Если редактируем существующее приложение — имя уже задано
    _nameManuallyEdited = widget.appName.isNotEmpty;
    
    // Для новых — сразу AI, для существующих — код
    if (widget.isNew) {
      _tabController.index = 1; // AI
    }
    
    // Отслеживаем ручные изменения имени
    _nameController.addListener(_onNameChanged);
  }
  
  void _onNameChanged() {
    // Если пользователь что-то ввёл — помечаем как ручное редактирование
    if (_nameController.text.isNotEmpty) {
      _nameManuallyEdited = true;
    }
  }
  
  /// Проверяет, есть ли несохранённые изменения
  bool _hasUnsavedChanges() {
    if (_messages.isNotEmpty) return true;
    if (_contentController.text != _initialContent) return true;
    if (!widget.isNew && _nameController.text != _initialName) return true;
    if (widget.isNew && (_contentController.text.isNotEmpty || _nameController.text.isNotEmpty)) {
      if (_contentController.text == _initialContent && _nameController.text.isEmpty) {
        return false;
      }
      return true;
    }
    return false;
  }
  
  /// Показывает диалог подтверждения выхода
  Future<bool> _confirmExit() async {
    if (!_hasUnsavedChanges()) return true;
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: const Text('Выйти без сохранения?'),
        content: const Text(
          'Несохранённые изменения будут потеряны.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }
    
    // Инициализируем при первом использовании (тут запросятся права)
    if (!_speechAvailable) {
      _speechAvailable = await _speech.initialize(
        onError: (error) {
          debugPrint('[Speech] Error: $error');
          if (mounted) {
            setState(() => _isListening = false);
            _showNotification('Ошибка: ${error.errorMsg}', isError: true);
          }
        },
        onStatus: (status) {
          debugPrint('[Speech] Status: $status');
          if (status == 'done' || status == 'notListening') {
            if (mounted) setState(() => _isListening = false);
          }
        },
      );
      
      if (!_speechAvailable) {
        _showNotification('Голосовой ввод недоступен', isError: true);
        return;
      }
    }
    
    if (!mounted) return;
    setState(() => _isListening = true);
    
    // Сохраняем текущий текст чтобы добавлять к нему
    final existingText = _chatController.text;
    final prefix = existingText.isNotEmpty && !existingText.endsWith(' ') 
        ? '$existingText ' 
        : existingText;
    
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() {
          _chatController.text = prefix + result.recognizedWords;
          _chatController.selection = TextSelection.fromPosition(
            TextPosition(offset: _chatController.text.length),
          );
        });
      },
      localeId: 'ru_RU',
      listenMode: ListenMode.dictation,
      cancelOnError: true,
      partialResults: true,
      pauseFor: const Duration(seconds: 7),    // Пауза 7 сек до остановки
      listenFor: const Duration(seconds: 120), // Максимум 2 минуты
    );
  }

  @override
  void dispose() {
    _speech.stop();
    _longWaitTimer?.cancel();
    _warmupTimer?.cancel();
    _nameController.removeListener(_onNameChanged);
    _tabController.dispose();
    _nameController.dispose();
    _contentController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  void _updateStats() {
    _bytes = _contentController.text.length;
    _lines = _contentController.text.split('\n').length;
  }

  void _runInEmulator({String? codeOverride}) {
    final name = _nameController.text.trim();
    final code = codeOverride ?? _contentController.text;
    
    if (code.isEmpty) return;
    
    // Запоминаем текущую вкладку
    final savedTabIndex = _tabController.index;
    
    Navigator.push<EmulatorResult>(
      context,
      MaterialPageRoute(
        builder: (_) => EmulatorScreen(
          appName: name.isEmpty ? 'preview' : name,
          code: code,
        ),
      ),
    ).then((result) {
      if (!mounted) return;
      
      // Если вернулись с ошибкой для исправления
      if (result != null && result.hasError) {
        _handleAutoFix(result);
      } else {
        // Просто восстанавливаем вкладку
        _tabController.animateTo(savedTabIndex);
      }
    });
  }
  
  /// Автоисправление ошибки через AI
  void _handleAutoFix(EmulatorResult result) {
    // Переключаемся на вкладку AI
    _tabController.animateTo(1);
    
    // Формируем сообщение для AI - олимпиадный стиль
    final errorPrompt = '''🔴 КОД НЕ ПРИНЯТ — RUNTIME ERROR

Ошибка при выполнении:
```
${result.errorMessage}
```

Контекст:
```
${result.errorContext ?? 'нет данных'}
```

Решение должно быть идеальным — исправь ВСЕ ошибки. Частичные решения не засчитываются.''';
    
    // Добавляем сообщение в чат и отправляем
    setState(() {
      _chatController.text = errorPrompt;
    });
    
    // Небольшая задержка чтобы UI обновился
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        _sendChatMessage();
      }
    });
  }

  /// Показывает компактное уведомление сверху (под AppBar)
  void _showNotification(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 13),
        ),
        backgroundColor: isError 
            ? const Color(0xFFEF4444)  // Светло-красный
            : const Color(0xFF22C55E), // Зелёный
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: MediaQuery.of(context).size.height - 180,
          left: 16,
          right: 16,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _push() async {
    final name = _nameController.text.trim();
    final content = _contentController.text;

    if (name.isEmpty) {
      setState(() => _error = 'Введите имя приложения');
      return;
    }

    setState(() {
      _pushing = true;
      _error = null;
    });

    // Автосохранение перед push
    await _saveLocal(silent: true);

    if (!mounted) return;
    final ble = context.read<BleService>();
    final ok = await ble.pushFile(name, _appFileName(name), content);

    if (mounted) {
      setState(() => _pushing = false);
      if (ok) {
        _showNotification('${_appFilePath(name)} загружен ✓');
        Navigator.pop(context);
      } else {
        setState(() => _error = 'Ошибка отправки');
      }
    }
  }

  Future<void> _saveLocal({bool silent = false}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final name = _nameController.text.trim();
      if (name.isEmpty) {
        if (!silent) _showNotification('Введите имя приложения', isError: true);
        return;
      }
      // Создаём папку name/ и сохраняем файл
      final appDir = Directory('${dir.path}/$name');
      if (!appDir.existsSync()) {
        appDir.createSync(recursive: true);
      }
      final path = '${appDir.path}/${_appFileName(name)}';
      await File(path).writeAsString(_contentController.text);
      
      // Обновляем начальные значения — теперь изменения "сохранены"
      _initialContent = _contentController.text;
      _initialName = name;
    } catch (e) {
      if (mounted && !silent) {
        _showNotification('Ошибка: $e', isError: true);
      }
    }
  }
  
  /// Экспорт кода через системный диалог "Поделиться"
  Future<void> _exportCode() async {
    try {
      final name = _nameController.text.trim();
      final fileName = name.isEmpty ? 'app.bax' : '$name.bax';
      
      // Автосохранение перед экспортом
      if (name.isNotEmpty) {
        await _saveLocal(silent: true);
      }
      
      // Сохраняем во временную папку для share
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(_contentController.text);
      
      // Открываем системный диалог
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'FutureClock App: $fileName',
      );
    } catch (e) {
      if (mounted) {
        _showNotification('Ошибка экспорта: $e', isError: true);
      }
    }
  }
  
  /// Обработка отправки с проверкой на вставленный код
  Future<void> _handleSend() async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    
    // Пробуем извлечь код через нашу умную функцию
    final extractedCode = _extractCode(text);
    
    if (extractedCode != null) {
      // Спрашиваем что делать
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('Обнаружен код', style: TextStyle(color: Colors.white)),
          content: Text(
            'Найден код приложения (${extractedCode.length} байт).\nЧто вы хотите сделать?',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'send'),
              child: const Text('Отправить как вопрос'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'apply'),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
              child: const Text('Вставить как код'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Отмена', style: TextStyle(color: Colors.white38)),
            ),
          ],
        ),
      );
      
      if (action == 'cancel' || action == null) return;
      
      if (action == 'apply') {
        _chatController.clear();
        _applyCode(extractedCode);
        return;
      }
      // action == 'send' - продолжаем как обычно
    }
    
    await _sendChatMessage();
  }
  
  Future<void> _sendChatMessage({String? autoFixMessage}) async {
    final text = autoFixMessage ?? _chatController.text.trim();
    if (text.isEmpty) return;
    
    // Сброс при ручном сообщении
    if (autoFixMessage == null) {
      _autoFixAttempts = 0;
      _sentWarnings.clear();  // Новый запрос — можем снова слать warnings
    }
    
    // Разворачиваем {filename} в содержимое файлов
    final expandedText = await _expandPromptResources(text);
    
    if (!mounted) return;
    setState(() {
      // Для автофикса сообщение уже добавлено
      if (autoFixMessage == null) {
        _messages.add(_ChatMessage(role: 'user', content: text));
        _chatController.clear();
      }
      _chatLoading = true;
      _loadingPhrase = '...';  // Сначала просто точки
    });
    
    // Через 1-3 сек показываем первую фразу
    _warmupTimer?.cancel();
    final warmupDelay = 1 + _random.nextInt(3); // 1-3 секунды
    _warmupTimer = Timer(Duration(seconds: warmupDelay), () {
      if (mounted && _chatLoading) {
        setState(() => _loadingPhrase = _loadingPhrases[_random.nextInt(_loadingPhrases.length)]);
      }
    });
    
    // Через 15-25 сек меняем фразу на "долгое ожидание"
    _longWaitTimer?.cancel();
    _warmupTimer?.cancel();
    final delay = 15 + _random.nextInt(11); // 15-25 секунд
    _longWaitTimer = Timer(Duration(seconds: delay), () {
      if (mounted && _chatLoading) {
        setState(() => _loadingPhrase = _longWaitPhrases[_random.nextInt(_longWaitPhrases.length)]);
      }
    });
    
    final ble = context.read<BleService>();
    final provider = ble.getActiveAiProvider();
    
    if (provider == null) {
      _longWaitTimer?.cancel();
      _warmupTimer?.cancel();
      setState(() {
        _messages.add(_ChatMessage(
          role: 'assistant', 
          content: 'Включите AI провайдера в настройках и добавьте API ключ.',
        ));
        _chatLoading = false;
      });
      return;
    }
    
    try {
      final currentCode = _contentController.text;
      final appName = _nameController.text.trim();
      
      // Загружаем промпты из файлов
      String systemPrompt;
      try {
        final system = await rootBundle.loadString('assets/prompts/system.md');
        final docs = await rootBundle.loadString('assets/prompts/documentation.md');
        systemPrompt = '$system\n\n$docs';
      } catch (e) {
        systemPrompt = 'Ты помогаешь создавать приложения. Код: <app os="1.0" title="Name">...</app>';
      }
      
      // Добавляем контекст
      final context = StringBuffer();
      context.writeln('\n## КОНТЕКСТ');
      context.writeln(currentCode.isEmpty 
          ? 'Задача: создать новое приложение по описанию.' 
          : 'Задача: модифицировать существующий код.');
      
      // Если пользователь задал имя — требуем использовать его как title
      if (appName.isNotEmpty && _nameManuallyEdited) {
        context.writeln('ВАЖНО: title="$appName" (имя задано пользователем, не менять!)');
      } else if (appName.isNotEmpty) {
        context.writeln('Имя: $appName');
      }
      
      if (currentCode.isNotEmpty) {
        context.writeln('\nТЕКУЩИЙ КОД:\n$currentCode');
      }
      systemPrompt = '$systemPrompt${context.toString()}';

      // Используем развёрнутый текст в сообщениях для AI
      final messagesForAi = _messages.map((m) {
        if (m == _messages.last && m.role == 'user') {
          return _ChatMessage(role: 'user', content: expandedText);
        }
        return m;
      }).toList();

      final response = await _callAiApi(provider, systemPrompt, messagesForAi);
      
      if (mounted) {
        _longWaitTimer?.cancel();
        _warmupTimer?.cancel();
        setState(() {
          _messages.add(_ChatMessage(role: 'assistant', content: response));
          _chatLoading = false;
        });
        
        // Если ответ содержит код - предложить применить
        final extractedCode = _extractCode(response);
        if (extractedCode != null) {
          _extractAndOfferCode(response);
        }
      }
    } catch (e) {
      if (mounted) {
        _longWaitTimer?.cancel();
        _warmupTimer?.cancel();
        setState(() {
          _messages.add(_ChatMessage(role: 'assistant', content: 'Ошибка: $e'));
          _chatLoading = false;
        });
      }
    }
  }
  
  /// Разворачивает {filename} в содержимое файлов из assets/prompts/
  Future<String> _expandPromptResources(String text) async {
    String result = text;
    
    // Ищем все {filename} паттерны
    final regex = RegExp(r'\{([a-zA-Z0-9_.-]+)\}');
    final matches = regex.allMatches(text).toList();
    
    for (final match in matches.reversed) {
      final filename = match.group(1)!;
      
      // Проверяем что это известный ресурс
      if (_promptResources.contains(filename)) {
        try {
          final content = await rootBundle.loadString('assets/prompts/$filename');
          result = result.replaceRange(match.start, match.end, content);
        } catch (e) {
          debugPrint('Не удалось загрузить ресурс $filename: $e');
        }
      }
    }
    
    return result;
  }
  
  Future<String> _callAiApi(Map<String, dynamic> provider, String system, List<_ChatMessage> messages) async {
    final providerName = provider['provider'] as String;
    final apiKey = provider['apiKey'] as String;
    final model = provider['model'] as String;
    
    if (apiKey.isEmpty) {
      throw Exception('API ключ не указан');
    }
    
    // Получаем прокси из BleService
    final ble = context.read<BleService>();
    final proxy = ble.aiProxy;
    
    // Создаём HTTP клиент (с прокси или без)
    final client = _createHttpClient(proxy);
    
    try {
      if (providerName == 'openai') {
        final response = await client.post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': system},
              ...messages.map((m) => {'role': m.role, 'content': m.content}),
            ],
            'max_completion_tokens': 32768,
          }),
        );
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          return data['choices'][0]['message']['content'] as String;
        } else {
          String errorMsg = 'OpenAI ${response.statusCode}';
          try {
            final body = jsonDecode(response.body);
            if (body['error'] != null && body['error']['message'] != null) {
              errorMsg = body['error']['message'];
            }
          } catch (_) {}
          throw Exception(errorMsg);
        }
      } else if (providerName == 'anthropic') {
        final response = await client.post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'max_tokens': 32768,
            'system': system,
            'messages': messages.map((m) => {'role': m.role, 'content': m.content}).toList(),
          }),
        );
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          return data['content'][0]['text'] as String;
        } else {
          String errorMsg = 'Anthropic ${response.statusCode}';
          try {
            final body = jsonDecode(response.body);
            if (body['error'] != null && body['error']['message'] != null) {
              errorMsg = body['error']['message'];
            }
          } catch (_) {}
          throw Exception(errorMsg);
        }
      }
      
      throw Exception('Unknown provider: $providerName');
    } finally {
      client.close();
    }
  }
  
  /// Создаёт HTTP клиент с поддержкой прокси
  /// Форматы: socks5://host:port, socks5://user:pass@host:port, http://host:port
  http.Client _createHttpClient(String proxy) {
    if (proxy.isEmpty) {
      return http.Client();
    }
    
    try {
      final uri = Uri.parse(proxy);
      final scheme = uri.scheme.toLowerCase();
      
      if (scheme == 'socks5' || scheme == 'socks') {
        // SOCKS5 прокси
        final host = uri.host;
        final port = uri.port != 0 ? uri.port : 1080;
        
        final client = HttpClient();
        
        // Авторизация если есть
        if (uri.userInfo.isNotEmpty) {
          final parts = uri.userInfo.split(':');
          final username = parts[0];
          final password = parts.length > 1 ? parts[1] : '';
          SocksTCPClient.assignToHttpClient(client, [
            ProxySettings(
              InternetAddress(host),
              port,
              username: username,
              password: password,
            ),
          ]);
        } else {
          SocksTCPClient.assignToHttpClient(client, [
            ProxySettings(InternetAddress(host), port),
          ]);
        }
        
        return IOClient(client);
      } else if (scheme == 'http' || scheme == 'https') {
        // HTTP прокси
        final client = HttpClient();
        client.findProxy = (url) => 'PROXY ${uri.host}:${uri.port}';
        
        // Авторизация если есть
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
      debugPrint('Ошибка парсинга прокси: $e');
    }
    
    // Fallback - без прокси
    return http.Client();
  }

  /// Извлекает title из кода <app title="...">
  String? _extractTitle(String code) {
    final regex = RegExp(r'<app[^>]+title\s*=\s*"([^"]+)"');
    final match = regex.firstMatch(code);
    return match?.group(1);
  }

  void _applyCode(String code) {
    setState(() {
      _contentController.text = code;
      _updateStats();
      _pendingCode = null;
      
      // Автоименовка: если имя не редактировалось вручную — берём из title
      if (!_nameManuallyEdited) {
        final title = _extractTitle(code);
        if (title != null && title.isNotEmpty) {
          _nameController.removeListener(_onNameChanged);
          _nameController.text = title.toLowerCase();
          _nameController.addListener(_onNameChanged);
        }
      }
    });
    _tabController.animateTo(0);
  }
  
  // Применить код напрямую (по клику на ссылку в старых сообщениях)
  void _extractAndApplyCode(String response) {
    final code = _extractCode(response);
    if (code != null) {
      _applyCode(code);
    }
  }
  
  // Применить код с подтверждением
  void _confirmAndApplyCode(String response) async {
    final code = _extractCode(response);
    if (code == null) return;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Применить версию?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Заменить текущий код на эту версию?\n(${code.length} байт)',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
            child: const Text('Применить'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена', style: TextStyle(color: Colors.white38)),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      _applyCode(code);
    }
  }
  
  /// Известные теги Evolution OS
  static const _knownTags = [
    '<ui', '<page', '<group', '<state', '<script', '<timer',
    '<label', '<button', '<input', '<slider', '<switch', '<canvas', '<image',
    '</ui>', '</page>', '</state>', '</script>',
  ];
  
  /// Проверяет что строка содержит минимум N известных тегов
  bool _hasKnownTags(String code, {int minCount = 2}) {
    int count = 0;
    for (final tag in _knownTags) {
      if (code.contains(tag)) {
        count++;
        if (count >= minCount) return true;
      }
    }
    return false;
  }
  
  /// Оборачивает код в <app> если его нет
  String _wrapInApp(String code) {
    if (code.contains('<app')) return code;
    return '<app os="1.0" title="App">\n$code\n</app>';
  }
  
  /// Извлекает код из ответа AI с цепочкой фоллбэков
  /// 
  /// Приоритет (два прохода - с требованием <app> и без):
  /// 1. XML блок ```xml ... ```
  /// 2. Любой блок кода ``` ... ```  
  /// 3. Всё сообщение целиком
  String? _extractCode(String response) {
    // === ПЕРВЫЙ ПРОХОД: требуем <app>...</app> ===
    
    // 1. XML блок с <app>
    final xmlBlockRegex = RegExp(r'```xml\s*\n?([\s\S]*?)```', multiLine: true);
    for (final match in xmlBlockRegex.allMatches(response)) {
      final content = match.group(1)?.trim() ?? '';
      if (content.contains('<app') && content.contains('</app>')) {
        final start = content.indexOf('<app');
        final end = content.lastIndexOf('</app>');
        if (start != -1 && end > start) {
          return content.substring(start, end + '</app>'.length);
        }
      }
    }
    
    // 2. Любой блок кода с <app>
    final anyBlockRegex = RegExp(r'```\w*\s*\n?([\s\S]*?)```', multiLine: true);
    for (final match in anyBlockRegex.allMatches(response)) {
      final content = match.group(1)?.trim() ?? '';
      if (content.contains('<app') && content.contains('</app>')) {
        final start = content.indexOf('<app');
        final end = content.lastIndexOf('</app>');
        if (start != -1 && end > start) {
          return content.substring(start, end + '</app>'.length);
        }
      }
    }
    
    // 3. Сообщение целиком с <app>
    if (response.contains('<app') && response.contains('</app>')) {
      final start = response.indexOf('<app');
      final end = response.lastIndexOf('</app>');
      if (start != -1 && end > start) {
        return response.substring(start, end + '</app>'.length);
      }
    }
    
    // === ВТОРОЙ ПРОХОД: без требования <app>, но с известными тегами ===
    
    // 1. XML блок с известными тегами
    for (final match in xmlBlockRegex.allMatches(response)) {
      final content = match.group(1)?.trim() ?? '';
      if (_hasKnownTags(content)) {
        return _wrapInApp(content);
      }
    }
    
    // 2. Любой блок кода с известными тегами
    for (final match in anyBlockRegex.allMatches(response)) {
      final content = match.group(1)?.trim() ?? '';
      if (_hasKnownTags(content)) {
        return _wrapInApp(content);
      }
    }
    
    // 3. Сообщение целиком с известными тегами (минимум 3 для надёжности)
    if (_hasKnownTags(response, minCount: 3)) {
      // Пытаемся найти границы кода по первому и последнему известному тегу
      int firstTag = response.length;
      int lastTag = 0;
      
      for (final tag in _knownTags) {
        final idx = response.indexOf(tag);
        if (idx != -1 && idx < firstTag) firstTag = idx;
        
        final lastIdx = response.lastIndexOf(tag);
        if (lastIdx != -1) {
          final endOfTag = response.indexOf('>', lastIdx);
          if (endOfTag != -1 && endOfTag > lastTag) lastTag = endOfTag + 1;
        }
      }
      
      // Ищем закрывающий тег после lastTag
      final closingTags = ['</app>', '</ui>', '</page>', '</state>', '</script>'];
      for (final ct in closingTags) {
        final idx = response.lastIndexOf(ct);
        if (idx != -1 && idx + ct.length > lastTag) {
          lastTag = idx + ct.length;
        }
      }
      
      if (firstTag < lastTag) {
        return _wrapInApp(response.substring(firstTag, lastTag).trim());
      }
    }
    
    return null;
  }
  
  /// Базовая валидация кода (без запуска)
  Map<String, dynamic> _validateCode(String code) {
    final errors = <String>[];
    final warnings = <String>[];
    
    if (code.trim().isEmpty) {
      errors.add('Код пустой');
      return {'valid': false, 'errors': errors, 'warnings': warnings};
    }
    
    // Базовая структура
    if (!code.contains('<app')) errors.add('Отсутствует тег <app>');
    if (!code.contains('<ui')) errors.add('Отсутствует секция <ui>');
    if (!code.contains('<page')) errors.add('Нет ни одной <page>');
    
    // Собираем state переменные
    final stateVars = <String>{};
    final stateRegex = RegExp(r'<(string|int|bool|float)\s+name="([^"]+)"');
    for (final match in stateRegex.allMatches(code)) {
      stateVars.add(match.group(2)!);
    }
    
    // Проверяем биндинги
    final bindingRegex = RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}');
    for (final match in bindingRegex.allMatches(code)) {
      final varName = match.group(1)!;
      if (!stateVars.contains(varName)) {
        warnings.add('{$varName} не в <state>');
      }
    }
    
    // Собираем обработчики
    final handlers = <String>{};
    final handlerRegex = RegExp(r'(onclick|onchange|onenter|onblur|call)="([^"]+)"');
    for (final match in handlerRegex.allMatches(code)) {
      handlers.add(match.group(2)!);
    }
    
    // Собираем функции
    final functions = <String>{};
    final funcRegex = RegExp(r'function\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\(');
    for (final match in funcRegex.allMatches(code)) {
      functions.add(match.group(1)!);
    }
    
    // Проверяем обработчики
    for (final handler in handlers) {
      if (!functions.contains(handler)) {
        errors.add('Функция "$handler" не найдена');
      }
    }
    
    // Проверяем баланс end
    final scriptMatch = RegExp(r'<script[^>]*>([\s\S]*?)</script>').firstMatch(code);
    if (scriptMatch != null) {
      final lua = scriptMatch.group(1)!;
      final clean = lua
          .replaceAll(RegExp(r'--\[\[[\s\S]*?\]\]'), '')
          .replaceAll(RegExp(r'--[^\n]*'), '')
          .replaceAll(RegExp(r'"[^"]*"'), '""')
          .replaceAll(RegExp(r"'[^']*'"), "''");
      
      final opens = RegExp(r'\b(function|if|for|while|repeat)\b').allMatches(clean).length;
      final closes = RegExp(r'\bend\b').allMatches(clean).length;
      final untils = RegExp(r'\buntil\b').allMatches(clean).length;
      final expected = opens - untils;
      
      if (closes < expected) errors.add('Не хватает ${expected - closes} "end"');
      else if (closes > expected) errors.add('Лишних ${closes - expected} "end"');
    }
    
    // Проверяем множественные label внутри button
    final buttonRegex = RegExp(r'<button[^>]*>([\s\S]*?)</button>', caseSensitive: false);
    for (final btnMatch in buttonRegex.allMatches(code)) {
      final btnContent = btnMatch.group(1) ?? '';
      final labelCount = RegExp(r'<label', caseSensitive: false).allMatches(btnContent).length;
      if (labelCount > 1) {
        // Попробуем найти id или onclick для идентификации
        final btnTag = code.substring(btnMatch.start, btnMatch.start + 100);
        final idMatch = RegExp(r'id="([^"]+)"').firstMatch(btnTag);
        final onclickMatch = RegExp(r'onclick="([^"]+)"').firstMatch(btnTag);
        final btnId = idMatch?.group(1) ?? onclickMatch?.group(1) ?? 'button';
        warnings.add('<button $btnId> содержит $labelCount вложенных <label> — только первый будет использован');
      }
    }
    
    // === ВИЗУАЛЬНАЯ ВАЛИДАЦИЯ (мягкие warnings) ===
    _validateLayout(code, warnings);
    
    return {'valid': errors.isEmpty, 'errors': errors, 'warnings': warnings};
  }
  
  /// Визуальная валидация: проверяет что элементы влезают в экран
  void _validateLayout(String code, List<String> warnings) {
    const screenW = 480;
    const screenH = 480;
    
    // Парсим элементы с позициями
    final elements = <_LayoutElement>[];
    final elementRegex = RegExp(
      r'<(label|button|input|slider|switch|image|canvas)\s+([^>]*)>([^<]*)',
      caseSensitive: false,
    );
    
    for (final match in elementRegex.allMatches(code)) {
      final tag = match.group(1)!.toLowerCase();
      final attrs = match.group(2)!;
      final content = match.group(3)?.trim() ?? '';
      
      final id = _extractAttr(attrs, 'id') ?? tag;
      final x = _parsePosition(attrs, 'x', screenW);
      final y = _parsePosition(attrs, 'y', screenH);
      final w = _parsePosition(attrs, 'w', screenW) ?? _defaultWidth(tag);
      final h = _parsePosition(attrs, 'h', screenH) ?? _defaultHeight(tag);
      final overflow = _extractAttr(attrs, 'overflow');
      
      if (x != null && y != null) {
        elements.add(_LayoutElement(id: id, tag: tag, x: x, y: y, w: w, h: h, text: content, overflow: overflow));
      }
    }
    
    // Проверяем выход за границы
    for (final el in elements) {
      if (el.x + el.w > screenW) {
        warnings.add('${el.id}: выходит за правый край (x=${el.x}, w=${el.w})');
      }
      if (el.y + el.h > screenH) {
        warnings.add('${el.id}: выходит за нижний край (y=${el.y}, h=${el.h})');
      }
    }
    
    // Проверяем пересечения (только значительные, >30% площади)
    for (var i = 0; i < elements.length; i++) {
      for (var j = i + 1; j < elements.length; j++) {
        final a = elements[i];
        final b = elements[j];
        final overlap = _getOverlap(a, b);
        final minArea = (a.w * a.h < b.w * b.h) ? a.w * a.h : b.w * b.h;
        if (overlap > minArea * 0.3) {
          warnings.add('${a.id} и ${b.id}: значительное перекрытие');
        }
      }
    }
    
    // Проверяем длину текста (только если нет overflow обработки)
    for (final el in elements) {
      if (el.text.isNotEmpty && (el.tag == 'label' || el.tag == 'button')) {
        // Пропускаем если overflow явно задан (ellipsis/clip/scroll)
        if (el.overflow != null && el.overflow != 'wrap') continue;
        
        // Примерная оценка: ~8px на символ при font 16
        final font = _extractFontSize(code, el.id);
        final charWidth = font * 0.5;  // примерно
        final textWidth = el.text.length * charWidth;
        if (textWidth > el.w * 1.2) {  // 20% допуск
          warnings.add('${el.id}: текст "${_truncate(el.text, 15)}" может не влезть (добавь overflow="ellipsis" или увеличь w)');
        }
      }
    }
  }
  
  String? _extractAttr(String attrs, String name) {
    final match = RegExp('$name="([^"]*)"').firstMatch(attrs);
    return match?.group(1);
  }
  
  int? _parsePosition(String attrs, String name, int base) {
    final val = _extractAttr(attrs, name);
    if (val == null) return null;
    if (val.endsWith('%')) {
      final percent = int.tryParse(val.replaceAll('%', ''));
      if (percent != null) return (base * percent / 100).round();
    }
    return int.tryParse(val);
  }
  
  int _defaultWidth(String tag) {
    switch (tag) {
      case 'button': return 100;
      case 'label': return 200;
      case 'input': return 200;
      case 'slider': return 200;
      case 'switch': return 50;
      default: return 100;
    }
  }
  
  int _defaultHeight(String tag) {
    switch (tag) {
      case 'button': return 40;
      case 'label': return 24;
      case 'input': return 40;
      case 'slider': return 30;
      case 'switch': return 30;
      default: return 40;
    }
  }
  
  int _getOverlap(_LayoutElement a, _LayoutElement b) {
    final xOverlap = (a.x + a.w > b.x && b.x + b.w > a.x)
        ? ((a.x + a.w < b.x + b.w ? a.x + a.w : b.x + b.w) - (a.x > b.x ? a.x : b.x))
        : 0;
    final yOverlap = (a.y + a.h > b.y && b.y + b.h > a.y)
        ? ((a.y + a.h < b.y + b.h ? a.y + a.h : b.y + b.h) - (a.y > b.y ? a.y : b.y))
        : 0;
    return xOverlap > 0 && yOverlap > 0 ? xOverlap * yOverlap : 0;
  }
  
  int _extractFontSize(String code, String id) {
    // Ищем font="N" в элементе
    final match = RegExp('id="$id"[^>]*font="(\\d+)"').firstMatch(code);
    return match != null ? int.parse(match.group(1)!) : 16;
  }
  
  String _truncate(String s, int max) => s.length > max ? '${s.substring(0, max)}...' : s;
  
  void _extractAndOfferCode(String response) {
    final code = _extractCode(response);
    
    if (code != null) {
      setState(() => _pendingCode = code);
      // Фоновая валидация через HTTP
      _validateInBackground(code);
    }
  }
  
  /// Фоновая валидация: загружаем код на сервер, ждём, проверяем console
  Future<void> _validateInBackground(String code) async {
    // Сначала базовая проверка
    final basicValidation = _validateCode(code);
    final basicErrors = basicValidation['errors'] as List<String>;
    
    if (basicErrors.isNotEmpty) {
      // Базовые ошибки — автофикс
      if (_autoFixAttempts < kMaxAutoFixAttempts) {
        _autoFixAttempts++;
        _requestAutoFix(basicErrors);
      } else {
        _autoFixAttempts = 0;
        _applyCode(code);
        _showNotification('Не удалось исправить за $kMaxAutoFixAttempts попыток', isError: true);
      }
      return;
    }
    
    // Базовые проверки прошли — пробуем запустить
    try {
      final server = LocalServer();
      final port = server.port;
      
      // Очищаем console
      await http.delete(Uri.parse('http://127.0.0.1:$port/console'));
      
      // Загружаем код
      await http.post(
        Uri.parse('http://127.0.0.1:$port/app'),
        headers: {'Content-Type': 'text/plain'},
        body: code,
      );
      
      // Ждём выполнения (достаточно для tick())
      await Future.delayed(const Duration(milliseconds: 1500));
      
      // Проверяем console на ошибки
      final consoleResp = await http.get(Uri.parse('http://127.0.0.1:$port/console'));
      if (consoleResp.statusCode == 200) {
        final data = jsonDecode(consoleResp.body);
        final logs = data['logs'] as List? ?? [];
        
        // Ищем ошибки
        final runtimeErrors = <String>[];
        for (final log in logs) {
          if (log['type'] == 'error') {
            runtimeErrors.add(log['msg'] as String);
          }
        }
        
        if (runtimeErrors.isNotEmpty && mounted) {
          // Runtime ошибки — автофикс
          if (_autoFixAttempts < kMaxAutoFixAttempts) {
            _autoFixAttempts++;
            _requestAutoFix(runtimeErrors);
          } else {
            _autoFixAttempts = 0;
            _applyCode(code);
            _showNotification('Не удалось исправить за $kMaxAutoFixAttempts попыток', isError: true);
          }
          return;
        }
      }
      
      // Всё ок — проверяем визуальные warnings
      final basicWarnings = basicValidation['warnings'] as List<String>;
      if (basicWarnings.isNotEmpty && mounted) {
        _sendLayoutWarnings(basicWarnings);
      }
      
      // Показываем popup
      if (mounted) {
        _autoFixAttempts = 0;
        _showPopup(code);
      }
    } catch (e) {
      // Ошибка HTTP — не смогли проверить через сервер, 
      // но базовая валидация прошла, показываем popup
      debugPrint('[VALIDATE] HTTP error: $e');
      final basicWarnings = basicValidation['warnings'] as List<String>;
      if (basicWarnings.isNotEmpty && mounted) {
        _sendLayoutWarnings(basicWarnings);
      }
      // Показываем popup только если ещё не показан
      if (mounted && _pendingCode == code) {
        _autoFixAttempts = 0;
        _showPopup(code);
      }
    }
  }
  
  /// Мягкое сообщение о визуальных предупреждениях (только новые)
  void _sendLayoutWarnings(List<String> warnings) {
    // Фильтруем уже отправленные
    final newWarnings = warnings.where((w) => !_sentWarnings.contains(w)).toList();
    if (newWarnings.isEmpty) return;
    
    // Запоминаем отправленные
    _sentWarnings.addAll(newWarnings);
    
    final warningList = newWarnings.take(5).map((e) => '• $e').join('\n');
    final message = '⚠️ Проверь вёрстку:\n$warningList\n\nЕсли это сделано специально — ок. Иначе поправь.';
    
    setState(() {
      _messages.add(_ChatMessage(role: 'user', content: message));
    });
    
    // Отправляем AI
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _sendChatMessage(autoFixMessage: message);
    });
  }
  
  /// Запрос автофикса
  void _requestAutoFix(List<String> errors) {
    final errorList = errors.take(5).map((e) => '• $e').join('\n');
    final message = '🔴 Код не принят (попытка $_autoFixAttempts/$kMaxAutoFixAttempts):\n$errorList\n\nРешение должно быть идеальным — исправь ВСЕ ошибки. Частичные решения не засчитываются.';
    
    setState(() {
      _messages.add(_ChatMessage(role: 'user', content: message));
    });
    
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _sendChatMessage(autoFixMessage: message);
    });
  }
  
  // Popup state
  bool _popupVisible = false;
  String? _successCode;
  
  void _showPopup(String code) {
    setState(() {
      _successCode = code;
      _popupVisible = true;
    });
  }
  
  void _hidePopup() {
    setState(() {
      _popupVisible = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isNew
        ? 'Новое приложение'
        : widget.appName;
    
    final ble = context.watch<BleService>();
    final connected = ble.isConnected;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmExit() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title, style: const TextStyle(fontSize: 16)),
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _confirmExit() && context.mounted) Navigator.pop(context);
            },
          ),
          actions: [
            // Run in emulator
            IconButton(
              onPressed: _contentController.text.isNotEmpty 
                  ? () => _runInEmulator() 
                  : null,
              icon: const Icon(Icons.play_arrow_rounded, size: 22),
              color: const Color(0xFF22C55E),
              tooltip: 'Запустить в эмуляторе',
            ),
            // Push на часы (загрузка на устройство)
            IconButton(
              onPressed: connected && !_pushing ? _push : null,
              icon: _pushing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFF3B82F6)),
                    )
                  : Icon(Icons.watch, size: 20, 
                      color: connected ? null : Colors.white24),
              color: const Color(0xFF3B82F6),
              tooltip: connected ? 'На устройство' : 'Нет подключения',
            ),
            // Export / Поделиться
            IconButton(
              onPressed: _contentController.text.isNotEmpty ? _exportCode : null,
              icon: const Icon(Icons.upload, size: 22),
              tooltip: 'Экспорт',
            ),
            const SizedBox(width: 4),
          ],
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(icon: Icon(Icons.code, size: 18), text: 'Код'),
            Tab(icon: Icon(Icons.rocket_launch, size: 18), text: 'ИИ'),
          ],
          indicatorColor: const Color(0xFF3B82F6),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white38,
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabController,
            children: [
              // Tab 1: Code Editor
              _buildCodeEditor(),
              // Tab 2: AI Chat
              _buildAiChat(),
            ],
          ),
          // Success popup overlay
          if (_popupVisible)
            _buildSuccessPopup(),
        ],
      ),
      ),
    );
  }
  
  Widget _buildSuccessPopup() {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(32),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 24),
                  SizedBox(width: 12),
                  Text('Готово!', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Код готов (${_successCode?.length ?? 0} байт)',
                style: TextStyle(color: Colors.white.withOpacity(0.7)),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton(
                    onPressed: () {
                      final c = _successCode;
                      _hidePopup();
                      if (c != null) {
                        _applyCode(c);
                        _runInEmulator(codeOverride: c);
                      }
                    },
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
                    child: const Text('Запустить'),
                  ),
                  FilledButton(
                    onPressed: () {
                      final c = _successCode;
                      _hidePopup();
                      if (c != null) _applyCode(c);
                    },
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF3B82F6)),
                    child: const Text('Применить'),
                  ),
                  TextButton(
                    onPressed: () {
                      _hidePopup();
                      setState(() => _pendingCode = null);
                    },
                    child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildCodeEditor() {
    final name = _nameController.text.trim();
    final autoPath = name.isEmpty ? '' : _appFilePath(name);
    
    return Column(
      children: [
        // App name + auto path
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: Colors.white.withOpacity(0.02),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameController,
                  enabled: widget.isNew,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Имя',
                    labelStyle:
                        TextStyle(color: Colors.white.withOpacity(0.3)),
                    isDense: true,
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => setState(() {}), // Обновить autoPath
                ),
              ),
              if (autoPath.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text('→  $autoPath',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.3), fontSize: 12)),
              ],
            ],
          ),
        ),

        if (_error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            color: const Color(0xFFEF4444).withOpacity(0.1),
            child: Text(_error!,
                style: const TextStyle(
                    color: Color(0xFFEF4444), fontSize: 13)),
          ),

        // Stats bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          color: Colors.white.withOpacity(0.01),
          child: Row(
            children: [
              Text('$_bytes bytes',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.2), fontSize: 11)),
              const Spacer(),
              Text('$_lines lines',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.2), fontSize: 11)),
            ],
          ),
        ),

        // Code editor with syntax highlighting
        Expanded(
          child: Container(
            color: const Color(0xFF0D1117),
            child: TextField(
              controller: _contentController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(
                color: Color(0xFFD1D5DB),
                fontSize: 13,
                fontFamily: 'monospace',
                height: 1.5,
              ),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.all(16),
                border: InputBorder.none,
                hintText: '<app>\n  ...\n</app>',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.1)),
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _updateStats();
              }),
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildAiChat() {
    final ble = context.watch<BleService>();
    final hasProvider = ble.getActiveAiProvider() != null;
    
    return Column(
      children: [
        // Статус провайдера
        if (!hasProvider)
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFFF59E0B).withOpacity(0.1),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, color: Color(0xFFF59E0B), size: 20),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Включите AI провайдера в настройках',
                    style: TextStyle(color: Color(0xFFF59E0B), fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        
        // Сообщения
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.rocket_launch, 
                          size: 48, color: Colors.white.withOpacity(0.1)),
                      const SizedBox(height: 16),
                      Text(
                        'Опишите что хотите создать',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.3),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Используйте 📎 для примеров',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.2),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _chatScrollController,
                  reverse: true, // Новые сообщения внизу автоматически
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length + (_chatLoading ? 1 : 0),
                  itemBuilder: (context, index) {
                    // При reverse=true index 0 это низ списка
                    if (_chatLoading && index == 0) {
                      // Loading indicator внизу
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 12),
                            Text(_loadingPhrase, 
                                style: const TextStyle(color: Colors.white38)),
                          ],
                        ),
                      );
                    }
                    
                    // Индекс сообщения (инвертированный для reverse)
                    final msgIndex = _chatLoading 
                        ? _messages.length - index 
                        : _messages.length - 1 - index;
                    final msg = _messages[msgIndex];
                    final isUser = msg.role == 'user';
                    
                    // Проверяем есть ли код в сообщении
                    final hasCode = !isUser && _extractCode(msg.content) != null;
                    
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: isUser 
                                  ? const Color(0xFF3B82F6).withOpacity(0.2)
                                  : const Color(0xFF22C55E).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              isUser ? Icons.person : Icons.rocket_launch,
                              size: 16,
                              color: isUser 
                                  ? const Color(0xFF3B82F6) 
                                  : const Color(0xFF22C55E),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.03),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: SelectableText(
                                    msg.content,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.8),
                                      fontSize: 13,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                                // Иконки под сообщением
                                Padding(
                                  padding: const EdgeInsets.only(top: 6, left: 0),
                                  child: Row(
                                    children: [
                                      // Copy
                                      GestureDetector(
                                        onTap: () {
                                          Clipboard.setData(ClipboardData(text: msg.content));
                                          _showNotification('Скопировано');
                                        },
                                        child: Icon(
                                          Icons.copy_outlined,
                                          size: 14,
                                          color: Colors.white.withOpacity(0.25),
                                        ),
                                      ),
                                      // Apply code (только если есть код)
                                      if (hasCode) ...[
                                        const SizedBox(width: 12),
                                        GestureDetector(
                                          onTap: () => _confirmAndApplyCode(msg.content),
                                          child: Icon(
                                            Icons.check_circle_outline,
                                            size: 14,
                                            color: const Color(0xFF3B82F6).withOpacity(0.6),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        
        // Input
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.02),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.05)),
            ),
          ),
          child: Row(
            children: [
              // Кнопка ресурсов
              IconButton(
                onPressed: () => _showResourcesDialog(),
                icon: const Icon(Icons.attach_file),
                color: Colors.white38,
                tooltip: 'Вставить ресурс',
              ),
              Expanded(
                child: TextField(
                  controller: _chatController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: 'Опишите приложение...',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Микрофон / Стоп
              IconButton(
                onPressed: _chatLoading ? null : _toggleListening,
                icon: Icon(_isListening ? Icons.stop_rounded : Icons.mic_none),
                color: _isListening ? const Color(0xFFEF4444) : Colors.white38,
                tooltip: _isListening ? 'Остановить' : 'Голосовой ввод',
              ),
              // Отправить
              IconButton(
                onPressed: _chatLoading ? null : _handleSend,
                icon: const Icon(Icons.send),
                color: const Color(0xFF3B82F6),
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  void _showResourcesDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ресурсы для промптов',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Используйте {filename} чтобы вставить содержимое в промпт',
              style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _promptResources.map((resource) {
                final isRules = resource.endsWith('.md');
                return ActionChip(
                  avatar: Icon(
                    isRules ? Icons.description : Icons.code,
                    size: 16,
                    color: isRules ? const Color(0xFF3B82F6) : const Color(0xFF22C55E),
                  ),
                  label: Text(resource),
                  labelStyle: const TextStyle(color: Colors.white70, fontSize: 12),
                  backgroundColor: Colors.white.withOpacity(0.05),
                  side: BorderSide.none,
                  onPressed: () {
                    Navigator.pop(context);
                    final current = _chatController.text;
                    final insertion = '{$resource}';
                    _chatController.text = current.isEmpty 
                        ? insertion 
                        : '$current $insertion';
                    _chatController.selection = TextSelection.collapsed(
                      offset: _chatController.text.length,
                    );
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Text(
              'Примеры:\n'
              '• "Сделай калькулятор как {calc.xml}"\n'
              '• "Напиши таймер. Правила: {rules.md}"',
              style: TextStyle(
                color: Colors.white.withOpacity(0.3),
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Layout element for visual validation
class _LayoutElement {
  final String id;
  final String tag;
  final int x, y, w, h;
  final String text;
  final String? overflow;
  
  _LayoutElement({
    required this.id,
    required this.tag,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.text = '',
    this.overflow,
  });
}

// Chat message model
class _ChatMessage {
  final String role; // 'user' or 'assistant'
  final String content;
  
  _ChatMessage({required this.role, required this.content});
}
