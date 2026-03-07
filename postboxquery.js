// Init Firebase
var firebase = require("firebase/app");
require("firebase/firestore");
var config = {
    "apiKey": "AIzaSyAl4uzvsZ1m05Dw0U19vkcq6b1IqYHJOdA",
    "databaseURL": "https://the-postbox-game.firebaseio.com",
    "storageBucket": "the-postbox-game.appspot.com",
    "authDomain": "the-postbox-game.firebaseapp.com",
    "messagingSenderId": "176793005702",
    "projectId": "the-postbox-game"
  };
  firebase.initializeApp(config);
  var db = firebase.firestore();

// Init GeoFireX
var geofirex = require('geofirex');

const setPrecsion = function(km) {
    switch (true) {
        case km <= 0.00477:
            return 9;
        case km <= 0.0382:
            return 8;
        case km <= 0.153:
            return 7;
        case km <= 1.22:
            return 6;
        case km <= 4.89:
            return 5;
        case km <= 39.1:
            return 4;
        case km <= 156:
            return 3;
        case km <= 1250:
            return 2;
        default:
            return 1;
    }
    // 1	≤ 5,000km	×	5,000km
    // 2	≤ 1,250km	×	625km
    // 3	≤ 156km	×	156km
    // 4	≤ 39.1km	×	19.5km
    // 5	≤ 4.89km	×	4.89km
    // 6	≤ 1.22km	×	0.61km
    // 7	≤ 153m	×	153m
    // 8	≤ 38.2m	×	19.1m
    // 9	≤ 4.77m	×	4.77m
}


const lat = 51.5432448;
const lng = -2.41827839;
const center = new geofirex.GeoFirePoint(firebase, lat, lng);


let json = {'postboxes':[]};
    const radius = 0.8;
    const field = 'position';
    var precision = setPrecsion(radius);
    var centerHash = center.hash.substr(0, precision);
    var areas = geofirex.GeoFirePoint.neighbors(centerHash).concat(centerHash);
        

        var postboxRef = db.collection('postboxes');
        var queries = [];
        const start = async () => {
        for (const geohash of areas) {
            console.log(geohash);
            let end = geohash + '~';
            var query = postboxRef
            .orderBy("position.geohash")
            .startAt(geohash)
            .endAt(end);
            
            queries.push(query.get());
        }

        var resultArray = await Promise.all(queries);

        resultArray.forEach(results => {
            results.forEach(doc => {
                json.postboxes.push(doc.data());
            });
        });

            console.log(json);
        };

    start();
        


    
/*
const cities = geo.collection('postboxes');
// lat, long
const point = geo.point(40, -119);

cities.add({ name: 'Phoenix', position: point.data });
*/