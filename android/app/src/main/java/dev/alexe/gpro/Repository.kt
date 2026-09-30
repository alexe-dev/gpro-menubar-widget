package dev.alexe.gpro

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Everything the screens need, fetched together. */
data class Snapshot(
    val sync: Sync,
    val quotes: List<Quote>,
    val now: Account,
    val atTargets: Account?,
)

object Repository {
    const val DEFAULT_GIST =
        "https://gist.githubusercontent.com/alexe-dev/c47be2b5d669d06ec4aaeb2b055f43fa/raw/gpro-sync.json"

    private const val PREFS = "gpro"
    private const val KEY_GIST = "gist"

    fun gistUrl(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_GIST, DEFAULT_GIST)
            ?: DEFAULT_GIST

    fun setGistUrl(context: Context, url: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_GIST, url.trim()).apply()
    }

    suspend fun load(context: Context): Snapshot = withContext(Dispatchers.IO) {
        val sync = Api.sync(gistUrl(context))

        val tickers = (sync.symbols + sync.positions.map { it.symbol }).distinct()
        val quotes = tickers.map { Api.quote(it) }
        val prices = quotes.associate { it.symbol to it.price }

        val pairs = sync.positions.map { it.currency }.distinct()
            .filter { it != sync.accountCurrency }
            .map { "$it${sync.accountCurrency}=X" }
        val fx = pairs.associateWith { Api.quote(it).price }

        val now = Calculator.account(sync, prices, fx)
            ?: error("missing prices")
        val atTargets = if (sync.targets.isEmpty()) null
            else Calculator.account(sync, prices, fx, sync.targets)

        Snapshot(sync, quotes.filter { it.symbol in sync.symbols }, now, atTargets)
    }
}
