// The Cloud Functions for Firebase SDK to create Cloud Functions and setup triggers.
const functions = require('firebase-functions');

// The Firebase Admin SDK to access the Firebase Realtime Database.
const admin = require('firebase-admin');
admin.initializeApp();

const database = admin.firestore();

const geofirex = require('geofirex');

const geolib = require('geolib');


const setPrecision = function(km) {
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
};

exports.nearbyPostboxes = functions.https.onCall(async (data, context) => {
    const {lat,lng,meters} = data;

    const center = new geofirex.GeoFirePoint(admin, lat, lng);

    const json = {'postboxes':[],'counts':{'total':0},'points':{'max':0,'min':0},'compass':{},'debug':data};
    if (meters && lat && lng){
        const queries = [];
        const radius = meters/1000;
        const precision = setPrecision(radius);
        const centerHash = center.hash.substr(0, precision);
        const areas = geofirex.GeoFirePoint.neighbors(centerHash).concat(centerHash);
            
    
        const postboxReference = database.collection('postboxes');
        for (const geohash of areas) {
            const end = `${geohash}~`;
            const query = postboxReference
                .orderBy('position.geohash')
                .startAt(geohash)
                .endAt(end);
                
            queries.push(query.get());
        }
  
        const resultArray = await Promise.all(queries);
  
        resultArray.forEach(results => {
            results.forEach(document_ => {
                const data = document_.data();
                const distance = geolib.getDistance(
                    {latitude: lat, longitude: lng},
                    {latitude: data.position.geopoint._latitude, longitude: data.position.geopoint._longitude}
                );
                if (distance <= meters){
                    json.counts.total++;
                    if (typeof data.monarch !== 'undefined'){
                        /*
                        EIIR: 2
                        GR: 4
                        GVR: 4
                        GVIR: 4
                        VR: 7
                        EVIIR: 9
                        EVIIIR: 12
                        */
                        switch (data.monarch){
                        case 'GR':
                        case 'GVR':
                        case 'GVIR':
                            json.points.max += 4;
                            json.points.min += 4;
                            break;
                        case 'VR':
                            json.points.max += 7;
                            json.points.min += 7;
                            break;
                        case 'EVIIR':
                            json.points.max += 9;
                            json.points.min += 9;
                            break;
                        case 'EVIIIR':
                            json.points.max += 12;
                            json.points.min += 12;
                            break;
                        default:
                            json.points.max += 2;
                            json.points.min += 2;
                            break;
                        }
                        if (typeof json.counts[data.monarch] !== 'undefined'){
                            json.counts[data.monarch]++;
                        } else {
                            json.counts[data.monarch] = 1;
                        }
                    } else {
                        json.points.max += 12;
                        json.points.min += 2;
                    }
                    const distance = geolib.getDistance(
                        {latitude: lat, longitude: lng},
                        {latitude: data.position.geopoint._latitude, longitude: data.position.geopoint._longitude}
                    );
                    data.distance = distance;
                    data.compass = geolib.getCompassDirection(
                        {latitude: lat, longitude: lng},
                        {latitude: data.position.geopoint._latitude, longitude: data.position.geopoint._longitude}
                    );
                    const compasspos = data.compass.exact;
                    if (typeof compasspos !== 'undefined'){
                        if (typeof json.compass[compasspos] !== 'undefined'){
                            json.compass[compasspos]++;
                        } else {
                            json.compass[compasspos] = 1;
                        }
                    }
                    json.postboxes.push(data);
                }
            });
        });
    }

    return json;
});
  