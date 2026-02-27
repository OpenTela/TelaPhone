import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import '../services/ble_service.dart';

class ScreenshotScreen extends StatefulWidget {
  const ScreenshotScreen({super.key});

  @override
  State<ScreenshotScreen> createState() => _ScreenshotScreenState();
}

class _ScreenshotScreenState extends State<ScreenshotScreen> {
  ui.Image? _displayImage;
  Uint8List? _pngBytes;
  bool _converting = false;
  String? _savedPath;
  bool _useTiny = false;
  String _colorFormat = 'rgb8';
  
  // Streaming
  bool _streaming = false;
  Timer? _streamTimer;
  int _frameCount = 0;
  DateTime? _streamStart;

  static const _colorFormats = {
    'auto': 'Auto',
    'rgb16': 'RGB16',
    'rgb8': 'RGB8',
    'gray': 'Gray',
    'bw': 'B/W',
  };

  @override
  void dispose() {
    _stopStreaming();
    super.dispose();
  }

  void _startStreaming(BleService ble) {
    if (_streaming) return;
    
    setState(() {
      _streaming = true;
      _frameCount = 0;
      _streamStart = DateTime.now();
    });
    
    _requestFrame(ble);
  }

  void _stopStreaming() {
    _streamTimer?.cancel();
    _streamTimer = null;
    if (mounted) setState(() => _streaming = false);
  }

  void _requestFrame(BleService ble) {
    if (_streaming && !ble.isConnected) {
      _stopStreaming();
      return;
    }
    
    // В режиме фото обнуляем картинку, в режиме видео - нет
    if (!_streaming) {
      _displayImage = null;
      _pngBytes = null;
      _savedPath = null;
    }
    
    ble.lastScreenshotData = null;
    ble.requestScreenshot(
      scale: _useTiny ? -1 : 0,
      color: _colorFormat == 'auto' ? 'pal' : _colorFormat,
    );
  }

  void _onFrameReceived(BleService ble) {
    if (!_streaming) return;
    
    _frameCount++;
    
    _streamTimer?.cancel();
    _streamTimer = Timer(const Duration(milliseconds: 50), () {
      if (_streaming && mounted && ble.isConnected) {
        _requestFrame(ble);
      }
    });
  }

  String get _fps {
    if (_streamStart == null || _frameCount == 0) return '0';
    final elapsed = DateTime.now().difference(_streamStart!).inMilliseconds;
    if (elapsed == 0) return '0';
    return (_frameCount * 1000 / elapsed).toStringAsFixed(1);
  }

  // Swipe tracking
  Offset? _panStart;
  DateTime? _panStartTime;
  Offset? _panEnd;
  bool _touchEnabled = true;  // Включение/выключение передачи нажатий
  static const _swipeThreshold = 20.0;  // Минимальное расстояние для swipe
  
  Future<void> _sendTap(BleService ble, Offset position, Size imageSize) async {
    if (!ble.isConnected || !_touchEnabled) return;
    
    final scaleX = ble.screenshotWidth / imageSize.width;
    final scaleY = ble.screenshotHeight / imageSize.height;
    
    final x = (position.dx * scaleX).round().clamp(0, ble.screenshotWidth - 1);
    final y = (position.dy * scaleY).round().clamp(0, ble.screenshotHeight - 1);
    
    debugPrint('[TAP] Sending tap at ($x, $y)');
    
    await ble.sendCommand('ui', 'tap', [x.toString(), y.toString()]);
    
    // Автообновление только в режиме фото
    if (!_streaming) {
      _requestUpdateDelayed();
    }
  }
  
  Future<void> _sendSwipe(BleService ble, Offset start, Offset end, Size imageSize) async {
    if (!ble.isConnected || !_touchEnabled) return;
    
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    
    // Определяем направление по большей компоненте
    String direction;
    if (dx.abs() > dy.abs()) {
      direction = dx > 0 ? 'right' : 'left';
    } else {
      direction = dy > 0 ? 'up' : 'down';
    }
    
    debugPrint('[SWIPE] direction: $direction (dx=$dx, dy=$dy)');
    
    await ble.sendCommand('ui', 'swipe', [direction]);
    
    // Автообновление только в режиме фото
    if (!_streaming) {
      _requestUpdateDelayed();
    }
  }
  
  Future<void> _sendSwipeDirection(BleService ble, String direction) async {
    if (!ble.isConnected) return;
    debugPrint('[NAV] Swipe $direction');
    await ble.sendCommand('ui', 'swipe', [direction]);
    if (!_streaming) {
      _requestUpdateDelayed();
    }
  }

  Future<void> _closeApp(BleService ble) async {
    if (!ble.isConnected) return;
    debugPrint('[NAV] Close app');
    await ble.sendCommand('app', 'home', []);
    if (!_streaming) {
      _requestUpdateDelayed();
    }
  }
  
  bool _updatePending = false;
  
  void _requestUpdateDelayed() {
    if (!mounted || _updatePending) return;
    _updatePending = true;
    
    Future.delayed(const Duration(milliseconds: 400), () {
      _updatePending = false;
      if (mounted && !_streaming) {
        final bleService = context.read<BleService>();
        if (!bleService.screenshotInProgress) {
          _displayImage = null;
          bleService.lastScreenshotData = null;
          bleService.requestScreenshot(
            scale: _useTiny ? -1 : 0,
            color: _colorFormat == 'auto' ? 'pal' : _colorFormat,
          );
        }
      }
    });
  }

  Future<void> _convertScreenshot(BleService ble) async {
    final rawData = ble.lastScreenshotData;
    if (rawData == null) return;
    
    ble.lastScreenshotData = null;
    
    final width = ble.screenshotWidth;
    final height = ble.screenshotHeight;
    final color = ble.screenshotColorFormat;

    setState(() => _converting = true);

    try {
      final pixels = Uint8List(width * height * 4);
      int pi = 0;

      if (color == 'pal') {
        if (rawData.isEmpty) throw Exception('Empty pal data');
        final paletteCount = rawData[0];
        final paletteStart = 1;
        final paletteEnd = paletteStart + paletteCount * 2;
        
        if (rawData.length < paletteEnd) throw Exception('Invalid pal data');
        
        final palette = <int>[];
        for (int i = paletteStart; i < paletteEnd; i += 2) {
          palette.add(rawData[i] | (rawData[i + 1] << 8));
        }
        
        final bitsPerPixel = paletteCount <= 16 ? 4 : 8;
        final dataStart = paletteEnd;
        
        if (bitsPerPixel == 4) {
          for (int i = dataStart; i < rawData.length && pi < pixels.length; i++) {
            final byte = rawData[i];
            for (int nibble = 0; nibble < 2 && pi < pixels.length; nibble++) {
              final idx = nibble == 0 ? (byte >> 4) & 0x0F : byte & 0x0F;
              if (idx < palette.length) {
                final c = palette[idx];
                final r = ((c >> 11) & 0x1F) * 255 ~/ 31;
                final g = ((c >> 5) & 0x3F) * 255 ~/ 63;
                final b = (c & 0x1F) * 255 ~/ 31;
                pixels[pi++] = r;
                pixels[pi++] = g;
                pixels[pi++] = b;
                pixels[pi++] = 255;
              } else {
                pi += 4;
              }
            }
          }
        } else {
          for (int i = dataStart; i < rawData.length && pi < pixels.length; i++) {
            final idx = rawData[i];
            if (idx < palette.length) {
              final c = palette[idx];
              final r = ((c >> 11) & 0x1F) * 255 ~/ 31;
              final g = ((c >> 5) & 0x3F) * 255 ~/ 63;
              final b = (c & 0x1F) * 255 ~/ 31;
              pixels[pi++] = r;
              pixels[pi++] = g;
              pixels[pi++] = b;
              pixels[pi++] = 255;
            } else {
              pi += 4;
            }
          }
        }
      } else if (color == 'rgb16') {
        for (int i = 0; i < rawData.length - 1 && pi < pixels.length; i += 2) {
          final c = rawData[i] | (rawData[i + 1] << 8);
          pixels[pi++] = ((c >> 11) & 0x1F) * 255 ~/ 31;
          pixels[pi++] = ((c >> 5) & 0x3F) * 255 ~/ 63;
          pixels[pi++] = (c & 0x1F) * 255 ~/ 31;
          pixels[pi++] = 255;
        }
      } else if (color == 'rgb8') {
        for (int i = 0; i < rawData.length && pi < pixels.length; i++) {
          final c = rawData[i];
          pixels[pi++] = ((c >> 5) & 0x07) * 255 ~/ 7;
          pixels[pi++] = ((c >> 2) & 0x07) * 255 ~/ 7;
          pixels[pi++] = (c & 0x03) * 255 ~/ 3;
          pixels[pi++] = 255;
        }
      } else if (color == 'gray') {
        for (int i = 0; i < rawData.length && pi < pixels.length; i++) {
          final g = rawData[i];
          pixels[pi++] = g;
          pixels[pi++] = g;
          pixels[pi++] = g;
          pixels[pi++] = 255;
        }
      } else if (color == 'bw') {
        for (int i = 0; i < rawData.length && pi < pixels.length; i++) {
          for (int bit = 7; bit >= 0 && pi < pixels.length; bit--) {
            final v = ((rawData[i] >> bit) & 1) == 1 ? 255 : 0;
            pixels[pi++] = v;
            pixels[pi++] = v;
            pixels[pi++] = v;
            pixels[pi++] = 255;
          }
        }
      }

      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels, width, height, ui.PixelFormat.rgba8888,
        (img) => completer.complete(img),
      );
      _displayImage = await completer.future;

      final byteData = await _displayImage!.toByteData(
        format: ui.ImageByteFormat.png,
      );
      _pngBytes = byteData?.buffer.asUint8List();

      if (!mounted) return;
      setState(() {
        _converting = false;
        _savedPath = null;
      });
      
      if (_streaming && mounted) {
        _onFrameReceived(context.read<BleService>());
      }
    } catch (e) {
      if (mounted) setState(() => _converting = false);
      debugPrint('Convert error: $e');
    }
  }

  Future<void> _saveScreenshot() async {
    if (_pngBytes == null) return;

    try {
      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/screenshot_$timestamp.png');
      await file.writeAsBytes(_pngBytes!);

      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Screenshot from FutureClock',
      );

      if (mounted) setState(() => _savedPath = file.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BleService>(
      builder: (context, ble, _) {
        final enabled = ble.isConnected;
        final inProgress = ble.screenshotInProgress;
        final progress = ble.screenshotTotal > 0
            ? ble.screenshotProgress / ble.screenshotTotal
            : 0.0;

        // Когда пришли новые данные
        if (ble.lastScreenshotData != null && !_converting) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _convertScreenshot(ble);
          });
        }

        return Scaffold(
          backgroundColor: const Color(0xFF0a0a0a),
          appBar: AppBar(
            title: Row(
              children: [
                const Text('Трансляция'),
                if (_streaming) ...[
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF22C55E),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.fiber_manual_record, size: 8, color: Colors.white),
                        const SizedBox(width: 4),
                        Text('$_fps fps', style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            backgroundColor: Colors.transparent,
            elevation: 0,
            actions: [
              if (_displayImage != null && !_streaming)
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: _saveScreenshot,
                  tooltip: 'Сохранить',
                ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // Фиксированная область для изображения (квадрат)
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1.0, // Квадрат
                        child: _buildDisplay(ble, enabled, inProgress, progress),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Progress bar (только при загрузке фото, не видео)
                  if (inProgress && !_streaming)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress > 0 ? progress : null,
                          minHeight: 4,
                          backgroundColor: Colors.white.withOpacity(0.1),
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF3B82F6)),
                        ),
                      ),
                    ),

                  // Controls row
                  Row(
                    children: [
                      // Tiny mode toggle
                      GestureDetector(
                        onTap: enabled && !inProgress && !_streaming
                            ? () {
                                final newTiny = !_useTiny;
                                setState(() => _useTiny = newTiny);
                                ble.requestScreenshot(
                                  scale: newTiny ? -1 : 0,
                                  color: _colorFormat == 'auto' ? 'pal' : _colorFormat,
                                );
                              }
                            : null,
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: _useTiny
                                ? Colors.orange.withOpacity(0.3)
                                : Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _useTiny
                                  ? Colors.orange
                                  : Colors.white.withOpacity(0.1),
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.compress,
                                  size: 18,
                                  color: _useTiny ? Colors.orange : Colors.white38),
                              const SizedBox(height: 2),
                              Text('tiny',
                                  style: TextStyle(
                                      fontSize: 9,
                                      color: _useTiny ? Colors.orange : Colors.white24)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Photo button
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: enabled && !inProgress && !_converting && !_streaming
                              ? () {
                                  _displayImage = null;
                                  ble.lastScreenshotData = null;
                                  ble.requestScreenshot(
                                    scale: _useTiny ? -1 : 0,
                                    color: _colorFormat == 'auto' ? 'pal' : _colorFormat,
                                  );
                                }
                              : null,
                          icon: Icon(
                            inProgress && !_streaming
                                ? Icons.hourglass_top 
                                : Icons.camera_alt,
                          ),
                          label: Text(
                            inProgress && !_streaming ? '...' : 'Фото',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF3B82F6),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      // const SizedBox(width: 8),

                      // Video button - скрыта, код оставлен
                      // Expanded(
                      //   child: _streaming
                      //       ? FilledButton.icon(
                      //           onPressed: _stopStreaming,
                      //           icon: const Icon(Icons.stop),
                      //           label: const Text('Стоп'),
                      //           style: FilledButton.styleFrom(
                      //             backgroundColor: Colors.red,
                      //             padding: const EdgeInsets.symmetric(vertical: 14),
                      //             shape: RoundedRectangleBorder(
                      //               borderRadius: BorderRadius.circular(12),
                      //             ),
                      //           ),
                      //         )
                      //       : FilledButton.icon(
                      //           onPressed: enabled && !inProgress && !_converting
                      //               ? () => _startStreaming(ble)
                      //               : null,
                      //           icon: const Icon(Icons.videocam),
                      //           label: const Text('Видео'),
                      //           style: FilledButton.styleFrom(
                      //             backgroundColor: const Color(0xFF22C55E),
                      //             padding: const EdgeInsets.symmetric(vertical: 14),
                      //             shape: RoundedRectangleBorder(
                      //               borderRadius: BorderRadius.circular(12),
                      //             ),
                      //           ),
                      //         ),
                      // ),
                      const SizedBox(width: 8),

                      // Color format selector
                      PopupMenuButton<String>(
                        key: const ValueKey('color_format_menu'),
                        enabled: enabled && !inProgress && !_streaming,
                        onSelected: (value) {
                          setState(() => _colorFormat = value);
                          ble.requestScreenshot(
                            scale: _useTiny ? -1 : 0,
                            color: value == 'auto' ? 'pal' : value,
                          );
                        },
                        itemBuilder: (context) => _colorFormats.entries
                            .map((e) => PopupMenuItem<String>(
                                  value: e.key,
                                  child: Row(
                                    children: [
                                      if (_colorFormat == e.key)
                                        const Icon(Icons.check, size: 16, color: Colors.green)
                                      else
                                        const SizedBox(width: 16),
                                      const SizedBox(width: 8),
                                      Text(e.value),
                                    ],
                                  ),
                                ))
                            .toList(),
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.1),
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.palette_outlined,
                                  size: 18,
                                  color: enabled && !_streaming ? Colors.white : Colors.white38),
                              const SizedBox(height: 2),
                              Text(_colorFormats[_colorFormat] ?? 'Auto',
                                  style: TextStyle(
                                      fontSize: 9,
                                      color: enabled && !_streaming ? Colors.white70 : Colors.white24)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Панель навигации
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        // Toggle touch events
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _touchEnabled = !_touchEnabled),
                            child: Container(
                              height: 40,
                              decoration: BoxDecoration(
                                color: _touchEnabled
                                    ? const Color(0xFF22C55E).withOpacity(0.2)
                                    : Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: _touchEnabled
                                      ? const Color(0xFF22C55E).withOpacity(0.5)
                                      : Colors.white.withOpacity(0.1),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _touchEnabled ? Icons.touch_app : Icons.touch_app_outlined,
                                    size: 18,
                                    color: _touchEnabled ? const Color(0xFF22C55E) : Colors.white38,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _touchEnabled ? 'Touch ON' : 'Touch OFF',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _touchEnabled ? const Color(0xFF22C55E) : Colors.white38,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Swipe left (показать предыдущую страницу)
                        IconButton(
                          onPressed: enabled ? () => _sendSwipeDirection(ble, 'right') : null,
                          icon: const Icon(Icons.chevron_left),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white.withOpacity(0.05),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // Close app
                        IconButton(
                          onPressed: enabled ? () => _closeApp(ble) : null,
                          icon: const Icon(Icons.close, size: 20),
                          tooltip: 'Close App',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.red.withOpacity(0.1),
                            foregroundColor: Colors.red,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // Swipe right (показать следующую страницу)
                        IconButton(
                          onPressed: enabled ? () => _sendSwipeDirection(ble, 'left') : null,
                          icon: const Icon(Icons.chevron_right),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white.withOpacity(0.05),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDisplay(BleService ble, bool enabled, bool inProgress, double progress) {
    final hasTimeout = ble.transferTimeout;
    
    // Всегда возвращаем контейнер одинакового размера
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasTimeout ? Colors.red : Colors.white.withOpacity(0.1),
          width: hasTimeout ? 2 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Stack(
          children: [
            if (_displayImage != null)
              _buildInteractiveImage(ble, enabled)
            else
              _buildPlaceholder(enabled, inProgress),
            // Показываем индикатор ошибки
            if (hasTimeout)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Таймаут',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInteractiveImage(BleService ble, bool enabled) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final displaySize = Size(constraints.maxWidth, constraints.maxHeight);
        
        Offset? toImagePos(Offset globalPos) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return null;
          final localPos = box.globalToLocal(globalPos);
          
          if (localPos.dx >= 0 && localPos.dx <= displaySize.width &&
              localPos.dy >= 0 && localPos.dy <= displaySize.height) {
            return localPos;
          }
          return null;
        }
        
        return GestureDetector(
          onPanStart: (details) {
            if (!enabled) return;
            final pos = toImagePos(details.globalPosition);
            if (pos != null) {
              _panStart = pos;
              _panStartTime = DateTime.now();
              _panEnd = pos;
            }
          },
          onPanUpdate: (details) {
            if (!enabled || _panStart == null) return;
            final pos = toImagePos(details.globalPosition);
            if (pos != null) {
              _panEnd = pos;
            }
          },
          onPanEnd: (details) {
            if (!enabled || _panStart == null) return;
            
            final endPos = _panEnd ?? _panStart!;
            final dx = endPos.dx - _panStart!.dx;
            final dy = endPos.dy - _panStart!.dy;
            final distance = (dx * dx + dy * dy);
            
            if (distance > _swipeThreshold * _swipeThreshold) {
              _sendSwipe(ble, _panStart!, endPos, displaySize);
            } else {
              _sendTap(ble, _panStart!, displaySize);
            }
            
            _panStart = null;
            _panEnd = null;
          },
          onPanCancel: () {
            _panStart = null;
            _panEnd = null;
          },
          child: RawImage(
            image: _displayImage,
            fit: BoxFit.contain,
            width: double.infinity,
            height: double.infinity,
          ),
        );
      },
    );
  }

  Widget _buildPlaceholder(bool enabled, bool inProgress) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (inProgress)
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Colors.white.withOpacity(0.5),
                ),
              ),
            )
          else
            Icon(
              enabled ? Icons.touch_app : Icons.cast_connected,
              size: 48,
              color: Colors.white.withOpacity(0.2),
            ),
          const SizedBox(height: 16),
          Text(
            inProgress 
                ? 'Загрузка...'
                : enabled
                    ? 'Нажмите "Фото"'
                    : 'Подключите часы',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
