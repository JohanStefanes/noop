package com.noop.analytics

import com.noop.data.HrSample

/**
 * HrSleepOnsetRefinement.kt — heart-rate sleep-onset refinement (Experimental, default OFF). Direct Kotlin
 * port of the Swift `HRSleepOnsetRefinement`
 * (Packages/StrandAnalytics/Sources/StrandAnalytics/HRSleepOnsetRefinement.swift): same constants, same
 * algorithm, same [StageSegment] shape.
 *
 * Session detection is a gravity-stillness spine, so lying awake and still in bed starts the session (and
 * the shown "Fell asleep" time) before the wearer fell asleep, and the stagers read that quiet lead-in as
 * light sleep. Heart rate falls when sleep begins, so this post-pass finds the first [SUSTAIN_MINUTES]-long
 * stretch whose mean per-minute HR is at or below the night's own median per-minute HR ([onsetTs]) and
 * relabels everything before it as wake. It only ever adds wake at the head of a session; bounds and every
 * stage after the onset are untouched.
 *
 * Passthrough when HR covers less than [MIN_HR_COVERAGE_FRACTION] of the session's minutes, when no
 * stretch qualifies, when the onset is under [MIN_SHIFT_SECONDS] after the start, or beyond
 * [MAX_LEAD_FRACTION] of the session. Default-off Experimental toggle
 * ([com.noop.ble.PuffinExperiment.hrSleepOnset]); applied on the detection path only, never to a
 * hand-edited window. `HrSleepOnsetRefinementTest` pins the Swift oracle's output.
 */
object HrSleepOnsetRefinement {

    /** Length of the stretch whose mean HR must sit at or below the night's median to call onset. */
    const val SUSTAIN_MINUTES: Int = 10

    /** Minutes inside that stretch that must carry HR for the stretch to count. */
    const val MIN_SUSTAIN_MINUTES_WITH_HR: Int = 8

    /** Share of the session's minutes that must carry HR before the pass trusts the night's median. */
    const val MIN_HR_COVERAGE_FRACTION: Double = 0.6

    /** A found onset closer than this to the session start changes nothing. */
    const val MIN_SHIFT_SECONDS: Long = 10 * 60L

    /** A found onset later than this share of the session is not trusted as the onset. */
    const val MAX_LEAD_FRACTION: Double = 0.5

    /** The heart-rate onset inside `[start, end)`, or null when the guards decline. */
    fun onsetTs(start: Long, end: Long, hr: List<HrSample>): Long? {
        if (end <= start) return null
        val firstMinute = start / 60
        val lastMinute = (end - 1) / 60
        val minuteCount = (lastMinute - firstMinute + 1).toInt()
        if (minuteCount < SUSTAIN_MINUTES) return null

        val sums = LongArray(minuteCount)
        val counts = IntArray(minuteCount)
        for (s in hr) {
            if (s.ts < start || s.ts >= end || s.bpm <= 0) continue
            val i = (s.ts / 60 - firstMinute).toInt()
            sums[i] += s.bpm.toLong()
            counts[i] += 1
        }
        val means = arrayOfNulls<Double>(minuteCount)
        val present = ArrayList<Double>(minuteCount)
        for (i in 0 until minuteCount) {
            if (counts[i] == 0) continue
            val m = sums[i].toDouble() / counts[i].toDouble()
            means[i] = m
            present.add(m)
        }
        if (present.size.toDouble() < MIN_HR_COVERAGE_FRACTION * minuteCount.toDouble()) return null
        val threshold = median(present)

        for (i in 0..(minuteCount - SUSTAIN_MINUTES)) {
            var total = 0.0
            var n = 0
            for (j in i until i + SUSTAIN_MINUTES) {
                val m = means[j] ?: continue
                total += m
                n += 1
            }
            if (n < MIN_SUSTAIN_MINUTES_WITH_HR) continue
            if (total / n.toDouble() > threshold) continue
            val onset = maxOf(start, (firstMinute + i) * 60)
            if (onset - start < MIN_SHIFT_SECONDS) return null
            if ((onset - start).toDouble() > MAX_LEAD_FRACTION * (end - start).toDouble()) return null
            return onset
        }
        return null
    }

    /** Relabel every stage before the heart-rate onset as wake. Passthrough when the guards decline. */
    fun refine(segments: List<StageSegment>, hr: List<HrSample>): List<StageSegment> {
        val windowStart = segments.firstOrNull()?.start ?: return segments
        val windowEnd = segments.last().end
        val onset = onsetTs(windowStart, windowEnd, hr) ?: return segments
        val out = ArrayList<StageSegment>(segments.size + 1)
        for (seg in segments) {
            when {
                seg.end <= onset -> appendMerging(StageSegment(seg.start, seg.end, "wake"), out)
                seg.start < onset -> {
                    appendMerging(StageSegment(seg.start, onset, "wake"), out)
                    appendMerging(StageSegment(onset, seg.end, seg.stage), out)
                }
                else -> appendMerging(seg.copy(), out)
            }
        }
        return out
    }

    /** Session-level convenience: refines `session.stages` and recomputes `efficiency` from the result. */
    fun refine(session: DetectedSleep, hr: List<HrSample>): DetectedSleep {
        val newStages = refine(session.stages, hr)
        if (newStages == session.stages) return session
        val newEfficiency = SleepStager.efficiency(session.start, session.end, newStages)
        return session.copy(efficiency = newEfficiency, stages = newStages)
    }

    /** Median of a non-empty list; the mean of the two middle values for an even count. */
    internal fun median(values: List<Double>): Double {
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2
    }

    private fun appendMerging(piece: StageSegment, out: MutableList<StageSegment>) {
        if (piece.end <= piece.start) return
        val last = out.lastOrNull()
        if (last != null && last.stage == piece.stage && last.end == piece.start) {
            last.end = piece.end
        } else {
            out.add(piece)
        }
    }
}
