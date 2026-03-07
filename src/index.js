// Firebase App is always required and must be first
var firebase = require("firebase/app");

// Add additional services that you want to use
//require("firebase/auth");
//require("firebase/database");
require("firebase/firestore");
//require("firebase/messaging");
//require("firebase/functions");

// Comment out (or don't require) services that you don't want to use
// require("firebase/storage");

var config = {
  "apiKey": "AIzaSyAl4uzvsZ1m05Dw0U19vkcq6b1IqYHJOdA",
  "databaseURL": "https://the-postbox-game.firebaseio.com",
  "storageBucket": "the-postbox-game.appspot.com",
  "authDomain": "the-postbox-game.firebaseapp.com",
  "messagingSenderId": "176793005702",
  "projectId": "the-postbox-game"
};
firebase.initializeApp(config);


const db = firebase.firestore();
const settings = {/* your settings... */ timestampsInSnapshots: true};
db.settings(settings);
  // Create a reference to the cities collection
var postboxRef = db.collection("postboxes");
import { GeoFirestore } from 'geofirestore';
const geoFirestore = new GeoFirestore(postboxRef);
// Create a query against the collection.
/*
var query = postboxRef.where("lat", ">", 54).where("lat", "<", 54.1).limit(33);
query.get().then(function(querySnapshot) {
    querySnapshot.forEach(function(doc) {
        // doc.data() is never undefined for query doc snapshots
        console.log(doc.id, " => ", doc.data());
    });
});
*/
var GoogleMapsLoader = require('google-maps'); // only for common js environments
GoogleMapsLoader.KEY = 'AIzaSyAl4uzvsZ1m05Dw0U19vkcq6b1IqYHJOdA';
GoogleMapsLoader.load();
var map;

import geolib from 'geolib';
var fiveminutesm = 420;
GoogleMapsLoader.onLoad(function(google) {
  map = new google.maps.Map(document.getElementById('map'), {
        zoom: 8
      });
navigator.geolocation.getCurrentPosition(
    function(position) {
        var initialPoint = {lat: position.coords.latitude, lon: position.coords.longitude};
        var marker = new google.maps.Marker({
  position: {lat: position.coords.latitude, lng: position.coords.longitude},
  map: map,
  title: 'Me'
});
        map.setCenter({lat:position.coords.latitude, lng:position.coords.longitude});
        var north = geolib.computeDestinationPoint(initialPoint, fiveminutesm, 0);
        var south = geolib.computeDestinationPoint(initialPoint, fiveminutesm, 90);
        var east = geolib.computeDestinationPoint(initialPoint, fiveminutesm, 180);
        var west = geolib.computeDestinationPoint(initialPoint, fiveminutesm, 240);
        console.log(initialPoint);
        console.log(north);
        console.log(south);
        console.log(east);
        console.log(west);
        var bounds = new google.maps.LatLngBounds();
        bounds.extend({lat:north.latitude,lng:north.longitude});
        bounds.extend({lat:south.latitude,lng:south.longitude});
        bounds.extend({lat:east.latitude,lng:east.longitude});
        bounds.extend({lat:west.latitude,lng:west.longitude});
        map.fitBounds(bounds);
        var rectangle = new google.maps.Rectangle({
          strokeColor: '#FF0000',
          strokeOpacity: 0.8,
          strokeWeight: 2,
          fillColor: '#FF0000',
          fillOpacity: 0.35,
          map: map,
          bounds: {
            north: north.latitude,
            south: south.latitude,
            east: east.longitude,
            west: west.longitude
          }
        });
        /*
        const geoQuery = geoFirestore.query({
          center: new firebase.firestore.GeoPoint(position.coords.latitude, position.coords.longitude),
          radius: fiveminutesm
        });
        console.log(geoQuery);
        */

        var query = postboxRef
        .where("lat", "<=", north.latitude)
        .where("lat", ">=", south.latitude)
        //.where("lng", "<=", east.longitude)
        //.where("lng", ">=", west.longitude)
        ;
        query.get().then(function(querySnapshot) {
          console.log(querySnapshot.size);
            querySnapshot.forEach(function(doc) {
                const data = doc.data();
                var marker = new google.maps.Marker({
          position: {lat: data.lat, lng: data.lng},
          map: map,
          title: data.ref
        });


            });
        });

    },
    function() {
        alert('Position could not be determined.')
    },
    {
        enableHighAccuracy: true
    }
);

});
