import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Renders the Postman James SVG character.
///
/// Replaces the old PostManJames CustomPainter. Animation added in later tasks.
class PostmanJamesSvg extends StatelessWidget {
  const PostmanJamesSvg({
    super.key,
    this.size = 120,
    this.isTalking = false,
    this.showStarEyes = false,
  });

  final double size;
  final bool isTalking;
  final bool showStarEyes;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.asset(
        'assets/postman_james.svg',
        width: size,
        height: size,
        fit: BoxFit.contain,
      ),
    );
  }
}
