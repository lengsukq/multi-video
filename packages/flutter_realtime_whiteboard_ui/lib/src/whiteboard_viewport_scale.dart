import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// Read the 2D whiteboard zoom, not Matrix4.getMaxScaleOnAxis().
///
/// The whiteboard uses 2D scaling, so its Z axis stays at 1.0 even when
/// the X/Y scale is 0.25. getMaxScaleOnAxis() would report 1.0 and cause
/// a pan or resize to unexpectedly reset a zoomed-out mobile viewport.
double whiteboardViewportScale(Matrix4 matrix) {
  final x = matrix.entry(0, 0);
  final y = matrix.entry(1, 0);
  return math.sqrt(x * x + y * y);
}
