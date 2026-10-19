package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins [HrSleepOnsetRefinement] against SYNTHETIC nights only: an awake lead-in at 66 bpm, then sleep at
 * 54 bpm with a 20-minute REM bump to 60 bpm every 90 minutes. Android twin of the Swift
 * `HRSleepOnsetRefinementTests`; [oracleMatchesSwift] pins the Swift algorithm's output verbatim.
 */
class HrSleepOnsetRefinementTest {

    private val start = 1_700_000_000L / 60 * 60
    private val nightMinutes = 420

    private fun night(awakeMinutes: Int, keepEvery: Int = 1): List<HrSample> {
        val out = ArrayList<HrSample>()
        for (minute in 0 until nightMinutes) {
            if (minute % keepEvery != 0) continue
            val bpm = if (minute < awakeMinutes) 66 else if ((minute - awakeMinutes) % 90 >= 70) 60 else 54
            for (k in 0 until 6) out.add(HrSample("d", start + minute * 60L + k * 10L, bpm))
        }
        return out
    }

    private fun wholeNightLight() = listOf(StageSegment(start, start + nightMinutes * 60L, "light"))

    @Test
    fun recoversInjectedOnsets() {
        for (lead in listOf(30, 60, 105)) {
            val out = HrSleepOnsetRefinement.refine(wholeNightLight(), night(lead))
            assertEquals(
                "lead-in $lead min",
                listOf(
                    StageSegment(start, start + lead * 60L, "wake"),
                    StageSegment(start + lead * 60L, start + nightMinutes * 60L, "light"),
                ),
                out,
            )
        }
    }

    @Test
    fun noLeadInIsPassthrough() {
        assertEquals(wholeNightLight(), HrSleepOnsetRefinement.refine(wholeNightLight(), night(0)))
    }

    @Test
    fun shiftBelowMinimumIsPassthrough() {
        assertNull(HrSleepOnsetRefinement.onsetTs(start, start + nightMinutes * 60L, night(5)))
    }

    @Test
    fun sparseHeartRateIsPassthrough() {
        assertEquals(wholeNightLight(), HrSleepOnsetRefinement.refine(wholeNightLight(), night(60, keepEvery = 2)))
    }

    @Test
    fun onsetPastHalfTheSessionIsRejected() {
        assertNull(HrSleepOnsetRefinement.onsetTs(start, start + nightMinutes * 60L, night(260)))
    }

    @Test
    fun stagesAfterOnsetAreUnchanged() {
        val segs = listOf(
            StageSegment(start, start + 40 * 60L, "light"),
            StageSegment(start + 40 * 60L, start + 100 * 60L, "deep"),
            StageSegment(start + 100 * 60L, start + nightMinutes * 60L, "rem"),
        )
        assertEquals(
            listOf(
                StageSegment(start, start + 60 * 60L, "wake"),
                StageSegment(start + 60 * 60L, start + 100 * 60L, "deep"),
                StageSegment(start + 100 * 60L, start + nightMinutes * 60L, "rem"),
            ),
            HrSleepOnsetRefinement.refine(segs, night(60)),
        )
    }

    @Test
    fun existingLeadingWakeMerges() {
        val segs = listOf(
            StageSegment(start, start + 20 * 60L, "wake"),
            StageSegment(start + 20 * 60L, start + nightMinutes * 60L, "light"),
        )
        assertEquals(
            listOf(
                StageSegment(start, start + 60 * 60L, "wake"),
                StageSegment(start + 60 * 60L, start + nightMinutes * 60L, "light"),
            ),
            HrSleepOnsetRefinement.refine(segs, night(60)),
        )
    }

    @Test
    fun sessionEfficiencyIsRecomputed() {
        val session = DetectedSleep(
            start = start, end = start + nightMinutes * 60L, efficiency = 1.0,
            stages = wholeNightLight(), restingHR = 52, avgHRV = 60.0,
        )
        val out = HrSleepOnsetRefinement.refine(session, night(105))
        assertEquals(session.start, out.start)
        assertEquals(52, out.restingHR)
        assertEquals((nightMinutes - 105).toDouble() / nightMinutes, out.efficiency, 1e-9)
    }

    /** Swift oracle output (standalone `swiftc` build of HRSleepOnsetRefinement.swift), pasted verbatim. */
    private val expectedOracle = listOf(
        "lead=0 noise=0 onset=nil",
        "lead=0 noise=3 onset=nil",
        "lead=0 noise=6 onset=nil",
        "lead=8 noise=0 onset=nil",
        "lead=8 noise=3 onset=nil",
        "lead=8 noise=6 onset=nil",
        "lead=25 noise=0 onset=1500",
        "lead=25 noise=3 onset=1500",
        "lead=25 noise=6 onset=1500",
        "lead=47 noise=0 onset=2820",
        "lead=47 noise=3 onset=2820",
        "lead=47 noise=6 onset=2760",
        "lead=90 noise=0 onset=5400",
        "lead=90 noise=3 onset=5400",
        "lead=90 noise=6 onset=5400",
        "lead=150 noise=0 onset=8880",
        "lead=150 noise=3 onset=8820",
        "lead=150 noise=6 onset=8820",
        "lead=230 noise=0 onset=nil",
        "lead=230 noise=3 onset=nil",
        "lead=230 noise=6 onset=nil",
    )

    @Test
    fun oracleMatchesSwift() {
        val base = 1_700_000_000L / 60 * 60
        val lines = ArrayList<String>()
        for (lead in listOf(0, 8, 25, 47, 90, 150, 230)) {
            for (noise in listOf(0, 3, 6)) {
                var seed = (lead * 31 + noise * 7 + 1).toLong()
                val hr = ArrayList<HrSample>()
                for (minute in 0 until 420) {
                    for (k in 0 until 6) {
                        seed = (seed * 1_664_525L + 1_013_904_223L) and 0xFFFFFFFFL
                        val jitter = if (noise == 0) 0 else ((seed ushr 16) % (2 * noise + 1)).toInt() - noise
                        val level = if (minute < lead) 66 else if ((minute - lead) % 90 >= 70) 60 else 54
                        hr.add(HrSample("d", base + minute * 60L + k * 10L, level + jitter))
                    }
                }
                val onset = HrSleepOnsetRefinement.onsetTs(base, base + 420 * 60L, hr)
                lines.add("lead=$lead noise=$noise onset=${onset?.let { (it - base).toString() } ?: "nil"}")
            }
        }
        assertEquals(expectedOracle, lines)
    }
}
