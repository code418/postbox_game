import 'package:flutter/material.dart';
import 'package:animated_text_kit/animated_text_kit.dart';

class Intro extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: Container( child:Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,

          children: <Widget>[PostManJames(),ChatWindow()],
        )));
  }
}

/// Placeholder for Postman James (was Flare asset james.flr; flare_flutter is incompatible with Dart 3).
/// Can be replaced with a Rive animation or image asset later.
class PostManJames extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Icon(Icons.mail, size: 80, color: Theme.of(context).colorScheme.primary),
    );
  }
}

class ChatWindow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250.0,
      child: AnimatedTextKit(
          animatedTexts: [
            TypewriterAnimatedText(
              "Discipline is the best tool",
              textStyle: TextStyle(fontSize: 30.0, fontFamily: "Agne"),
            ),
            TypewriterAnimatedText(
              "Design first, then code",
              textStyle: TextStyle(fontSize: 30.0, fontFamily: "Agne"),
            ),
            TypewriterAnimatedText(
              "Do not patch bugs out, rewrite them",
              textStyle: TextStyle(fontSize: 30.0, fontFamily: "Agne"),
            ),
            TypewriterAnimatedText(
              "Do not test bugs out, design them out",
              textStyle: TextStyle(fontSize: 30.0, fontFamily: "Agne"),
            ),
          ],
          onTap: () {
            debugPrint("Tap Event");
          },
      ),
    );
  }
}