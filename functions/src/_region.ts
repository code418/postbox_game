import { setGlobalOptions } from "firebase-functions/v2";

// UK-only audience reading the eur3 Firestore: pin every Cloud Function to
// europe-west2 so round-trips stay in-region. setGlobalOptions covers all v2
// functions (callables + scheduler); the v1 triggers reference FUNCTION_REGION
// directly via .region(). See ROADMAP v1.3 (us-central1 -> europe-west2).
//
// Imported first in index.ts so setGlobalOptions runs before any function
// module is evaluated (and therefore before each function is defined).
export const FUNCTION_REGION = "europe-west2";

// v1 (Gen1) Firestore triggers must run in the region matching the database's
// location, and the eur3 multi-region's Gen1 trigger region is europe-west1
// (NOT europe-west2). onFriendAdded is pinned here; deploying it to
// europe-west2 fails with "...is in region eur3-europe-west1 which is not
// supported". (Auth triggers like onUserCreated are global and stay on
// FUNCTION_REGION.)
export const FIRESTORE_TRIGGER_REGION = "europe-west1";

setGlobalOptions({ region: FUNCTION_REGION });
