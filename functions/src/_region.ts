import { setGlobalOptions } from "firebase-functions/v2";

// UK-only audience reading the eur3 Firestore: pin every Cloud Function to
// europe-west2 so round-trips stay in-region. setGlobalOptions covers all v2
// functions (callables + scheduler); the v1 triggers reference FUNCTION_REGION
// directly via .region(). See ROADMAP v1.3 (us-central1 -> europe-west2).
//
// Imported first in index.ts so setGlobalOptions runs before any function
// module is evaluated (and therefore before each function is defined).
export const FUNCTION_REGION = "europe-west2";

setGlobalOptions({ region: FUNCTION_REGION });
