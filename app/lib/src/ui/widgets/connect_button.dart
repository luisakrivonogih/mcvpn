import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../vpn/vpn_controller.dart';
import '../theme.dart';

/// The big central power control: a glowing ring that pulses while connecting,
/// glows steady when connected, and sits dim when off.
class ConnectButton extends StatefulWidget {
  final AppState state;
  final VoidCallback onTap;
  const ConnectButton({super.key, required this.state, required this.onTap});

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    _spin.dispose();
    super.dispose();
  }

  bool get _isConnected => widget.state == AppState.connected;
  bool get _isBusy =>
      widget.state == AppState.connecting ||
      widget.state == AppState.reconnecting ||
      widget.state == AppState.disconnecting;

  @override
  Widget build(BuildContext context) {
    final accent = _isConnected
        ? AppColors.accent
        : (widget.state == AppState.error ? AppColors.danger : AppColors.accent);

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 240,
        height: 240,
        child: AnimatedBuilder(
          animation: Listenable.merge([_pulse, _spin]),
          builder: (context, _) {
            final glow = _isConnected
                ? 0.35 + 0.25 * math.sin(_pulse.value * 2 * math.pi)
                : (_isBusy ? 0.3 : 0.12);
            return Stack(
              alignment: Alignment.center,
              children: [
                // Outer glow.
                Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: glow),
                        blurRadius: 60,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                ),
                // Track ring.
                Container(
                  width: 210,
                  height: 210,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: accent.withValues(alpha: 0.18),
                      width: 2,
                    ),
                  ),
                ),
                // Progress arc while busy.
                if (_isBusy)
                  Transform.rotate(
                    angle: _spin.value * 2 * math.pi,
                    child: CustomPaint(
                      size: const Size(210, 210),
                      painter: _ArcPainter(accent),
                    ),
                  ),
                // Core.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: _isConnected || _isBusy
                        ? const LinearGradient(
                            colors: [AppColors.gradientA, AppColors.gradientB],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : const LinearGradient(
                            colors: [
                              AppColors.surfaceDark2,
                              AppColors.surfaceDark,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                  ),
                  child: Icon(
                    Icons.power_settings_new_rounded,
                    size: 56,
                    color: _isConnected || _isBusy
                        ? Colors.white
                        : accent.withValues(alpha: 0.7),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  final Color color;
  _ArcPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [color.withValues(alpha: 0), color],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawArc(
      Rect.fromLTWH(2, 2, size.width - 4, size.height - 4),
      0,
      math.pi * 1.4,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ArcPainter oldDelegate) => false;
}
