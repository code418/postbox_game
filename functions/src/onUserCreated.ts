import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions/v1";

export const onUserCreated = functions.auth.user().onCreate(async (user) => {
  const displayName =
    user.displayName ||
    (user.email
      ? user.email.split("@")[0]
      : `Player_${user.uid.slice(0, 6)}`);

  await admin.firestore().collection("users").doc(user.uid).set(
    { displayName, email: user.email ?? null, createdAt: admin.firestore.Timestamp.now() },
    { merge: true }
  );
});
