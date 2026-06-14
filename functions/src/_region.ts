import { setGlobalOptions } from "firebase-functions/v2";

// UK-only audience reading the eur3 Firestore: pin every Cloud Function to
// europe-west2 so round-trips stay in-region. setGlobalOptions covers all v2
// functions (callables + scheduler); the v1 triggers reference FUNCTION_REGION
// directly via .region(). See ROADMAP v1.3 (us-central1 -> europe-west2).
//
// Imported first in index.ts so setGlobalOptions runs before any function
// module is evaluated (and therefore before each function is defined).
export const FUNCTION_REGION = "europe-west2";

// eur3 has no Gen1 Firestore triggers at all (Gen1 deploys fail in every
// region with "...is in region eur3-europe-west1 which is not supported"), so
// onFriendAdded is a 2nd-gen trigger. Eventarc maps the eur3 multi-region to
// europe-west4, so the function must run there — NOT europe-west2/west1.
// (Auth triggers like onUserCreated are global and stay on FUNCTION_REGION.)
export const FIRESTORE_TRIGGER_REGION = "europe-west4";

setGlobalOptions({ region: FUNCTION_REGION });
