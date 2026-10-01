import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'netherlands_map.dart';

/// Both themes use exactly the same assets, framing and overlays.
final class ConnectionArt extends StatelessWidget {
  const ConnectionArt({
    required this.dark,
    this.connected = false,
    this.countryCode = '',
    this.countryName = '',
    super.key,
  });
  final bool dark;
  final bool connected;
  final String countryCode;
  final String countryName;

  static const ColorFilter lightPalette = ColorFilter.matrix(<double>[
    .78,
    .05,
    -.55,
    0,
    198,
    .30,
    .40,
    -.20,
    0,
    217,
    .12,
    .05,
    .05,
    0,
    239,
    0,
    0,
    0,
    1,
    0,
  ]);

  @override
  Widget build(BuildContext context) {
    final netherlands = countryCode.toUpperCase() == 'NL';
    final regional =
        connected && (countryCode.toUpperCase() == 'AM' || netherlands);
    final base = dark ? const Color(0xFF060D20) : const Color(0xFFD4E0F5);
    final foreground = dark ? const Color(0xFF97A9E7) : const Color(0xFF637DBA);
    return IgnorePointer(child: LayoutBuilder(builder: (context, bounds) {
      Widget map = regional && netherlands
          ? const CustomPaint(
              key: ValueKey('netherlands-art'), painter: NetherlandsMap())
          : Image.asset(
              regional
                  ? 'assets/visual/armenia-map.png'
                  : 'assets/visual/globe.png',
              key: ValueKey(regional ? 'regional-art' : 'globe-art'),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
            );
      if (!dark) map = ColorFiltered(colorFilter: lightPalette, child: map);
      map = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent
          ],
          stops: [0, .05, .72, 1],
        ).createShader(rect),
        child: map,
      );
      return Stack(fit: StackFit.expand, children: <Widget>[
        ColoredBox(color: base),
        Positioned(
          top: regional ? 0 : bounds.maxHeight * .065,
          left: regional ? 0 : -bounds.maxWidth * .175,
          width: bounds.maxWidth * (regional ? 1 : 1.35),
          child: AspectRatio(
            aspectRatio: regional ? 1 : 1672 / 941,
            child: map,
          ),
        ),
        DecoratedBox(
            decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              base.withValues(alpha: .35),
              base.withValues(alpha: 0),
              base.withValues(alpha: 0),
              base
            ],
            stops: const <double>[0, .16, .69, 1],
          ),
        )),
        if (regional) ...<Widget>[
          if (netherlands) ...[
            _mapLabel('Северное море', .10, .22, foreground),
            _mapLabel('Германия', .85, .35, foreground),
            _mapLabel('Бельгия', .28, .40, foreground),
          ] else ...[
            _mapLabel('Грузия', .52, .10, foreground),
            _mapLabel('Турция', .12, .33, foreground),
            _mapLabel('Азербайджан', .83, .29, foreground),
            _mapLabel('Иран', .78, .49, foreground),
          ],
          Positioned(
            left: bounds.maxWidth * .57,
            top: netherlands ? bounds.maxWidth * .20 : bounds.maxHeight * .215,
            child: Row(children: <Widget>[
              Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border:
                        Border.all(color: const Color(0xFF8D47FF), width: 6),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                          color: Color(0xFF973DFF),
                          blurRadius: 20,
                          spreadRadius: 5)
                    ],
                  )),
              const SizedBox(width: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: base.withValues(alpha: .9),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFA079FF)),
                ),
                child: Text(countryName,
                    style: TextStyle(
                        color: dark ? Colors.white : const Color(0xFF25175F),
                        fontWeight: FontWeight.w600,
                        fontSize: 15)),
              ),
            ]),
          ),
        ],
      ]);
    }));
  }

  Widget _mapLabel(String label, double x, double y, Color color) => Align(
        alignment: FractionalOffset(x, y),
        child: Text(label,
            style:
                TextStyle(color: color.withValues(alpha: .76), fontSize: 15)),
      );
}

/// Integer harmonics share a 24-second period, including their first derivatives.
Offset orbOffset(double phase) {
  final t = phase * math.pi * 2;
  return Offset(9 * math.sin(t) + 4 * math.sin(3 * t + .7),
      6 * math.sin(2 * t + .4) + 3 * math.cos(5 * t));
}

final class ConnectionOrb extends StatefulWidget {
  const ConnectionOrb(
      {required this.dark,
      required this.connected,
      required this.size,
      required this.child,
      super.key});
  final bool dark;
  final bool connected;
  final double size;
  final Widget child;

  @override
  State<ConnectionOrb> createState() => _ConnectionOrbState();
}

final class _ConnectionOrbState extends State<ConnectionOrb> {
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);
  final Stopwatch _watch = Stopwatch();
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate = !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (animate && _timer == null) {
      _watch.start();
      _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
        _phase.value = (_watch.elapsedMicroseconds % 24000000) / 24000000;
      });
    } else if (!animate) {
      _timer?.cancel();
      _timer = null;
      _watch.stop();
      _phase.value = 0;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _watch.stop();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: ValueListenableBuilder<double>(
          valueListenable: _phase,
          child: SizedBox.square(dimension: widget.size, child: widget.child),
          builder: (context, phase, control) {
            final t = phase * math.pi * 2;
            Widget texture = Image.asset('assets/visual/orb.png',
                width: widget.size * 1.15,
                height: widget.size * 1.15,
                filterQuality: FilterQuality.medium,
                excludeFromSemantics: true);
            if (!widget.dark) {
              texture = ShaderMask(
                blendMode: BlendMode.srcATop,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xDD36F3FF),
                    Color(0xAA35DFFF),
                    Color(0x207C59FF),
                    Color(0xBBD7A2FF)
                  ],
                  stops: [.15, .4, .66, 1],
                ).createShader(rect),
                child: texture,
              );
            }
            return SizedBox(
              width: widget.size * 1.75,
              height: widget.size * 1.35,
              child: Transform.translate(
                offset: orbOffset(phase),
                child: Stack(alignment: Alignment.center, children: <Widget>[
                  Positioned.fill(
                      child: CustomPaint(
                          painter: _OrbitPainter(
                              phase: phase,
                              connected: widget.connected,
                              front: false))),
                  Transform.rotate(
                    angle: .12 * math.sin(t * 2) + .08 * math.sin(t * 3),
                    child: texture,
                  ),
                  Positioned.fill(
                      child: IgnorePointer(
                          child: CustomPaint(
                              painter: _OrbitPainter(
                                  phase: phase,
                                  connected: widget.connected,
                                  front: true)))),
                  control!,
                ]),
              ),
            );
          },
        ),
      );
}

final class _OrbitPainter extends CustomPainter {
  const _OrbitPainter(
      {required this.phase, required this.connected, required this.front});
  final double phase;
  final bool connected;
  final bool front;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.height / 1.35 * .5;
    const violet = Color(0xFFB774FF);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .9
      ..color = violet.withValues(alpha: .65);
    if (!front) {
      canvas.drawCircle(c, r * 1.17, line);
      canvas.drawCircle(
          c, r * 1.30, line..color = violet.withValues(alpha: .22));
    }
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-.26);
    final rx = r * (connected ? 1.60 : 1.30);
    final ry = r * .62;
    Offset point(double a) => Offset(rx * math.cos(a), ry * math.sin(a));
    final start = front ? 0.0 : math.pi;
    final orbit = Path()..moveTo(point(start).dx, point(start).dy);
    for (var i = 1; i <= 80; i++) {
      final p = point(start + i / 80 * math.pi);
      orbit.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
        orbit,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = connected ? 3 : 1
          ..color = violet.withValues(alpha: .45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    if (connected) {
      for (var i = 0; i < 40; i++) {
        final a = i / 40 * math.pi * 2 + phase * math.pi * 2;
        if ((math.sin(a) >= 0) != front) continue;
        final p = point(a);
        canvas.save();
        canvas.translate(p.dx, p.dy);
        canvas.rotate(math.atan2(ry * math.cos(a), -rx * math.sin(a)));
        canvas.drawOval(
            Rect.fromCenter(center: Offset.zero, width: 11, height: 5),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.3
              ..color = violet);
        canvas.restore();
      }
      for (var i = 0; i < 4; i++) {
        final a = i * math.pi / 2 + .3 + phase * math.pi * 2;
        if ((math.sin(a) >= 0) != front) continue;
        final p = point(a);
        canvas.save();
        canvas.translate(p.dx, p.dy);
        canvas.rotate(.26);
        _drawGlyph(canvas, const Size(25, 29), true,
            origin: const Offset(-12.5, -14.5));
        canvas.restore();
      }
    } else {
      canvas.drawPath(orbit, line..color = violet.withValues(alpha: .72));
      for (var i = 0; i < 3; i++) {
        final a = i * math.pi * 2 / 3 + phase * math.pi * 2;
        if ((math.sin(a) >= 0) != front) continue;
        final p = point(a);
        canvas.drawCircle(
            p,
            5,
            Paint()
              ..color = violet
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
        canvas.drawCircle(p, 2.5, Paint()..color = Colors.white);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.phase != phase || old.connected != connected || old.front != front;
}

final class ConnectionGlyph extends StatelessWidget {
  const ConnectionGlyph(
      {required this.connected, required this.size, super.key});
  final bool connected;
  final double size;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GlyphPainter(connected));
}

final class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.connected);
  final bool connected;
  @override
  void paint(Canvas canvas, Size size) => _drawGlyph(canvas, size, connected);
  @override
  bool shouldRepaint(covariant _GlyphPainter old) => old.connected != connected;
}

void _drawGlyph(Canvas canvas, Size size, bool connected,
    {Offset origin = Offset.zero}) {
  canvas.save();
  canvas.translate(origin.dx, origin.dy);
  final w = size.width;
  final h = size.height;
  final path = Path();
  if (connected) {
    path.moveTo(w * .5, h * .08);
    path.quadraticBezierTo(w * .28, h * .22, w * .12, h * .23);
    path.lineTo(w * .16, h * .56);
    path.quadraticBezierTo(w * .21, h * .76, w * .5, h * .92);
    path.quadraticBezierTo(w * .79, h * .76, w * .84, h * .56);
    path.lineTo(w * .88, h * .23);
    path.quadraticBezierTo(w * .72, h * .22, w * .5, h * .08);
    path.moveTo(w * .32, h * .49);
    path.lineTo(w * .46, h * .63);
    path.lineTo(w * .70, h * .37);
  } else {
    path.addArc(
        Rect.fromCenter(
            center: Offset(w * .5, h * .54), width: w * .69, height: h * .69),
        -math.pi * .31,
        math.pi * 1.62);
    path.moveTo(w * .5, h * .07);
    path.lineTo(w * .5, h * .45);
  }
  final pen = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w * .075
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  canvas.drawPath(
      path,
      pen
        ..color = const Color(0xFFBAAEFF)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .10));
  canvas.drawPath(
      path,
      pen
        ..color = Colors.white
        ..maskFilter = null);
  canvas.restore();
}
