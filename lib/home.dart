import 'package:flutter/material.dart';

class Home extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text('Nearby postboxes'),
        ),
        body: Center(
          child: HomeMenu(),
        ));
  }
}

class HomeMenu extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: GridView.count(
      primary: false,
      padding: const EdgeInsets.all(20.0),
      crossAxisSpacing: 10.0,
      crossAxisCount: 2,
      
      children: <Widget>[
        HomeMenuButton(
          text: 'Nearby Postboxes',
          icon: Icon(Icons.location_searching),
          onPressed: () {
            Navigator.pushNamed(context, '/nearby');
          },
        ),
        HomeMenuButton(
          text: 'Claim Postbox',
          icon: Icon(Icons.location_searching),
          onPressed: () {
            Navigator.pushNamed(context, '/nearby');
          },
        ),
        /*HomeMenuButton(
          text: 'Upload Photo',
          onPressed: () {
            Navigator.pushNamed(context, '/upload');
          },
        ),*/
        /*HomeMenuButton(
          text: 'Upload Photo',
          onPressed: () {
            Navigator.pushNamed(context, '/upload');
          },
        ),
        HomeMenuButton(
          text: 'Leaderboards',
          onPressed: () {
            Navigator.pushNamed(context, '/nearby');
          },
        ),
        HomeMenuButton(
          text: 'Register',
          onPressed: () {
            Navigator.pushNamed(context, '/register');
          },
        ),
        HomeMenuButton(
          text: 'Login',
          onPressed: () {
            Navigator.pushNamed(context, '/login');
          },
        ),
        */
      ],
    ));
  }
}

class HomeMenuButton extends StatelessWidget {
  const HomeMenuButton(
      {Key key, this.text = 'Test', this.icon, this.child, this.onPressed})
      : super(key: key);

  final String text;

  final Icon icon;

  final Widget child;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: this.onPressed,
      label: Text(this.text),
      icon: this.icon,
    );
  }
}
