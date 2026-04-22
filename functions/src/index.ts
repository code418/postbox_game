import "./adminInit";
import { nearbyPostboxes } from "./nearbyPostboxes";
import { startScoring } from "./startScoring";
import { onUserCreated } from "./onUserCreated";
import { updateDisplayName } from "./updateDisplayName";
import { newDayScoreboard } from "./newDayScoreboard";
import { registerFcmToken, onFriendAdded } from "./_notifications";
import { userClaimHistory } from "./userClaimHistory";

export {
  nearbyPostboxes,
  startScoring,
  onUserCreated,
  updateDisplayName,
  newDayScoreboard,
  registerFcmToken,
  onFriendAdded,
  userClaimHistory,
};
