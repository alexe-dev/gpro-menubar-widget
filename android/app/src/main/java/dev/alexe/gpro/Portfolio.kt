package dev.alexe.gpro

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** One open book, as the Mac publishes it. */
data class Position(
    val symbol: String,
    val direction: String,
    val units: Double,
    val avgPrice: Double,
    val currency: String,
    val leverage: Double,
    val spread: Double,
    val lots: Int,
) {
    val sign: Double get() = if (direction.equals("Sell", true)) -1.0 else 1.0

    /** A long closes at the bid and is margined at the ask; Yahoo's last trade is near the mid. */
    fun closing(last: Double) = last - sign * spread / 2
    fun marginPrice(last: Double) = last + sign * spread / 2
}

data class Sync(
    val generated: String,
    val accountCurrency: String,
    val cash: Double,
    val deposits: Double,
    val withdrawals: Double,
    val symbols: List<String>,
    val targets: Map<String, Double>,
    val positions: List<Position>,
) {
    val netDeposits: Double get() = deposits - withdrawals
}

data class Quote(
    val symbol: String,
    val price: Double,
    val change: Double,
    val changePercent: Double,
    val currency: String,
    val name: String,
    val session: String,
)

data class Holding(val symbol: String, val lots: Int, val result: Double, val value: Double, val margin: Double)

data class Account(
    val equity: Double,
    val result: Double,
    val margin: Double,
    val health: Double,
    val freeFunds: Double,
    val holdings: List<Holding>,
)

private const val FX_FEE = 0.005

object Api {
    private fun read(url: String): JSONObject {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            setRequestProperty("User-Agent", "Mozilla/5.0")
            instanceFollowRedirects = true
            connectTimeout = 10_000
            readTimeout = 10_000
        }
        // A bare inputStream on an error status throws with the URL as its message, which
        // reads like a broken link rather than the status the server actually returned.
        val status = connection.responseCode
        if (status !in 200..299) {
            val detail = connection.errorStream?.bufferedReader()?.use { it.readText() }?.take(120)
            error("HTTP $status${if (detail.isNullOrBlank()) "" else " · $detail"}")
        }
        return connection.inputStream.bufferedReader().use { JSONObject(it.readText()) }
    }

    /// A gist id, a gist page link or a raw link all end up at the same place. The API is
    /// preferred: raw links go through a CDN that has served stale 404s, the API has not.
    fun sync(source: String): Sync {
        val id = Regex("[0-9a-f]{20,40}").find(source)?.value
        val json = if (id != null && !source.contains("/raw/")) {
            val gist = read("https://api.github.com/gists/$id")
            val files = gist.getJSONObject("files")
            val name = files.keys().asSequence().firstOrNull { it.endsWith(".json") }
                ?: files.keys().next()
            JSONObject(files.getJSONObject(name).getString("content"))
        } else {
            read(source)
        }
        val positions = json.getJSONArray("positions").let { array ->
            (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                Position(
                    symbol = item.getString("symbol"),
                    direction = item.optString("direction", "Buy"),
                    units = item.getDouble("units"),
                    avgPrice = item.getDouble("avgPrice"),
                    currency = item.optString("currency", "USD"),
                    leverage = item.optDouble("leverage", 5.0),
                    spread = item.optDouble("spread", 0.0),
                    lots = item.optInt("lots", 1),
                )
            }
        }
        val targets = json.optJSONObject("targets")?.let { node ->
            node.keys().asSequence().associateWith { node.getDouble(it) }
        } ?: emptyMap()
        val symbols = json.optJSONArray("symbols")?.let { array ->
            (0 until array.length()).map { array.getString(it) }
        } ?: positions.map { it.symbol }

        return Sync(
            generated = json.optString("generated"),
            accountCurrency = json.optString("accountCurrency", "CZK"),
            cash = json.optDouble("cash", 0.0),
            deposits = json.optDouble("deposits", 0.0),
            withdrawals = json.optDouble("withdrawals", 0.0),
            symbols = symbols,
            targets = targets,
            positions = positions,
        )
    }

    /** Extended-hours price is the last non-null minute close; `meta` only carries the session one. */
    fun quote(ticker: String): Quote {
        val result = read(
            "https://query1.finance.yahoo.com/v8/finance/chart/$ticker" +
                "?interval=1m&range=1d&includePrePost=true"
        ).getJSONObject("chart").getJSONArray("result").getJSONObject(0)
        val meta = result.getJSONObject("meta")

        var last = meta.getDouble("regularMarketPrice")
        var stamp = meta.optDouble("regularMarketTime", 0.0)
        val stamps = result.optJSONArray("timestamp")
        val closes = result.optJSONObject("indicators")?.optJSONArray("quote")
            ?.optJSONObject(0)?.optJSONArray("close")
        if (stamps != null && closes != null) {
            for (index in closes.length() - 1 downTo 0) {
                if (!closes.isNull(index)) {
                    last = closes.getDouble(index)
                    stamp = stamps.getDouble(index)
                    break
                }
            }
        }

        var session = "closed"
        meta.optJSONObject("currentTradingPeriod")?.let { periods ->
            for (name in listOf("regular", "pre", "post")) {
                val period = periods.optJSONObject(name) ?: continue
                if (stamp >= period.getDouble("start") && stamp < period.getDouble("end")) {
                    session = name
                    break
                }
            }
        }

        val regular = meta.getDouble("regularMarketPrice")
        val previous = meta.optDouble("chartPreviousClose", regular)
        val base = if (session == "pre" || session == "post") regular else previous
        val change = last - base

        return Quote(
            symbol = ticker,
            price = last,
            change = change,
            changePercent = if (base == 0.0) 0.0 else change / base * 100,
            currency = meta.optString("currency", ""),
            name = meta.optString("longName", ticker),
            session = session,
        )
    }
}

object Calculator {
    /** The same arithmetic Trading 212 applies, so the figures hold outside its session. */
    fun account(sync: Sync, prices: Map<String, Double>, fx: Map<String, Double>,
                targets: Map<String, Double> = emptyMap()): Account? {
        var result = 0.0
        var margin = 0.0
        val holdings = mutableListOf<Holding>()

        for (position in sync.positions) {
            val last = prices[position.symbol] ?: return null
            val rate = if (position.currency == sync.accountCurrency) 1.0
                else fx["${position.currency}${sync.accountCurrency}=X"] ?: return null

            val target = targets[position.symbol]
            val closing = target ?: position.closing(last)
            val marginPrice = target?.plus(position.sign * position.spread) ?: position.marginPrice(last)

            val pnl = position.sign * position.units * (closing - position.avgPrice) * rate
            val positionResult = pnl - FX_FEE * Math.abs(pnl)
            val positionMargin = position.units * marginPrice * rate / position.leverage

            result += positionResult
            margin += positionMargin
            holdings += Holding(position.symbol, position.lots, positionResult,
                position.units * closing * rate, positionMargin)
        }
        if (margin <= 0) return null

        val equity = sync.cash + result
        // Trading 212's account status: below 50% measured against margin, above against both.
        val health = if (equity < margin) equity / margin * 50 else equity / (equity + margin) * 100
        return Account(equity, result, margin, health, maxOf(equity - margin, 0.0), holdings)
    }
}
