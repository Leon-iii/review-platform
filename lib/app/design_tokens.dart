import 'package:flutter/material.dart';

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double section = 32;
}

abstract final class AppRadius {
  static const double control = 8;
  static const double card = 12;
  static const double panel = 16;
}

abstract final class AppLayout {
  static const double readingWidth = 720;
  static const double managementWidth = 1200;
  static const double railBreakpoint = 840;
  static const double touchTarget = 48;

  static EdgeInsets pagePadding(BuildContext context, {double bottom = 32}) =>
      EdgeInsets.fromLTRB(
        MediaQuery.sizeOf(context).width < 600 ? 16 : 24,
        16,
        MediaQuery.sizeOf(context).width < 600 ? 16 : 24,
        bottom,
      );
}
