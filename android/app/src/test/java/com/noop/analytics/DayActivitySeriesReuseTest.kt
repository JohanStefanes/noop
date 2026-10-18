package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * [AnalyticsEngine.analyzeDay] builds the gravity-derived activity series once and hands it to
 * [WorkoutDetector.detect], [WorkoutTypeFeatureExtractor.extract] and the day calorie motion, instead of
 * each rebuilding it from the same gravity. A pure speed change: the precomputed path must equal the raw
 * path exactly, and the day's outputs must be the values the per-caller rebuild produced. Twin of Swift
 * `DayActivitySeriesReuseTests`, same fixture and literals.
 */
class DayActivitySeriesReuseTest {

    private val day = "2026-08-23"
    private val bouts = listOf(
        9 * 3600 to 9 * 3600 + 2400, 13 * 3600 to 13 * 3600 + 3600, 18 * 3600 to 18 * 3600 + 2700,
    )
    private val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")

    private data class Day(val hr: List<HrSample>, val gravity: List<GravitySample>, val steps: List<StepSample>)

    /** A full 1 Hz calendar day: resting HR with a faint wobble, three bouts at 150 bpm with real motion. */
    private fun fullDay(): Day {
        val base = AnalyticsEngine.dayStartUtcSeconds(day)
        val hr = ArrayList<HrSample>(86_400)
        val gravity = ArrayList<GravitySample>(86_400)
        val steps = ArrayList<StepSample>(86_400)
        for (t in 0 until 86_400) {
            val inBout = bouts.any { t >= it.first && t < it.second }
            hr.add(HrSample("d", base + t, if (inBout) 150 else 62 + (t / 600) % 5))
            val x = if (inBout) (if (t % 2 == 0) 0.9 else 0.5) else 0.1 + (t % 7) * 0.002
            gravity.add(GravitySample("d", base + t, x, 0.1, 0.1))
            steps.add(StepSample("d", base + t, (t / 3) and 0xFFFF, if (inBout) 2 else 0))
        }
        return Day(hr, gravity, steps)
    }

    /** Gravity out of ts order, so the series' own sort is exercised on both paths. */
    private fun shuffledGravity(g: List<GravitySample>): List<GravitySample> {
        val out = g.toMutableList()
        var i = 0
        while (i + 1 < out.size) {
            val tmp = out[i]; out[i] = out[i + 1]; out[i + 1] = tmp
            i += 7
        }
        return out.reversed()
    }

    @Test
    fun detectWithPrecomputedSeriesEqualsRawPath() {
        val d = fullDay()
        val gravity = shuffledGravity(d.gravity)
        var rawFunnel: WorkoutDetector.DetectionFunnel? = null
        var preFunnel: WorkoutDetector.DetectionFunnel? = null
        val raw = WorkoutDetector.detect(
            d.hr, gravity, restingHR = 60.0, maxHR = 185.0, profile = profile, funnel = { rawFunnel = it },
        )
        val pre = WorkoutDetector.detect(
            d.hr, gravity, restingHR = 60.0, maxHR = 185.0, profile = profile, funnel = { preFunnel = it },
            activity = WorkoutDetector.activitySeries(gravity),
        )
        assertEquals(3, raw.size)
        assertEquals(raw, pre)
        assertEquals(rawFunnel, preFunnel)
    }

    @Test
    fun extractWithPrecomputedSeriesEqualsRawPath() {
        val d = fullDay()
        val gravity = shuffledGravity(d.gravity)
        val series = WorkoutDetector.activitySeries(gravity)
        val base = AnalyticsEngine.dayStartUtcSeconds(day)
        for ((s, e) in bouts) {
            val raw = WorkoutTypeFeatureExtractor.extract(
                d.hr, gravity, d.steps, base + s, base + e, restingHR = 60.0, maxHR = 185.0, caloriesKcal = 500.0,
            )
            val pre = WorkoutTypeFeatureExtractor.extract(
                d.hr, gravity, d.steps, base + s, base + e, restingHR = 60.0, maxHR = 185.0, caloriesKcal = 500.0,
                activity = series,
            )
            assertNotNull(raw)
            assertEquals(raw, pre)
        }
    }

    /** The day's results, pinned to what Swift `analyzeDay` produced while each caller still rebuilt the series. */
    @Test
    fun analyzeDayOutputsUnchanged() {
        val d = fullDay()
        val res = AnalyticsEngine.analyzeDay(
            day = day, hr = d.hr, gravity = d.gravity, steps = d.steps,
            dayHr = d.hr, daySteps = d.steps, dayGravity = d.gravity, profile = profile,
        )
        assertEquals(3610.9295848211677, res.daily.activeKcalEst!!, 0.0)
        assertEquals(listOf(1_787_475_604L, 1_787_490_004L, 1_787_508_004L), res.workouts.map { it.start })
        assertEquals(listOf(1_787_477_999L, 1_787_493_599L, 1_787_510_699L), res.workouts.map { it.end })
        assertEquals(
            listOf(559.5425267789391, 839.7808540472009, 629.6021085960045),
            res.workouts.map { it.caloriesKcal },
        )
    }
}
