import '../utils/io_compat.dart';
import 'package:flutter/material.dart';

/// Modes de fond virtuel CRUX.
sealed class VirtualBackgroundMode {
  const VirtualBackgroundMode();
}

class VirtualBackgroundNone extends VirtualBackgroundMode {
  const VirtualBackgroundNone();
}

sealed class VirtualBackgroundBlur extends VirtualBackgroundMode {
  final double blurRadius;
  const VirtualBackgroundBlur(this.blurRadius);
}

class VirtualBackgroundBlurLight extends VirtualBackgroundBlur {
  const VirtualBackgroundBlurLight() : super(5.0);
}

class VirtualBackgroundBlurMedium extends VirtualBackgroundBlur {
  const VirtualBackgroundBlurMedium() : super(10.0);
}

class VirtualBackgroundBlurStrong extends VirtualBackgroundBlur {
  const VirtualBackgroundBlurStrong() : super(20.0);
}

class VirtualBackgroundImage extends VirtualBackgroundMode {
  final File image;
  final double opacity;
  const VirtualBackgroundImage(this.image, {this.opacity = 1.0});
}

class VirtualBackgroundColor extends VirtualBackgroundMode {
  final Color color;
  const VirtualBackgroundColor(this.color);
}

class VirtualBackgroundGradient extends VirtualBackgroundMode {
  final List<Color> colors;
  final Alignment begin;
  final Alignment end;
  const VirtualBackgroundGradient(
    this.colors, {
    this.begin = Alignment.topLeft,
    this.end = Alignment.bottomRight,
  });
}
