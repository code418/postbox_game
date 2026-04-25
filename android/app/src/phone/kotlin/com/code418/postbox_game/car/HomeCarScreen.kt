package com.code418.postbox_game.car

import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.CarColor
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Template
import com.google.firebase.auth.FirebaseAuth
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Driver-safe single-action screen.
 *
 *  Follows Android Auto UX rules: one primary action, no free text input,
 *  short messages. Tapping "Claim nearby postbox" runs [ClaimAction] which
 *  fetches the car's current location and calls the `startScoring` Cloud
 *  Function. Results update the on-screen message and emit a car toast. */
class HomeCarScreen(carContext: CarContext) : Screen(carContext) {

    private enum class Phase { Idle, Working, Done, Error, SignedOut }

    private var phase: Phase = Phase.Idle
    private var message: String = "Tap to scan for nearby postboxes."
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var pending: Job? = null

    init {
        // Cancel any in-flight claim if the host tears down the screen.
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                pending?.cancel()
                scope.cancel()
            }
        })
    }

    override fun onGetTemplate(): Template {
        refreshAuthPhase()
        val builder = MessageTemplate.Builder(message)
            .setTitle("Postbox Quick Claim")
            .setHeaderAction(Action.APP_ICON)

        when (phase) {
            Phase.Idle, Phase.Done, Phase.Error -> {
                builder.addAction(
                    Action.Builder()
                        .setTitle("Claim nearby postbox")
                        .setBackgroundColor(CarColor.RED)
                        .setOnClickListener { triggerClaim() }
                        .build()
                )
            }
            Phase.Working -> {
                // Intentionally no action while awaiting the Cloud Function.
                // The message itself conveys that work is in progress.
            }
            Phase.SignedOut -> {
                builder.addAction(
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
            }
        }
        return builder.build()
    }

    private fun refreshAuthPhase() {
        if (FirebaseAuth.getInstance().currentUser == null && phase == Phase.Idle) {
            phase = Phase.SignedOut
            message = "Sign in on your phone to start claiming postboxes."
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
