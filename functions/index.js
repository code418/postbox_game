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

const getPoints = function(monarch){
    /*
                        EIIR: 2
                        GR: 4
                        GVR: 4
                        GVIR: 4
                        VR: 7
                        EVIIR: 9
                        EVIIIR: 12
                        */
    let points = 0;
    switch (monarch){
    case 'GR':
    case 'GVR':
    case 'GVIR':
        points = 4;
        break;
    case 'VR':
        points = 7;
        break;
    case 'EVIIR':
        points = 9;
        break;
    case 'EVIIIR':
        points = 12;
        break;
    default:
        points = 2;
        break;
    }
    return points;
};

const lookupPostboxes = async function(lat,lng,meters){
    const center = new geofirex.GeoFirePoint(admin, lat, lng);

    const json = {'postboxes':{},'counts':{'total':0},'points':{'max':0,'min':0},'compass':{}};
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
                        json.points.max += getPoints(data.monarch);
                        json.points.min += getPoints(data.monarch);
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
                    json.postboxes[document_.id] = data;
                }
            });
        });
    }
    return json;
};

exports.startScoring = functions.https.onCall(async (data, context) => {
    const {lat,lng,userid} = data;

    const results = await lookupPostboxes(lat,lng,20);

    const json = {found:false, claims: []};
    const claims = [];
    json.found = results.counts.total > 0;

    if (json.found){
        const keys = Object.keys(results.postboxes);
        for (const key of keys){
            const postbox = results.postboxes[key];
            const data = {
                userid,
                timestamp: admin.firestore.Timestamp.now(),
                validated:false,
                postboxes: `/postboxes/${key}`,
            };

            if (typeof postbox.monarch !== 'undefined'){
                data.monarch = postbox.monarch;
                data.points = getPoints(data.monarch);
            }
            
            claims.push(database.collection('claims').add(data));            
        }
        json.claims = await Promise.all(claims);
    }
    
    return json;
});

exports.nearbyPostboxes = functions.https.onCall(async (data, context) => {
    const {lat,lng,meters} = data;

    const json = await lookupPostboxes(lat,lng,meters);

    return json;
});
  