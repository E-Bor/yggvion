import 'package:flutter/material.dart';

/// Scales layout, paint, pointer coordinates and overlays together. Insets stay
/// in the same logical coordinate space as the resized Navigator.
class InterfaceScale extends StatelessWidget {
  const InterfaceScale({super.key, required this.scale, required this.child});
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final size = Size(
          constraints.maxWidth / scale,
          constraints.maxHeight / scale,
        );
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: size.width,
            maxWidth: size.width,
            minHeight: size.height,
            maxHeight: size.height,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: MediaQuery(
                data: media.copyWith(
                  size: size,
                  padding: media.padding / scale,
                  viewPadding: media.viewPadding / scale,
                  viewInsets: media.viewInsets / scale,
                  systemGestureInsets: media.systemGestureInsets / scale,
                  devicePixelRatio: media.devicePixelRatio * scale,
                ),
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
