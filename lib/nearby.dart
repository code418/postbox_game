import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import './compass.dart';

enum NearbyStage { initial, searching, results }

class Nearby extends StatefulWidget {
  @override
  NearbyState createState() => NearbyState();
}

class NearbyState extends State<Nearby> {
  double _lat = 0;
  double _lng = 0;
  int _count = 0;
  int _maxPoints = 0;
  int _minPoints = 0;
  int _EIIR = 0;
  int _GR = 0;
  int _VR = 0;
  int _EVIIR = 0;
  int _EVIIIR = 0;

  int nne = 0;
  int ne = 0;
  int ene = 0;
  int e = 0;
  int ese = 0;
  int se = 0;
  int sse = 0;
  int s = 0;
  int ssw = 0;
  int sw = 0;
  int wsw = 0;
  int w = 0;
  int wnw = 0;
  int nw = 0;
  int nnw = 0;
  int n = 0;

  double _direction;
  NearbyStage currentStage = NearbyStage.initial;

  @override
  void initState() {
    super.initState();
    FlutterCompass.events.listen((double direction) {
      setState(() {
        _direction = direction;
      });
    });
  }

  final HttpsCallable callable = CloudFunctions.instance
      .getHttpsCallable(functionName: 'nearbyPostboxes')
        ..timeout = const Duration(seconds: 30);
  Future getPosition() async {
    Position position = await Geolocator()
        .getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    return position;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text("Postboxes nearby"),
        ),
        body: OrientationBuilder(
          builder: (context, orientation) {
            return GridView.count(
              // Create a grid with 2 columns in portrait mode, or 3 columns in
              // landscape mode.
              crossAxisCount: orientation == Orientation.portrait ? 1 : 2,
              // Generate 100 Widgets that display their index in the List
              children: getCustomContainer(),
            );
          },
        ));
  }

  List<Widget> getCustomContainer() {
    switch (currentStage) {
      case NearbyStage.initial:
        return _initialList();
      case NearbyStage.searching:
        return _loadingList();
      case NearbyStage.results:
        return _resultsList();
    }
  }

  List<Widget> _initialList() => [_geolocateButton('Find nearby postboxes')];

  List<Widget> _loadingList() => [Text('Searching nearby location...')];

  List<Widget> _resultsList() => [
        _buildList(),
        new Transform.rotate(
          angle: ((_direction ?? 0) * (pi / 180) * -1),
          child: Compass(
              n: n,
              nne: nne,
              ne: ne,
              ene: ene,
              e: e,
              ese: ese,
              se: se,
              sse: ssw,
              s: s,
              ssw: ssw,
              sw: sw,
              wsw: wsw,
              w: w,
              wnw: wnw,
              nw: nw,
              nnw: nnw,
              rotation: 0 - ((_direction ?? 0) * (pi / 180) * -1)),
        )
      ];

  Widget _geolocateButton(String buttonLabel) => RaisedButton(
        onPressed: () async {
          try {
            setState(() {
              currentStage = NearbyStage.searching;
            });
            Position position = await getPosition();
            final HttpsCallableResult result = await callable.call(
              <String, dynamic>{
                'lat': position.latitude,
                'lng': position.longitude,
                'meters': 800,
              },
            );
            print(result.data);
            print(result.data['compass']);
            setState(() {
              _lat = position.latitude;
              _lng = position.longitude;
              _count = result.data['counts']['total'];
              _maxPoints = result.data['points']['max'];
              _minPoints = result.data['points']['min'];
              currentStage = NearbyStage.results;
              nne = result.data['compass']['NNE'] ?? 0;
               ne =  result.data['compass']['NE'] ?? 0;
               ene =  result.data['compass']['ENE'] ?? 0;
               e =  result.data['compass']['E'] ?? 0;
               ese =  result.data['compass']['ESE'] ?? 0;
               se =  result.data['compass']['SE'] ?? 0;
               sse =  result.data['compass']['SSE'] ?? 0;
               s =  result.data['compass']['S'] ?? 0;
               ssw =  result.data['compass']['SSW'] ?? 0;
               sw =  result.data['compass']['SW'] ?? 0;
               wsw =  result.data['compass']['WSW'] ?? 0;
               w =  result.data['compass']['W'] ?? 0;
               wnw =  result.data['compass']['WNW'] ?? 0;
               nw =  result.data['compass']['NW'] ?? 0;
               nnw =  result.data['compass']['NNW'] ?? 0;
               n =  result.data['compass']['N'] ?? 0;
            });
          } on CloudFunctionsException catch (e) {
            print('caught firebase functions exception');
            print(e.code);
            print(e.message);
            print(e.details);
          } catch (e) {
            setState(() {
              currentStage = NearbyStage.initial;
            });
            print('caught generic exception');
            print(e);
          }
        },
        child: Text(buttonLabel),
      );

  Widget _buildList() {
    List<Widget> list = [
      _geolocateButton('Refresh location'),
      _tile('Postboxes Nearby', '$_count', Icons.location_searching),
    ];
    if (_maxPoints != _minPoints) {
      list.add(
        _tile('Points Available', '$_minPoints - $_maxPoints',
            Icons.arrow_upward),
      );
    } else {
      list.add(
        _tile('Points Available', '$_maxPoints', Icons.arrow_upward),
      );
    }
    return ListView(
      children: list,
    );
  }

  ListTile _tile(String title, String subtitle, IconData icon) => ListTile(
        title: Text(title,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 20,
            )),
        subtitle: Text(subtitle),
        leading: Icon(
          icon,
          color: Colors.blue[500],
        ),
      );
}
