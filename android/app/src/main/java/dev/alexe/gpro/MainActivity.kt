package dev.alexe.gpro

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.text.NumberFormat
import java.util.Locale

private val UP = Color(0xFF3ECF7E)
private val DOWN = Color(0xFFE05A50)
private val SURFACE = Color(0xFF15171C)
private val CARD = Color(0xFF1D2026)

fun trend(up: Boolean) = if (up) UP else DOWN

fun money(value: Double): String =
    NumberFormat.getIntegerInstance(Locale.FRANCE).format(value.toLong()).replace(' ', ' ')

fun signed(value: Double) = (if (value >= 0) "+" else "−") + money(Math.abs(value))

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { MaterialTheme(colorScheme = darkColorScheme(background = SURFACE)) { Screen() } }
    }
}

@Composable
private fun Screen() {
    val context = LocalContext.current
    var url by remember { mutableStateOf(Repository.gistUrl(context)) }
    var snapshot by remember { mutableStateOf<Snapshot?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var settings by remember { mutableStateOf(false) }

    // Prices move constantly, so the screen refreshes itself while it is open.
    LaunchedEffect(url) {
        if (url.isBlank()) return@LaunchedEffect
        while (true) {
            runCatching { Repository.load(context) }
                .onSuccess { snapshot = it; error = null }
                .onFailure { error = it.message ?: it.javaClass.simpleName }
            delay(15_000)
        }
    }

    Column(
        Modifier.fillMaxSize().background(SURFACE).verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp).padding(top = 48.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // Without a sync URL there is nothing to show, so the field is the screen.
        if (url.isBlank()) {
            Setup { saved -> Repository.setGistUrl(context, saved); url = saved }
            return@Column
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("GPRO ${BuildConfig.VERSION_NAME}", color = Color.White.copy(alpha = 0.5f),
                fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { settings = true }) {
                Text("sync", color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp)
            }
        }

        val current = snapshot
        when {
            current != null -> {
                Hero(current)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    current.quotes.forEach { QuoteTile(it, Modifier.weight(1f)) }
                }
                Positions(current)
                current.atTargets?.let { Targets(current, it) }
                Text(
                    "updated ${current.sync.generated.take(16).replace('T', ' ')}",
                    color = Color.White.copy(alpha = 0.3f), fontSize = 10.sp,
                )
            }
            error != null -> Text(error!!, color = DOWN, fontSize = 13.sp)
            else -> Text("Loading…", color = Color.White.copy(alpha = 0.5f), fontSize = 14.sp)
        }
    }

    if (settings) {
        SettingsDialog(
            current = url,
            onSave = { saved -> Repository.setGistUrl(context, saved); url = saved; settings = false },
            onDismiss = { settings = false },
        )
    }
}

@Composable
private fun Setup(onSave: (String) -> Unit) {
    var value by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Sync URL", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        // Shown so a stale install is obvious at a glance.
        Text("build ${BuildConfig.VERSION_NAME}", color = Color.White.copy(alpha = 0.35f), fontSize = 11.sp)
        Text(
            "Run ./tools/publish-sync.py on the Mac and paste the raw gist URL it prints.",
            color = Color.White.copy(alpha = 0.5f), fontSize = 13.sp,
        )
        OutlinedTextField(
            value = value,
            onValueChange = { value = it },
            label = { Text("https://gist.githubusercontent.com/…") },
            modifier = Modifier.fillMaxWidth(),
        )
        Button(onClick = { if (value.isNotBlank()) onSave(value.trim()) }) { Text("Save") }
    }
}

@Composable
private fun Hero(snapshot: Snapshot) {
    val account = snapshot.now
    val invested = snapshot.sync.netDeposits
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(money(account.equity), color = Color.White,
                        fontSize = 34.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.width(6.dp))
                    Text(snapshot.sync.accountCurrency, color = Color.White.copy(alpha = 0.45f),
                        fontSize = 13.sp, modifier = Modifier.padding(bottom = 5.dp))
                }
                Text(signed(account.result), color = trend(account.result >= 0),
                    fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
            HealthRing(account.health)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            Metric("margin", money(account.margin))
            Metric("free", money(account.freeFunds))
            if (invested != 0.0) {
                Metric("overall", signed(account.equity - invested), trend(account.equity >= invested))
            }
        }
    }
}

@Composable
private fun Metric(caption: String, value: String, color: Color = Color.White) {
    Column {
        Text(value, color = color, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace)
        Text(caption, color = Color.White.copy(alpha = 0.35f), fontSize = 10.sp)
    }
}

@Composable
private fun HealthRing(health: Double) {
    val color = when {
        health < 25 -> DOWN
        health < 45 -> Color(0xFFE0A33C)
        else -> UP
    }
    Box(Modifier.size(56.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            progress = { (health / 100).toFloat().coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxSize(),
            color = color,
            trackColor = Color.White.copy(alpha = 0.12f),
            strokeWidth = 5.dp,
            strokeCap = StrokeCap.Round,
        )
        Text("${health.toInt()}", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun QuoteTile(quote: Quote, modifier: Modifier = Modifier) {
    val up = quote.changePercent >= 0
    Column(
        modifier.clip(RoundedCornerShape(14.dp)).background(CARD).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(quote.symbol, color = Color.White.copy(alpha = 0.5f),
            fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        Text(String.format(Locale.US, "%.2f", quote.price), color = Color.White,
            fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
        Text(String.format(Locale.US, "%s%.2f%%", if (up) "▲" else "▼", Math.abs(quote.changePercent)),
            color = trend(up), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Positions(snapshot: Snapshot) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(CARD).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        snapshot.now.holdings.forEach { holding ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(holding.symbol, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.width(8.dp))
                Text("${holding.lots}", color = Color.White.copy(alpha = 0.35f), fontSize = 10.sp,
                    modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.08f))
                        .padding(horizontal = 6.dp, vertical = 2.dp))
                Spacer(Modifier.weight(1f))
                Text(signed(holding.result), color = trend(holding.result >= 0),
                    fontSize = 14.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
            }
        }
    }
}

@Composable
private fun Targets(snapshot: Snapshot, scenario: Account) {
    val delta = scenario.equity - snapshot.now.equity
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(CARD).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("AT TARGETS", color = Color.White.copy(alpha = 0.35f),
            fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(money(scenario.equity), color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.width(10.dp))
            Text(signed(delta), color = trend(delta >= 0), fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(bottom = 3.dp))
        }
        scenario.holdings.forEach { holding ->
            Row {
                Text(holding.symbol, color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
                Spacer(Modifier.width(8.dp))
                Text(snapshot.sync.targets[holding.symbol]?.let { String.format(Locale.US, "%.2f", it) } ?: "—",
                    color = Color.White.copy(alpha = 0.35f), fontSize = 12.sp)
                Spacer(Modifier.weight(1f))
                Text(signed(holding.result), color = trend(holding.result >= 0), fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace)
            }
        }
    }
}

@Composable
private fun SettingsDialog(current: String, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var url by remember { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Sync URL") },
        text = {
            OutlinedTextField(value = url, onValueChange = { url = it }, singleLine = false,
                label = { Text("raw gist URL") })
        },
        confirmButton = { TextButton(onClick = { onSave(url.trim()) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
