import 'package:flutter/material.dart';
import 'package:flare_flutter/flare_actor.dart';
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
class PostManJames extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FlareActor("assets/james.flr", alignment:Alignment.center, fit:BoxFit.contain, animation:"idle");
  }
}

class ChatWindow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250.0,
      child: TypewriterAnimatedTextKit(
          onTap: () {
            print("Tap Event");
          },
          text: [
            "Discipline is the best tool",
            "Design first, then code",
            "Do not patch bugs out, rewrite them",
            "Do not test bugs out, design them out",
          ],
          textStyle: TextStyle(
              fontSize: 30.0,
              fontFamily: "Agne"
          ),
          textAlign: TextAlign.start,
          //alignment: AlignmentDirectional.topStart // or Alignment.topLeft
      ),
    );
  }
}