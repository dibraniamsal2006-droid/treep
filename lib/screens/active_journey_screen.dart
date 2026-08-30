import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Color treepBackground = Color(0xFF090C0B);
const Color treepSurface = Color(0xFF131816);
const Color treepSurfaceRaised = Color(0xFF19201D);
const Color treepGreen = Color(0xFF55D68B);
const Color treepMuted = Color(0xFF89938E);
const Color treepBorder = Color(0xFF27302C);
const Color treepDanger = Color(0xFFFF7B73);
const Color treepCompleted = Color(0xFFDCE3DF);
const int journeyPassengerWagonCount = 5;
const double journeyLocomotiveFrontLength = 17;
const double journeyWagonTailLength = 13;

String treepDirectionPhrase(String direction) {
  final clean = direction.trim();
  if (clean.isEmpty || clean.toLowerCase() == 'direction unavailable') {
    return 'Direction unavailable';
  }
  return 'Direction $clean';
}

double journeyVehicleSpacingForRadius(double radius) =>
    math.min(0.112, 28 / radius);

double journeyTrainAngleForProgress(double progress, {double radius = 141}) {
  final clamped = progress.clamp(0.0, 1.0);
  const twelveOClock = -math.pi / 2;
  final spacing = journeyVehicleSpacingForRadius(radius);
  final start =
      twelveOClock -
      journeyPassengerWagonCount * spacing -
      journeyWagonTailLength / radius;
  final end =
      twelveOClock - math.pi * 2 + journeyLocomotiveFrontLength / radius;
  return start + (end - start) * clamped;
}

double journeyLastWagonTailAngleForProgress(
  double progress, {
  double radius = 141,
}) =>
    journeyTrainAngleForProgress(progress, radius: radius) +
    journeyPassengerWagonCount * journeyVehicleSpacingForRadius(radius) +
    journeyWagonTailLength / radius;

double journeyLocomotiveFrontAngleForProgress(
  double progress, {
  double radius = 141,
}) =>
    journeyTrainAngleForProgress(progress, radius: radius) -
    journeyLocomotiveFrontLength / radius;

double journeyCompletedSweepForProgress(double progress) =>
    -math.pi * 2 * progress.clamp(0.0, 1.0);

class TreepPressableButton extends StatefulWidget {
  const TreepPressableButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.backgroundColor = treepGreen,
    this.foregroundColor = const Color(0xFF07120C),
    this.borderColor = Colors.transparent,
    this.busy = false,
    this.haptic = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color borderColor;
  final bool busy;
  final bool haptic;

  @override
  State<TreepPressableButton> createState() => _TreepPressableButtonState();
}

class _TreepPressableButtonState extends State<TreepPressableButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  void _setPressed(bool value) {
    if (!_enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  void _activate() {
    _setPressed(false);
    if (!_enabled) return;
    if (widget.haptic) HapticFeedback.lightImpact();
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => _setPressed(true) : null,
        onTapCancel: _enabled ? () => _setPressed(false) : null,
        onTapUp: _enabled ? (_) => _activate() : null,
        child: AnimatedScale(
          scale: _pressed ? 0.975 : 1,
          duration: const Duration(milliseconds: 105),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: _enabled ? 1 : 0.45,
            duration: const Duration(milliseconds: 140),
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                color: widget.backgroundColor,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: widget.borderColor),
              ),
              alignment: Alignment.center,
              child: widget.busy
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: widget.foregroundColor,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.icon != null) ...[
                          Icon(
                            widget.icon,
                            size: 20,
                            color: widget.foregroundColor,
                          ),
                          const SizedBox(width: 9),
                        ],
                        Text(
                          widget.label,
                          style: TextStyle(
                            color: widget.foregroundColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.1,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class ActiveJourneyScreen extends StatelessWidget {
  const ActiveJourneyScreen({
    super.key,
    required this.activatedAt,
    required this.alarmTime,
    required this.arrivalTime,
    required this.lineLabel,
    required this.destinationLabel,
    required this.directionLabel,
    required this.isCancelling,
    required this.onCancel,
    this.cancellationMessage,
  });

  final DateTime activatedAt;
  final DateTime alarmTime;
  final DateTime arrivalTime;
  final String lineLabel;
  final String destinationLabel;
  final String directionLabel;
  final bool isCancelling;
  final VoidCallback? onCancel;
  final String? cancellationMessage;

  String _hhmm(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: treepBackground,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
            final compact = constraints.maxHeight < 700;

            Widget metadata() => Padding(
              key: const Key('journey-metadata'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ActiveLineBadge(label: lineLabel),
                  SizedBox(height: compact ? 7 : 10),
                  Text(
                    destinationLabel,
                    key: const Key('journey-destination'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    treepDirectionPhrase(directionLabel),
                    key: const Key('journey-direction'),
                    style: const TextStyle(
                      color: treepMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: compact ? 10 : 14),
                    child: const Divider(height: 1, color: treepBorder),
                  ),
                  _JourneyTimeRow(label: 'Arrival', value: _hhmm(arrivalTime)),
                  SizedBox(height: compact ? 7 : 10),
                  _JourneyTimeRow(
                    label: 'Alarm',
                    value: _hhmm(alarmTime),
                    accent: true,
                  ),
                ],
              ),
            );

            Widget footer() => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (cancellationMessage != null) ...[
                  const SizedBox(height: 9),
                  Text(
                    cancellationMessage!,
                    key: const Key('cancel-error'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: treepDanger,
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                ],
                SizedBox(height: compact ? 10 : 18),
                TreepPressableButton(
                  key: const Key('cancel-alarm-button'),
                  label: isCancelling ? 'Cancelling…' : 'Cancel alarm',
                  icon: Icons.close_rounded,
                  busy: isCancelling,
                  backgroundColor: treepSurfaceRaised,
                  foregroundColor: treepDanger,
                  borderColor: treepBorder,
                  haptic: false,
                  onPressed: isCancelling ? null : onCancel,
                ),
              ],
            );

            Widget header() => Column(
              children: [
                const Text(
                  'Active journey',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Alarm will ring at ${_hhmm(alarmTime)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: treepMuted, fontSize: 14),
                ),
              ],
            );

            final horizontalRingLimit = math.max(
              72.0,
              math.min(constraints.maxWidth - 48, 336.0),
            );
            final needsAccessibilityScroll =
                textScale > 1.3 || constraints.maxHeight < 460;
            if (needsAccessibilityScroll) {
              final ringDiameter = math.min(horizontalRingLimit, 220.0);
              return SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header(),
                      const SizedBox(height: 12),
                      Center(
                        child: JourneyProgressRing(
                          key: const Key('journey-progress-ring'),
                          activatedAt: activatedAt,
                          alarmTime: alarmTime,
                          diameter: ringDiameter,
                        ),
                      ),
                      const SizedBox(height: 12),
                      metadata(),
                      footer(),
                    ],
                  ),
                ),
              );
            }

            return Padding(
              key: const Key('active-journey-standard-layout'),
              padding: EdgeInsets.fromLTRB(
                24,
                compact ? 14 : 24,
                24,
                compact ? 12 : 18,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header(),
                  SizedBox(height: compact ? 8 : 14),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, ringConstraints) {
                        final ringDiameter = math.min(
                          horizontalRingLimit,
                          ringConstraints.maxHeight,
                        );
                        return Center(
                          child: JourneyProgressRing(
                            key: const Key('journey-progress-ring'),
                            activatedAt: activatedAt,
                            alarmTime: alarmTime,
                            diameter: ringDiameter,
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(height: compact ? 8 : 14),
                  metadata(),
                  footer(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _JourneyTimeRow extends StatelessWidget {
  const _JourneyTimeRow({
    required this.label,
    required this.value,
    this.accent = false,
  });

  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: treepMuted, fontSize: 14)),
        Text(
          value,
          style: TextStyle(
            color: accent ? treepGreen : Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ActiveLineBadge extends StatelessWidget {
  const _ActiveLineBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: treepGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: treepGreen,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class JourneyProgressRing extends StatefulWidget {
  const JourneyProgressRing({
    super.key,
    required this.activatedAt,
    required this.alarmTime,
    this.diameter = 328,
  });

  final DateTime activatedAt;
  final DateTime alarmTime;
  final double diameter;

  @override
  State<JourneyProgressRing> createState() => _JourneyProgressRingState();
}

class _JourneyProgressRingState extends State<JourneyProgressRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _configureAnimation();
  }

  @override
  void didUpdateWidget(covariant JourneyProgressRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activatedAt != widget.activatedAt ||
        oldWidget.alarmTime != widget.alarmTime) {
      _configureAnimation();
    }
  }

  void _configureAnimation() {
    final total = widget.alarmTime.difference(widget.activatedAt);
    final elapsed = DateTime.now().difference(widget.activatedAt);
    if (total <= Duration.zero || elapsed >= total) {
      _controller
        ..stop()
        ..value = 1;
      return;
    }
    final start = (elapsed.inMilliseconds / total.inMilliseconds).clamp(0, 1);
    _controller
      ..duration = total
      ..forward(from: start.toDouble());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _countdown() {
    final remaining = widget.alarmTime.difference(DateTime.now());
    final seconds = math.max(0, remaining.inSeconds);
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return SizedBox.square(
            dimension: widget.diameter,
            child: CustomPaint(
              painter: _TrainProgressPainter(progress: _controller.value),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _countdown(),
                      key: const Key('journey-countdown'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 42,
                        fontWeight: FontWeight.w300,
                        letterSpacing: -1.7,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'until alarm',
                      style: TextStyle(color: treepMuted, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TrainProgressPainter extends CustomPainter {
  const _TrainProgressPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 27;
    const startAngle = -math.pi / 2;
    final completedSweep = journeyCompletedSweepForProgress(progress);
    final track = Rect.fromCircle(center: center, radius: radius);
    final completedPaint = Paint()
      ..color = treepCompleted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;
    final remainingPaint = Paint()
      ..color = treepGreen
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    // The full duration starts green. Moving counter-clockwise from twelve
    // o'clock, the train replaces the consumed section with the light tone.
    canvas.drawArc(track, 0, math.pi * 2, false, remainingPaint);
    if (progress > 0) {
      canvas.drawArc(track, startAngle, completedSweep, false, completedPaint);
    }

    final headAngle = journeyTrainAngleForProgress(progress, radius: radius);
    final vehicleSpacing = journeyVehicleSpacingForRadius(radius);
    for (var index = journeyPassengerWagonCount; index >= 0; index--) {
      // Counter-clockwise is the direction of travel, so trailing vehicles
      // sit at progressively larger (clockwise) angles behind the engine.
      final angle = headAngle + vehicleSpacing * index;
      _paintVehicle(canvas, center, radius, angle, locomotive: index == 0);
    }
  }

  void _paintVehicle(
    Canvas canvas,
    Offset center,
    double radius,
    double angle, {
    required bool locomotive,
  }) {
    final point = Offset(
      center.dx + math.cos(angle) * radius,
      center.dy + math.sin(angle) * radius,
    );
    canvas.save();
    canvas.translate(point.dx, point.dy);
    // Local negative-Y points along the counter-clockwise tangent.
    canvas.rotate(angle);
    if (locomotive) {
      final body = RRect.fromRectAndRadius(
        const Rect.fromLTWH(-9.5, -13, 19, 28),
        const Radius.circular(4),
      );
      canvas.drawRRect(body, Paint()..color = const Color(0xFF151A18));
      final nose = Path()
        ..moveTo(-9.5, -12)
        ..lineTo(-6.5, -17)
        ..lineTo(6.5, -17)
        ..lineTo(9.5, -12)
        ..close();
      canvas.drawPath(nose, Paint()..color = const Color(0xFF151A18));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-6.5, -10.5, 13, 7),
          const Radius.circular(2),
        ),
        Paint()..color = const Color(0xFFB7EBCB),
      );
      canvas.drawRect(
        const Rect.fromLTWH(-9.5, 8, 19, 3),
        Paint()..color = treepGreen,
      );
    } else {
      final body = RRect.fromRectAndRadius(
        const Rect.fromLTWH(-7.5, -13, 15, 26),
        const Radius.circular(3.5),
      );
      canvas.drawRRect(body, Paint()..color = const Color(0xFFF0F3F1));
      final windows = Paint()..color = const Color(0xFF68736D);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-4.8, -8, 3.3, 5),
          const Radius.circular(1),
        ),
        windows,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(1.5, -8, 3.3, 5),
          const Radius.circular(1),
        ),
        windows,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-4.8, 1.5, 3.3, 5),
          const Radius.circular(1),
        ),
        windows,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(1.5, 1.5, 3.3, 5),
          const Radius.circular(1),
        ),
        windows,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TrainProgressPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
