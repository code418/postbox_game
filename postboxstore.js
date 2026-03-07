// Init Firebase
var firebase = require("firebase/app");
var postboxes = require('./postboxes.json');
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
  
const _cliProgress = require('cli-progress');
 
// create a new progress bar instance and use shades_classic theme
const bar1 = new _cliProgress.Bar({}, _cliProgress.Presets.shades_classic);

// Init GeoFireX
var geofirex = require('geofirex');
const geo = geofirex.init(firebase);
const postbox_collection = geo.collection('postboxes');
const total = postboxes.elements.length;
bar1.start(total, 0);
let progress = 0;
postboxes.elements.forEach(async (postbox) => {
    if(postbox.type == 'node'){
        if(typeof postbox.id != 'undefined'){
            const point = geo.point(postbox.lat, postbox.lon);
            let postbox_document = {
                overpass_id:postbox.id,
                position: point.data
            }
            const tags = Object.keys(postbox.tags);
            for (let index = 0; index < tags.length; index++) {
                const tag = tags[index];
                const value = postbox.tags[tag];
                switch(tag){
                    case 'ref':
                    postbox_document.reference = value;
                    break;
                    case 'royal_cypher':
                    postbox_document.monarch = value;
                    break;
                }                
            }
            await postbox_collection.add(postbox_document);
        }
    }
    progress++;
    bar1.update(progress);
});
/*
const cities = geo.collection('postboxes');
// lat, long
const point = geo.point(40, -119);

cities.add({ name: 'Phoenix', position: point.data });
*/