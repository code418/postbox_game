package com.code418.postbox_game.car

import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.model.Template
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** Driver-safe stats pane with a single primary action.
 *
 *  Shows lifetime points, unique boxes, current streak, and today's rank.
 *  Tapping "Claim nearby postbox" runs [ClaimAction] (location → cloud
 *  function); tapping "Leaderboard" pushes [LeaderboardCarScreen].
 *
 *  The whole flow lives on this one screen and updates via [invalidate]. To stay
 *  within Android Auto's five-templates-per-task quota, every render must be a
 *  *refresh*: [onGetTemplate] always returns the SAME PaneTemplate shape (built
 *  by [buildHomeTemplate]) and only the rows' secondary text changes between
 *  phases. Returning a different template type per phase would burn a step on
 *  each claim and trip "This task cannot be completed while driving". */
class HomeCarScreen(carContext: CarContext) : Screen(carContext) {

    private enum class Phase { Idle, Working, Done, Error, SignedOut }

    private var phase: Phase = Phase.Idle
    private var message: String = "Tap to scan for nearby postboxes."
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var pending: Job? = null
    private var statsJob: Job? = null
    private var leaderboardJob: Job? = null

    private var stats: StatsRepository.UserStats? = null
    private var dailyEntries: List<StatsRepository.LeaderboardEntry>? = null

    /** The account [statsJob] is streaming. `users/{uid}` is readable by any
     *  signed-in user, so a listener left on the previous account keeps
     *  succeeding: without this the pane went on showing (and live-updating)
     *  the last account's points and streak after a switch on a shared phone. */
    private var observedUid: String? = null

    /** Re-renders on any sign-in, sign-out or switch; [refreshAuthPhase]
     *  notices the new uid and re-arms the observers. */
    private val authListener = FirebaseAuth.AuthStateListener { invalidate() }

    init {
        FirebaseAuth.getInstance().addAuthStateListener(authListener)
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                FirebaseAuth.getInstance().removeAuthStateListener(authListener)
                pending?.cancel()
                statsJob?.cancel()
                leaderboardJob?.cancel()
                scope.cancel()
            }
        })
        startStatsObserver()
        refreshLeaderboard()
    }

    private fun startStatsObserver() {
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        observedUid = uid
        statsJob?.cancel()
        stats = null
        if (uid == null) return
        statsJob = scope.launch {
            StatsRepository.observeUserStats(uid).collectLatest {
                stats = it
                invalidate()
            }
        }
    }

    private fun refreshLeaderboard() {
        leaderboardJob?.cancel()
        leaderboardJob = scope.launch {
            dailyEntries = StatsRepository.fetchDailyLeaderboard()
            invalidate()
        }
    }

    override fun onGetTemplate(): Template {
        refreshAuthPhase()
        val s = stats
        // `message` already tracks the right status text for every phase (set
        // alongside `phase` in triggerClaim/refreshAuthPhase), so it is the
        // single status channel the refresh-safe pane needs.
        val state = HomeUiState(
            statusMessage = message,
            lifetimePoints = s?.lifetimePoints,
            uniqueBoxes = s?.uniquePostboxesClaimed,
            streakLabel = streakLabel(s?.streak),
            rankLabel = rankLabel(),
        )
        return buildHomeTemplate(
            state,
            onClaim = { triggerClaim() },
            onLeaderboard = { screenManager.push(LeaderboardCarScreen(carContext)) },
        )
    }

    private fun streakLabel(streak: Int?): String = when {
        streak == null || streak <= 0 -> "—"
        streak == 1 -> "1 day"
        else -> "$streak days"
    }

    private fun rankLabel(): String {
        val list = dailyEntries ?: return "Loading…"
        if (list.isEmpty()) return "Not ranked yet"
        val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return "—"
        val idx = list.indexOfFirst { it.uid == uid }
        return if (idx < 0) "Not in top ${list.size}" else "#${idx + 1} of ${list.size}"
    }

    private fun refreshAuthPhase() {
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        if (uid != observedUid) {
            // Any change of account, including one that never passed through
            // a rendered signed-out state: never keep the last one's stats.
            startStatsObserver()
            refreshLeaderboard()
        }
        val signedIn = uid != null
        if (!signedIn && phase != Phase.SignedOut) {
            phase = Phase.SignedOut
            message = "Sign in on your phone to start claiming postboxes."
        } else if (signedIn && phase == Phase.SignedOut) {
            phase = Phase.Idle
            message = "Tap to scan for nearby postboxes."
        }
    }

    private fun triggerClaim() {
        if (pending?.isActive == true) return
        if (phase == Phase.SignedOut) return
        phase = Phase.Working
        message = "Scanning for postboxes nearby…"
        invalidate()

        pending = scope.launch {
            val outcome = ClaimAction(carContext).run()
            when (outcome) {
                is ClaimAction.Outcome.Claimed -> {
                    phase = Phase.Done
                    val suffix = if (outcome.count == 1) "postbox" else "postboxes"
                    message = "Claimed ${outcome.count} $suffix (+${outcome.points} pts)"
                    CarToast.makeText(carContext, message, CarToast.LENGTH_LONG).show()
                    refreshLeaderboard()
                }
                is ClaimAction.Outcome.Empty -> {
                    phase = Phase.Done
                    message = "No unclaimed postboxes in range. Try somewhere new!"
                }
                is ClaimAction.Outcome.AlreadyClaimedToday -> {
                    phase = Phase.Done
                    message = "You've already claimed these today."
                }
                is ClaimAction.Outcome.TooFast -> {
                    phase = Phase.Error
                    message = "You're travelling too fast — slow down before claiming again."
                }
                is ClaimAction.Outcome.NotSignedIn -> {
                    phase = Phase.SignedOut
                    message = "Sign in on your phone to start claiming postboxes."
                }
                is ClaimAction.Outcome.UnderMaintenance -> {
                    phase = Phase.Error
                    message = "Claiming is paused for maintenance. Try again shortly."
                }
                is ClaimAction.Outcome.Error -> {
                    phase = Phase.Error
                    message = outcome.display
                }
            }
            invalidate()
        }
    }
}
