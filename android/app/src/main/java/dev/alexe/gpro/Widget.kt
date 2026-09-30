package dev.alexe.gpro

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.*
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import androidx.work.*
import java.util.concurrent.TimeUnit

/** The home screen tile: account value, health and both prices, nothing else. */
class GproWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = runCatching { Repository.load(context) }.getOrNull()
        provideContent { GlanceTheme { Body(snapshot) } }
    }

    @Composable
    private fun Body(snapshot: Snapshot?) {
        Column(
            GlanceModifier.fillMaxSize()
                .background(androidx.glance.unit.ColorProvider(androidx.compose.ui.graphics.Color(0xFF15171C)))
                .cornerRadius(20.dp)
                .padding(14.dp)
                .clickable(actionStartActivity<MainActivity>()),
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            if (snapshot == null) {
                Text("—", style = TextStyle(color = white(0.5f), fontSize = 16.sp))
                return@Column
            }

            val account = snapshot.now
            Row(verticalAlignment = Alignment.Vertical.Bottom) {
                Text(
                    money(account.equity),
                    style = TextStyle(color = white(1f), fontSize = 24.sp, fontWeight = FontWeight.Bold),
                )
                Spacer(GlanceModifier.width(6.dp))
                Text(
                    "${account.health.toInt()}%",
                    style = TextStyle(color = healthColor(account.health), fontSize = 13.sp,
                        fontWeight = FontWeight.Medium),
                )
            }
            Text(
                signed(account.result),
                style = TextStyle(color = trendColor(account.result >= 0), fontSize = 14.sp,
                    fontWeight = FontWeight.Medium),
            )
            Spacer(GlanceModifier.height(8.dp))
            Row {
                snapshot.quotes.forEach { quote ->
                    Column(GlanceModifier.defaultWeight()) {
                        Text(quote.symbol, style = TextStyle(color = white(0.45f), fontSize = 10.sp))
                        Text(
                            String.format("%.2f", quote.price),
                            style = TextStyle(color = white(0.95f), fontSize = 15.sp,
                                fontWeight = FontWeight.Medium),
                        )
                        Text(
                            String.format("%s%.2f%%", if (quote.changePercent >= 0) "▲" else "▼",
                                Math.abs(quote.changePercent)),
                            style = TextStyle(color = trendColor(quote.changePercent >= 0), fontSize = 11.sp),
                        )
                    }
                }
            }
        }
    }

    private fun white(alpha: Float) =
        ColorProvider(androidx.compose.ui.graphics.Color.White.copy(alpha = alpha))

    private fun trendColor(up: Boolean) = ColorProvider(
        if (up) androidx.compose.ui.graphics.Color(0xFF3ECF7E)
        else androidx.compose.ui.graphics.Color(0xFFE05A50)
    )

    private fun healthColor(health: Double) = ColorProvider(
        when {
            health < 25 -> androidx.compose.ui.graphics.Color(0xFFE05A50)
            health < 45 -> androidx.compose.ui.graphics.Color(0xFFE0A33C)
            else -> androidx.compose.ui.graphics.Color(0xFF3ECF7E)
        }
    )
}

class GproWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = GproWidget()

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        // Fifteen minutes is the floor Android allows for periodic work.
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            "gpro-refresh",
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<RefreshWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build(),
        )
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        WorkManager.getInstance(context).cancelUniqueWork("gpro-refresh")
    }
}

class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        GproWidget().updateAll(applicationContext)
        return Result.success()
    }
}
