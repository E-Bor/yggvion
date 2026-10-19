import 'package:flutter/material.dart';
import 'theme.dart';

/// The Yggdrasil Shield mark; the mask takes its color from the live theme.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    size <= 48
        ? 'assets/branding/logo-mask-small.png'
        : 'assets/branding/logo-mask.png',
    width: size,
    height: size,
    cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
    color: context.accentColor,
    colorBlendMode: BlendMode.srcIn,
    filterQuality: FilterQuality.high,
    semanticLabel: 'Yggvion — Щит Иггдрасиля',
  );
}
