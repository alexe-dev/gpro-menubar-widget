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
    // Deliberately empty: a secret gist is unlisted, not private, so its URL is a
    // credential and must not live in a public repository. It is entered on the device.
    const val DEFAULT_GIST = ""

    private const val PREFS = "gpro"
    private const val KEY_GIST = "gist"

    fun gistUrl(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_GIST, DEFAULT_GIST)
            ?: DEFAULT_GIST

    /// Pasting on a phone picks up newlines and stray spaces. A bare gist id is kept as
    /// is — Api.sync resolves it through the API rather than the raw CDN.
    fun normalise(url: String): String {
        val cleaned = url.filterNot { it.isWhitespace() }
        return when {
            cleaned.isEmpty() -> ""
            cleaned.matches(Regex("[0-9a-f]{20,40}")) -> cleaned
            cleaned.startsWith("http://") || cleaned.startsWith("https://") -> cleaned
            else -> "https://$cleaned"
        }
    }

    fun setGistUrl(context: Context, url: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_GIST, normalise(url)).apply()
    }

    suspend fun load(context: Context): Snapshot = withContext(Dispatchers.IO) {
        val url = gistUrl(context)
        require(url.isNotBlank()) { "Set the sync URL first" }
        val sync = Api.sync(url)

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
