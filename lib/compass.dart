import 'package:flutter/material.dart';

class Compass extends StatelessWidget {
  final int nne;
  final int ne;
  final int ene;
  final int e;
  final int ese;
  final int se;
  final int sse;
  final int s;
  final int ssw;
  final int sw;
  final int wsw;
  final int w;
  final int wnw;
  final int nw;
  final int nnw;
  final int n;

  final double rotation;

  const Compass(
      {Key key,
      this.nne = 0,
      this.ne = 0,
      this.ene = 0,
      this.e = 0,
      this.ese = 0,
      this.se = 0,
      this.sse = 0,
      this.s = 0,
      this.ssw = 0,
      this.sw = 0,
      this.wsw = 0,
      this.w = 0,
      this.wnw = 0,
      this.nw = 0,
      this.nnw = 0,
      this.n = 0,
      this.rotation = 0})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
            top: 0, left: 0, child: new Image.asset('assets/compass.png')),
        Positioned(
          bottom: 0,
          right: 0,
          child: new CircleButton(content: se, size: 20, rotation: rotation),
        ),
        Positioned(
          top: 0,
          left: 0,
          child: new CircleButton(content: nw, size: 20, rotation: rotation),
        ),
        Positioned(
          top: 0,
          left: 50,
          right: 50,
          child: new CircleButton(content: n, size: 20, rotation: rotation),
        ),
        Positioned(
          bottom: 0,
          left: 50,
          right: 50,
          child: new CircleButton(content: s, size: 20, rotation: rotation),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          child: new CircleButton(content: sw, size: 20, rotation: rotation),
        ),
        Positioned(
          top: 50,
          bottom: 50,
          left: 0,
          child: new CircleButton(content: w, size: 20, rotation: rotation),
        ),
        Positioned(
          top: 50,
          bottom: 50,
          right: 0,
          child: new CircleButton(content: e, size: 20, rotation: rotation),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: new CircleButton(content: ne, size: 20, rotation: rotation),
        ),
        Positioned(
          top: 0,
          left: 50,
          child: new CircleButton(content: nnw, size: 20, rotation: rotation),
        ),
        Positioned(
          top: 0,
          right: 50,
          child: new CircleButton(content: nne, size: 20, rotation: rotation),
        ),
        Positioned(
          top: 50,
          left: 0,
          child: new CircleButton(content: wnw, size: 20, rotation: rotation),
        ),
        Positioned(
          top: 50,
          right: 0,
          child: new CircleButton(content: ene, size: 20, rotation: rotation),
        ),
        Positioned(
          bottom: 0,
          right: 50,
          child: new CircleButton(content: sse, size: 20, rotation: rotation),
        ),
        Positioned(
          bottom: 0,
          left: 50,
          child: new CircleButton(content: ssw, size: 20, rotation: rotation),
        ),
        Positioned(
          bottom: 50,
          right: 0,
          child: new CircleButton(content: ese, size: 20, rotation: rotation),
        ),
        Positioned(
          bottom: 50,
          left: 0,
          child: new CircleButton(content: wsw, size: 20, rotation: rotation),
        ),
      ],
    );
  }
}

class CircleButton extends StatelessWidget {
  final int content;
  final double size;
  final double rotation;

  const CircleButton({Key key, this.content, this.size, this.rotation = 0})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return content <= 0
        ? new Container()
        : Container(
            width: size,
            height: size,
            decoration: new BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
            child: Center(
                child: new Transform.rotate(
                    angle: rotation,
                    child: new Text(content.toString(),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white)))),
          );
  }
}
