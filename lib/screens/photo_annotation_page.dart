part of '../main.dart';

// ─────────────────────────────────────────────────────────
// Photo Annotation (ペン描画)
// ─────────────────────────────────────────────────────────

class _DrawnStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final bool isEraser;

  _DrawnStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.isEraser = false,
  });
}

class _TextAnnotation {
  final String text;
  final Offset position;
  final Color color;
  final double fontSize;

  const _TextAnnotation({
    required this.text,
    required this.position,
    required this.color,
    required this.fontSize,
  });

  _TextAnnotation copyWith({
    String? text,
    Offset? position,
    Color? color,
    double? fontSize,
  }) {
    return _TextAnnotation(
      text: text ?? this.text,
      position: position ?? this.position,
      color: color ?? this.color,
      fontSize: fontSize ?? this.fontSize,
    );
  }
}

class _StrokesPainter extends CustomPainter {
  final List<_DrawnStroke> strokes;
  final _DrawnStroke? currentStroke;
  final List<_TextAnnotation> textAnnotations;

  const _StrokesPainter({
    required this.strokes,
    required this.currentStroke,
    required this.textAnnotations,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in [...strokes, ?currentStroke]) {
      _drawStroke(canvas, stroke);
    }
    for (final annotation in textAnnotations) {
      _drawText(canvas, annotation);
    }
    canvas.restore();
  }

  void _drawStroke(Canvas canvas, _DrawnStroke stroke) {
    if (stroke.points.isEmpty) return;
    final paint = Paint()
      ..color = stroke.isEraser ? const Color(0x00000000) : stroke.color
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver
      ..strokeWidth = stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (stroke.points.length == 1) {
      canvas.drawCircle(
        stroke.points.first,
        stroke.strokeWidth / 2,
        Paint()
          ..color = stroke.isEraser ? const Color(0x00000000) : stroke.color
          ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver
          ..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (int i = 1; i < stroke.points.length - 1; i++) {
      final midX = (stroke.points[i].dx + stroke.points[i + 1].dx) / 2;
      final midY = (stroke.points[i].dy + stroke.points[i + 1].dy) / 2;
      path.quadraticBezierTo(
        stroke.points[i].dx,
        stroke.points[i].dy,
        midX,
        midY,
      );
    }
    path.lineTo(stroke.points.last.dx, stroke.points.last.dy);
    canvas.drawPath(path, paint);
  }

  void _drawText(Canvas canvas, _TextAnnotation annotation) {
    final painter = TextPainter(
      text: TextSpan(
        text: annotation.text,
        style: TextStyle(
          color: annotation.color,
          fontSize: annotation.fontSize,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    painter.paint(canvas, annotation.position);
  }

  @override
  bool shouldRepaint(_StrokesPainter old) => true;
}

class PhotoAnnotationPage extends StatefulWidget {
  final Uint8List? imageBytes;
  final String title;
  final Color canvasBackgroundColor;

  const PhotoAnnotationPage({
    super.key,
    required this.imageBytes,
    this.title = '写真に書き込み',
  }) : canvasBackgroundColor = Colors.black;

  const PhotoAnnotationPage.blank({super.key, this.title = 'メモに書き込み'})
    : imageBytes = null,
      canvasBackgroundColor = Colors.white;

  @override
  State<PhotoAnnotationPage> createState() => _PhotoAnnotationPageState();
}

class _PhotoAnnotationPageState extends State<PhotoAnnotationPage> {
  final List<_DrawnStroke> _strokes = [];
  final List<_DrawnStroke> _redoStack = [];
  final List<_TextAnnotation> _textAnnotations = [];
  _DrawnStroke? _currentStroke;
  Color _penColor = Colors.red;
  double _strokeWidth = 4.0;
  double _eraserWidth = 24.0;
  bool _isErasing = false;
  bool _isTextMode = false;
  bool _isZoomMode = false;
  double _viewScale = 1.0;
  double _viewRotation = 0.0;
  Offset _viewOffset = Offset.zero;
  Offset? _mousePos;
  int? _activeDrawPointer;
  int? _activePanPointer;
  Offset _panStartViewport = Offset.zero;
  Offset _panStartOffset = Offset.zero;
  int _scalePointerCount = 0;
  double _scaleStartViewScale = 1.0;
  double _scaleStartViewRotation = 0.0;
  Offset _scaleStartViewOffset = Offset.zero;
  Offset _scaleStartFocalCanvas = Offset.zero;
  Offset _scaleStartFocalViewport = Offset.zero;
  int? _activeTextPointer;
  int? _activeTextIndex;
  Offset _textDragStartCanvas = Offset.zero;
  Offset _textDragStartPosition = Offset.zero;
  int? _hoveredTextIndex;
  bool _suppressNextTextTap = false;
  final _repaintKey = GlobalKey();
  ui.Image? _uiImage;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void dispose() {
    _uiImage?.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    final sourceBytes = widget.imageBytes;
    if (sourceBytes == null) return;
    final codec = await ui.instantiateImageCodec(sourceBytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _uiImage = frame.image);
  }

  void _updateMousePos(Offset? nextPosition) {
    if (_mousePos == nextPosition) return;
    setState(() => _mousePos = nextPosition);
  }

  Rect _annotationBounds(_TextAnnotation annotation) {
    final painter = TextPainter(
      text: TextSpan(
        text: annotation.text,
        style: TextStyle(
          color: annotation.color,
          fontSize: annotation.fontSize,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    return Rect.fromLTWH(
      annotation.position.dx,
      annotation.position.dy,
      painter.width,
      painter.height,
    );
  }

  int? _hitTestTextAnnotation(Offset canvasPoint) {
    for (var index = _textAnnotations.length - 1; index >= 0; index--) {
      final bounds = _annotationBounds(_textAnnotations[index]).inflate(10);
      if (bounds.contains(canvasPoint)) {
        return index;
      }
    }
    return null;
  }

  static const _colorOptions = [
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.white,
    Colors.black,
  ];

  static const double _minViewScale = 0.5;
  static const double _maxViewScale = 6.0;

  Offset _rotateOffset(Offset offset, double angle) {
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    return Offset(
      offset.dx * cosA - offset.dy * sinA,
      offset.dx * sinA + offset.dy * cosA,
    );
  }

  Offset _viewportToCanvas(Offset point) {
    return _rotateOffset(point - _viewOffset, -_viewRotation) / _viewScale;
  }

  void _zoomAt(Offset viewportPoint, double scaleDelta) {
    final canvasPoint = _viewportToCanvas(viewportPoint);
    final nextScale = (_viewScale * scaleDelta).clamp(
      _minViewScale,
      _maxViewScale,
    );
    setState(() {
      _viewScale = nextScale;
      _viewOffset =
          viewportPoint -
          _rotateOffset(canvasPoint * _viewScale, _viewRotation);
    });
  }

  void _rotateView(double angle) {
    final box = _repaintKey.currentContext?.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size.zero;
    final center = Offset(size.width / 2, size.height / 2);
    final centerCanvas = _viewportToCanvas(center);
    final quarterTurns = ((_viewRotation + angle) / (math.pi / 2)).round();
    final newRotation = quarterTurns * (math.pi / 2);
    final newOffset =
        center - _rotateOffset(centerCanvas * _viewScale, newRotation);
    setState(() {
      _viewRotation = newRotation;
      _viewOffset = newOffset;
    });
  }

  void _resetView() {
    setState(() {
      _viewScale = 1.0;
      _viewRotation = 0.0;
      _viewOffset = Offset.zero;
    });
  }

  void _setZoomMode(bool enabled) {
    setState(() {
      _isZoomMode = enabled;
      _currentStroke = null;
      _activeDrawPointer = null;
      _activePanPointer = null;
      _activeTextPointer = null;
      _activeTextIndex = null;
      _hoveredTextIndex = null;
      _suppressNextTextTap = false;
      _mousePos = enabled ? null : _mousePos;
    });
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_isZoomMode) {
      if (_isZoomMode &&
          event.kind == PointerDeviceKind.mouse &&
          event.buttons == kSecondaryMouseButton) {
        _activePanPointer = event.pointer;
        _panStartViewport = event.localPosition;
        _panStartOffset = _viewOffset;
      }
      return;
    }

    final canvasPoint = _viewportToCanvas(event.localPosition);
    final hitTextIndex = _hitTestTextAnnotation(canvasPoint);
    if (hitTextIndex != null) {
      _activeTextPointer = event.pointer;
      _activeTextIndex = hitTextIndex;
      _textDragStartCanvas = canvasPoint;
      _textDragStartPosition = _textAnnotations[hitTextIndex].position;
      _suppressNextTextTap = true;
      return;
    }

    if (_isTextMode) {
      return;
    }

    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons == kSecondaryMouseButton) {
      _activePanPointer = event.pointer;
      _panStartViewport = event.localPosition;
      _panStartOffset = _viewOffset;
      return;
    }

    if (_activePanPointer != null) return;

    if (event.buttons == kPrimaryMouseButton ||
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.mouse) {
      _activeDrawPointer = event.pointer;
      final canvasPoint = _viewportToCanvas(event.localPosition);
      setState(() {
        _mousePos = canvasPoint;
        _currentStroke = _DrawnStroke(
          points: [canvasPoint],
          color: _penColor,
          strokeWidth: _isErasing ? _eraserWidth : _strokeWidth,
          isEraser: _isErasing,
        );
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_activePanPointer == event.pointer) {
      setState(() {
        _viewOffset =
            _panStartOffset + (event.localPosition - _panStartViewport);
      });
      return;
    }

    if (_activeTextPointer == event.pointer && _activeTextIndex != null) {
      final canvasPoint = _viewportToCanvas(event.localPosition);
      final nextPosition =
          _textDragStartPosition + (canvasPoint - _textDragStartCanvas);
      setState(() {
        _textAnnotations[_activeTextIndex!] =
            _textAnnotations[_activeTextIndex!].copyWith(
              position: nextPosition,
            );
      });
      return;
    }

    if (_isZoomMode) return;

    if (_activeDrawPointer != event.pointer || _currentStroke == null) {
      return;
    }

    final canvasPoint = _viewportToCanvas(event.localPosition);
    setState(() {
      _mousePos = canvasPoint;
      _currentStroke?.points.add(canvasPoint);
    });
  }

  void _finishPointer(int pointer) {
    if (_activePanPointer == pointer) {
      _activePanPointer = null;
    }
    if (_activeTextPointer == pointer) {
      _activeTextPointer = null;
      _activeTextIndex = null;
    }
    if (_activeDrawPointer != pointer) return;
    setState(() {
      if (_currentStroke != null) {
        _strokes.add(_currentStroke!);
        _redoStack.clear();
        _currentStroke = null;
      }
    });
    _activeDrawPointer = null;
  }

  void _handleHover(PointerHoverEvent event) {
    if (_isZoomMode) {
      _updateMousePos(null);
      if (_hoveredTextIndex != null) {
        setState(() => _hoveredTextIndex = null);
      }
      return;
    }

    final canvasPoint = _viewportToCanvas(event.localPosition);
    final nextHoveredIndex = _hitTestTextAnnotation(canvasPoint);
    if (_hoveredTextIndex != nextHoveredIndex) {
      setState(() => _hoveredTextIndex = nextHoveredIndex);
    }

    _updateMousePos(_isErasing ? canvasPoint : null);
  }

  Future<void> _showTextInputDialog(Offset canvasPosition) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('文字を追加'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: null,
            decoration: const InputDecoration(hintText: '入力してください'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('追加'),
            ),
          ],
        );
      },
    );

    if (!mounted || text == null) return;
    final value = text.trim();
    if (value.isEmpty) return;

    setState(() {
      _textAnnotations.add(
        _TextAnnotation(
          text: value,
          position: canvasPosition,
          color: _penColor,
          fontSize: 20.0,
        ),
      );
    });
  }

  void _handleTapUp(TapUpDetails details) {
    if (!_isTextMode || _isZoomMode) return;
    if (_suppressNextTextTap) {
      _suppressNextTextTap = false;
      return;
    }
    _showTextInputDialog(_viewportToCanvas(details.localPosition));
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final isTrackpad = event.kind == PointerDeviceKind.trackpad;
    final zoomDelta = isTrackpad ? event.scrollDelta.dy : -event.scrollDelta.dy;
    final zoomFactor = math.exp(zoomDelta / 120);
    _zoomAt(event.localPosition, zoomFactor);
  }

  void _handleScaleStart(ScaleStartDetails details) {
    if (details.pointerCount < 2) {
      if (_isZoomMode) {
        _scalePointerCount = 1;
        _scaleStartViewScale = _viewScale;
        _scaleStartViewRotation = _viewRotation;
        _scaleStartViewOffset = _viewOffset;
        _scaleStartFocalCanvas = _viewportToCanvas(details.localFocalPoint);
        _scaleStartFocalViewport = details.localFocalPoint;
      }
      return;
    }
    _scalePointerCount = 1;
    _scaleStartViewScale = _viewScale;
    _scaleStartViewRotation = _viewRotation;
    _scaleStartViewOffset = _viewOffset;
    _scaleStartFocalCanvas = _viewportToCanvas(details.localFocalPoint);
    _scaleStartFocalViewport = details.localFocalPoint;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (!_isZoomMode && details.pointerCount < 2) {
      return;
    }
    if (details.pointerCount < 2) {
      if (_scalePointerCount != 1) {
        _scalePointerCount = 1;
        _scaleStartViewOffset = _viewOffset;
        _scaleStartFocalViewport = details.localFocalPoint;
        return;
      }

      setState(() {
        _viewOffset =
            _scaleStartViewOffset +
            (details.localFocalPoint - _scaleStartFocalViewport);
      });
      _scalePointerCount = details.pointerCount;
      return;
    }

    if (_scalePointerCount < 2) {
      _scaleStartViewScale = _viewScale;
      _scaleStartViewRotation = _viewRotation;
      _scaleStartViewOffset = _viewOffset;
      _scaleStartFocalCanvas = _viewportToCanvas(details.localFocalPoint);
      _scaleStartFocalViewport = details.localFocalPoint;
    }
    _scalePointerCount = details.pointerCount;

    final newScale = (_scaleStartViewScale * details.scale).clamp(
      _minViewScale,
      _maxViewScale,
    );
    final newRotation = _scaleStartViewRotation;
    final newOffset =
        details.localFocalPoint -
        _rotateOffset(_scaleStartFocalCanvas * newScale, newRotation);
    setState(() {
      _viewScale = newScale;
      _viewRotation = newRotation;
      _viewOffset = newOffset;
    });
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _scalePointerCount = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.canvasBackgroundColor,
      appBar: AppBar(
        backgroundColor: widget.canvasBackgroundColor,
        foregroundColor: widget.canvasBackgroundColor == Colors.black
            ? Colors.white
            : Colors.black,
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          Expanded(
            child: RepaintBoundary(
              key: _repaintKey,
              child: MouseRegion(
                cursor: _isZoomMode
                    ? SystemMouseCursors.grab
                    : (_activeTextPointer != null
                          ? SystemMouseCursors.grabbing
                          : (_hoveredTextIndex != null
                                ? SystemMouseCursors.move
                                : (_isErasing
                                      ? SystemMouseCursors.none
                                      : SystemMouseCursors.precise))),
                onHover: _handleHover,
                onExit: (_) => _updateMousePos(null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _handleTapUp,
                  onScaleStart: _handleScaleStart,
                  onScaleUpdate: _handleScaleUpdate,
                  onScaleEnd: _handleScaleEnd,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _handlePointerDown,
                    onPointerMove: _handlePointerMove,
                    onPointerUp: (event) => _finishPointer(event.pointer),
                    onPointerCancel: (event) => _finishPointer(event.pointer),
                    onPointerSignal: _handlePointerSignal,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Transform(
                          transform: Matrix4.identity()
                            ..translateByDouble(
                              _viewOffset.dx,
                              _viewOffset.dy,
                              0,
                              1,
                            )
                            ..rotateZ(_viewRotation)
                            ..scaleByDouble(_viewScale, _viewScale, 1, 1),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (widget.imageBytes != null)
                                Image.memory(
                                  widget.imageBytes!,
                                  fit: BoxFit.contain,
                                )
                              else
                                Container(color: Colors.white),
                              CustomPaint(
                                painter: _StrokesPainter(
                                  strokes: _strokes,
                                  currentStroke: _currentStroke,
                                  textAnnotations: _textAnnotations,
                                ),
                                child: Container(color: Colors.transparent),
                              ),
                              if (!_isZoomMode &&
                                  _isErasing &&
                                  _mousePos != null)
                                Positioned(
                                  left: _mousePos!.dx - _eraserWidth / 2,
                                  top: _mousePos!.dy - _eraserWidth / 2,
                                  child: IgnorePointer(
                                    child: Container(
                                      width: _eraserWidth,
                                      height: _eraserWidth,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Colors.white,
                                          width: 1.5,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          _buildToolbar(),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // カラーパレット
              for (final color in _colorOptions)
                GestureDetector(
                  onTap: _isZoomMode
                      ? null
                      : () => setState(() {
                          _penColor = color;
                          _isErasing = false;
                        }),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: !_isErasing && _penColor == color
                            ? Colors.white
                            : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              Icon(
                _isZoomMode
                    ? Icons.zoom_in_map
                    : (_isErasing ? Icons.auto_fix_normal : Icons.brush),
                color: Colors.white54,
                size: 18,
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 100,
                child: Slider(
                  value: _isErasing ? _eraserWidth : _strokeWidth,
                  min: 2,
                  max: _isErasing ? 60 : 20,
                  onChanged: _isZoomMode
                      ? null
                      : (v) => setState(() {
                          if (_isErasing) {
                            _eraserWidth = v;
                          } else {
                            _strokeWidth = v;
                          }
                        }),
                  activeColor: _isErasing ? Colors.white54 : _penColor,
                  inactiveColor: Colors.white24,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // モード切替(押した状態が続く)ボタン群。枠で囲み、下の
              // 一回きりの操作ボタンと見た目で区別する。
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _buildActionButton(
                      icon: Icons.zoom_in_map,
                      label: 'ズーム',
                      onPressed: () => _setZoomMode(!_isZoomMode),
                      emphasized: _isZoomMode,
                    ),
                    _buildActionButton(
                      icon: Icons.title,
                      label: '文字',
                      onPressed: _isZoomMode
                          ? null
                          : () => setState(() {
                              _isTextMode = !_isTextMode;
                              _isErasing = false;
                            }),
                      emphasized: !_isZoomMode && _isTextMode,
                    ),
                    _buildActionButton(
                      icon: Icons.auto_fix_normal,
                      label: '消しゴム',
                      onPressed: _isZoomMode
                          ? null
                          : () => setState(() => _isErasing = !_isErasing),
                      emphasized: !_isZoomMode && _isErasing,
                    ),
                  ],
                ),
              ),
              _buildActionButton(
                icon: Icons.undo,
                label: '元に戻す',
                onPressed: _strokes.isEmpty ? null : _undo,
              ),
              _buildActionButton(
                icon: Icons.redo,
                label: 'やり直し',
                onPressed: _redoStack.isEmpty ? null : _redo,
              ),
              _buildActionButton(
                icon: Icons.center_focus_strong,
                label: 'リセット',
                onPressed: _resetView,
              ),
              _buildActionButton(
                icon: Icons.delete_outline,
                label: 'クリア',
                onPressed: _strokes.isEmpty && _textAnnotations.isEmpty
                    ? null
                    : _clear,
              ),
              if (_isZoomMode) ...[
                _buildActionButton(
                  icon: Icons.zoom_out,
                  label: '縮小',
                  onPressed: () => _zoomAt(const Offset(200, 200), 0.85),
                ),
                _buildActionButton(
                  icon: Icons.zoom_in,
                  label: '拡大',
                  onPressed: () => _zoomAt(const Offset(200, 200), 1.18),
                ),
                _buildActionButton(
                  icon: Icons.rotate_left,
                  label: '左回転',
                  onPressed: () => _rotateView(-math.pi / 2),
                ),
                _buildActionButton(
                  icon: Icons.rotate_right,
                  label: '右回転',
                  onPressed: () => _rotateView(math.pi / 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text(
                '保存',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandOrange,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool emphasized = false,
  }) {
    final foreground = emphasized ? Colors.black : Colors.white;
    final background = emphasized ? Colors.white : Colors.white12;
    return SizedBox(
      height: 40,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: Colors.white10,
          disabledForegroundColor: Colors.white38,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  void _undo() => setState(() => _redoStack.add(_strokes.removeLast()));
  void _redo() => setState(() => _strokes.add(_redoStack.removeLast()));
  void _clear() => setState(() {
    _redoStack.addAll(_strokes.reversed);
    _strokes.clear();
    _textAnnotations.clear();
  });

  Future<void> _save() async {
    final srcImage = _uiImage;
    final box = _repaintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      if (mounted) Navigator.pop(context);
      return;
    }

    if (srcImage == null) {
      final repaint =
          _repaintKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (repaint == null) {
        if (mounted) Navigator.pop(context);
        return;
      }
      final image = await repaint.toImage(pixelRatio: 2.0);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null || !mounted) return;
      Navigator.pop(context, png.buffer.asUint8List());
      return;
    }

    final imgW = srcImage.width.toDouble();
    final imgH = srcImage.height.toDouble();
    final conW = box.size.width;
    final conH = box.size.height;

    // BoxFit.contain の表示領域を計算してストロークの座標を逆変換
    double displayW, displayH, offsetX, offsetY;
    if (imgW / imgH > conW / conH) {
      displayW = conW;
      displayH = conW * imgH / imgW;
      offsetX = 0;
      offsetY = (conH - displayH) / 2;
    } else {
      displayH = conH;
      displayW = conH * imgW / imgH;
      offsetX = (conW - displayW) / 2;
      offsetY = 0;
    }
    final scale = imgW / displayW;

    // 1. ストロークレイヤーを別途作成（透明背景、消しゴムはここだけで有効）
    final strokeRecorder = ui.PictureRecorder();
    final strokeCanvas = Canvas(strokeRecorder);
    strokeCanvas.saveLayer(Rect.fromLTWH(0, 0, imgW, imgH), Paint());
    for (final stroke in _strokes) {
      _paintScaledStroke(strokeCanvas, stroke, offsetX, offsetY, scale);
    }
    strokeCanvas.restore();
    final strokePicture = strokeRecorder.endRecording();
    final strokeImage = await strokePicture.toImage(
      srcImage.width,
      srcImage.height,
    );

    // 2. 元画像 + ストロークレイヤーを合成
    final compositeRecorder = ui.PictureRecorder();
    final compositeCanvas = Canvas(compositeRecorder);
    compositeCanvas.drawImage(srcImage, Offset.zero, Paint());
    compositeCanvas.drawImage(strokeImage, Offset.zero, Paint());
    for (final annotation in _textAnnotations) {
      final scaledPosition = Offset(
        (annotation.position.dx - offsetX) * scale,
        (annotation.position.dy - offsetY) * scale,
      );
      final textPainter = TextPainter(
        text: TextSpan(
          text: annotation.text,
          style: TextStyle(
            color: annotation.color,
            fontSize: annotation.fontSize * scale,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      textPainter.paint(compositeCanvas, scaledPosition);
    }
    final compositePicture = compositeRecorder.endRecording();
    final compositeImage = await compositePicture.toImage(
      srcImage.width,
      srcImage.height,
    );

    // 3. プレビューの回転をそのまま最終画像に適用
    final rotation = _viewRotation;
    final cosR = math.cos(rotation).abs();
    final sinR = math.sin(rotation).abs();
    final outW = (imgW * cosR + imgH * sinR).round();
    final outH = (imgW * sinR + imgH * cosR).round();

    final rotatedRecorder = ui.PictureRecorder();
    final rotatedCanvas = Canvas(rotatedRecorder);
    rotatedCanvas.translate(outW / 2, outH / 2);
    rotatedCanvas.rotate(rotation);
    rotatedCanvas.translate(-imgW / 2, -imgH / 2);
    rotatedCanvas.drawImage(compositeImage, Offset.zero, Paint());
    final rotatedPicture = rotatedRecorder.endRecording();
    final out = await rotatedPicture.toImage(outW, outH);

    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || !mounted) return;
    Navigator.pop(context, data.buffer.asUint8List());
  }

  void _paintScaledStroke(
    Canvas canvas,
    _DrawnStroke stroke,
    double offsetX,
    double offsetY,
    double scale,
  ) {
    if (stroke.points.isEmpty) return;
    final scaled = stroke.points
        .map((p) => Offset((p.dx - offsetX) * scale, (p.dy - offsetY) * scale))
        .toList();
    final paint = Paint()
      ..color = stroke.isEraser ? const Color(0x00000000) : stroke.color
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver
      ..strokeWidth = stroke.strokeWidth * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (scaled.length == 1) {
      canvas.drawCircle(
        scaled.first,
        stroke.strokeWidth * scale / 2,
        Paint()
          ..color = stroke.isEraser ? const Color(0x00000000) : stroke.color
          ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver
          ..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(scaled.first.dx, scaled.first.dy);
    for (int i = 1; i < scaled.length - 1; i++) {
      final midX = (scaled[i].dx + scaled[i + 1].dx) / 2;
      final midY = (scaled[i].dy + scaled[i + 1].dy) / 2;
      path.quadraticBezierTo(scaled[i].dx, scaled[i].dy, midX, midY);
    }
    path.lineTo(scaled.last.dx, scaled.last.dy);
    canvas.drawPath(path, paint);
  }
}
