package com.code418.postbox_game.car

import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.CarColor
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Pane
import androidx.car.app.model.PaneTemplate
import androidx.car.app.model.Row
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
 *  function); tapping "Leaderboard" pushes [LeaderboardCarScreen]. */
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

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
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
        val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return
        statsJob?.cancel()
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
        return when (phase) {
            Phase.Working, Phase.SignedOut, Phase.Error -> messageTemplate()
            Phase.Idle, Phase.Done -> paneTemplate()
        }
    }

    private fun messageTemplate(): Template {
        val builder = MessageTemplate.Builder(message)
            .setTitle("Postbox Quick Claim")
            .setHeaderAction(Action.APP_ICON)
        when (phase) {
            Phase.SignedOut -> builder.addAction(
                Action.Builder()
                    .setTitle("Open phone app")
                    .setOnClickListener {
                        CarToast.makeText(
                            carContext,
                            "Sign in on your phone first.",
                            CarToast.LENGTH_LONG
                        ).show()
                    }
                    .build()
            )
            Phase.Error -> builder.addAction(
                Action.Builder()
                    .setTitle("Try again")
                    .setBackgroundColor(CarColor.RED)
                    .setOnClickListener { triggerClaim() }
                    .build()
            )
            else -> Unit
        }
        return builder.build()
    }

    private fun paneTemplate(): Template {
        val s = stats
        val pane = Pane.Builder()

        pane.addRow(
            Row.Builder()
                .setTitle("Total points")
                .addText(s?.totalPoints?.toString() ?: "—")
                .build()
        )
        pane.addRow(
            Row.Builder()
                .setTitle("Unique boxes")
                .addText(s?.uniquePostboxesClaimed?.toString() ?: "—")
                .build()
        )
        pane.addRow(
            Row.Builder()
                .setTitle("Daily streak")
                .addText(streakLabel(s?.streak))
                .build()
        )
        pane.addRow(
            Row.Builder()
                .setTitle("Today's rank")
                .addText(rankLabel())
                .build()
        )

        pane.addAction(
            Action.Builder()
                .setTitle("Claim nearby postbox")
                .setBackgroundColor(CarColor.RED)
                .setOnClickListener { triggerClaim() }
                .build()
        )
        pane.addAction(
            Action.Builder()
                .setTitle("Leaderboard")
                .setOnClickListener {
                    screenManager.push(LeaderboardCarScreen(carContext))
                }
                .build()
        )

        return PaneTemplate.Builder(pane.build())
            .setTitle(if (phase == Phase.Done) message else "Postbox Quick Claim")
            .setHeaderAction(Action.APP_ICON)
            .build()
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
        val signedIn = FirebaseAuth.getInstance().currentUser != null
        if (!signedIn && phase != Phase.SignedOut) {
            phase = Phase.SignedOut
            message = "Sign in on your phone to start claiming postboxes."
        } else if (signedIn && phase == Phase.SignedOut) {
            phase = Phase.Idle
            message = "Tap to scan for nearby postboxes."
            startStatsObserver()
            refreshLeaderboard()
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
                is ClaimAction.Outcome.Error -> {
                    phase = Phase.Error
                    message = outcome.display
                }
            }
            invalidate()
        }
    }
}
