package com.code418.postbox_game.car

import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
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
import kotlinx.coroutines.launch

/** Driver-safe top-N daily leaderboard. Six rows max — well within Auto's
 *  templated-content limit and short enough to read at a glance. */
class LeaderboardCarScreen(carContext: CarContext) : Screen(carContext) {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var job: Job? = null
    private var entries: List<StatsRepository.LeaderboardEntry>? = null
    private var loadFailed: Boolean = false

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                job?.cancel()
                scope.cancel()
            }
        })
        load()
    }

    private fun load() {
        job = scope.launch {
            val data = StatsRepository.fetchDailyLeaderboard()
            entries = data
            loadFailed = data.isEmpty() && !hasNetworkLikely()
            invalidate()
        }
    }

    // Best-effort: we treat an empty result as either "no claims yet" or a
    // load error; the Firestore call itself swallows exceptions so we cannot
    // distinguish. Default to the friendlier "no claims yet" message.
    private fun hasNetworkLikely(): Boolean = true

    override fun onGetTemplate(): Template {
        val data = entries
        val builder = ListTemplate.Builder()
            .setTitle("Daily leaderboard")
            .setHeaderAction(Action.BACK)

        if (data == null) {
            builder.setLoading(true)
            return builder.build()
        }

        val currentUid = FirebaseAuth.getInstance().currentUser?.uid
        val list = ItemList.Builder()
        if (data.isEmpty()) {
            list.addItem(
                Row.Builder()
                    .setTitle("No claims yet today.")
                    .build()
            )
        } else {
            data.take(6).forEachIndexed { idx, entry ->
                val name = if (entry.uid == currentUid) "${entry.displayName} (you)" else entry.displayName
                list.addItem(
                    Row.Builder()
                        .setTitle("#${idx + 1} $name")
                        .addText("${entry.points} pts")
                        .build()
                )
            }
        }
        builder.setSingleList(list.build())
        return builder.build()
    }
}
