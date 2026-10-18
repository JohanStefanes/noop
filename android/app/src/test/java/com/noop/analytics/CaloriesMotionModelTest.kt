package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests the branched HR + motion day model ([Calories.estimateDayEnergy] with `motion`), the strength
 * damping and the Mifflin–St Jeor BMR. Twin of the Swift `CaloriesMotionModelTests`: same block
 * fixtures, and every pinned literal is the Swift implementation's output, so a drift on either side
 * fails here. APPROXIMATE estimates — not calorimetry, not medical advice.
 */
class CaloriesMotionModelTest {

    private data class Block(val seconds: Int, val bpm: Int, val intensity: Double?)

    private val h = 3_600
    private val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")

    /** 1 Hz HR and (where a block has an intensity) 1 Hz motion, blocks back to back from ts 0. */
    private fun build(blocks: List<Block>): Pair<List<HrSample>, List<ActivityPoint>> {
        val hr = ArrayList<HrSample>()
        val motion = ArrayList<ActivityPoint>()
        var t = 0L
        for (b in blocks) {
            for (k in 0 until b.seconds) {
                hr.add(HrSample(deviceId = "t", ts = t + k, bpm = b.bpm))
                if (b.intensity != null) motion.add(ActivityPoint(ts = t + k, intensity = b.intensity))
            }
            t += b.seconds
        }
        return hr to motion
    }

    // Typical days (same fixtures as the Swift twin and the before/after report).
    private val walkingDay = listOf(
        Block(8 * h, 52, 0.01), Block(6 * h, 68, 0.03), Block(3 * h, 98, 0.25),
        Block(1 * h, 85, 0.12), Block(6 * h, 66, 0.03),
    )
    /** Three hours at 128 bpm (above the 120 bpm HR-only gate) while sitting still. */
    private val stressDay = listOf(
        Block(8 * h, 52, 0.01), Block(3 * h, 128, 0.02), Block(5 * h, 70, 0.03), Block(8 * h, 66, 0.03),
    )
    private val runDay = listOf(
        Block(8 * h, 52, 0.01), Block(45 * 60, 160, 0.55), Block(15 * 60, 115, 0.22),
        Block(8 * h, 68, 0.03), Block(7 * h, 66, 0.03),
    )
    private val strengthHour = listOf(Block(1 * h, 135, 0.12))

    private fun energy(
        blocks: List<Block>,
        withMotion: Boolean,
        strengthWindows: List<LongRange> = emptyList(),
    ): Calories.DayEnergyEstimate {
        val (hr, motion) = build(blocks)
        return Calories.estimateDayEnergy(
            hr, profile, hrmax = 185.0, restingHR = 55.0,
            motion = if (withMotion) motion else emptyList(),
            strengthWindows = strengthWindows,
        )
    }

    // ---- Mifflin–St Jeor ----

    @Test
    fun mifflinStJeorReferenceValues() {
        // Hand-computed from the published equation (Mifflin et al. 1990), independent of the code.
        val rest = (0 until 86_400).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = 50) }
        for ((p, bmr) in listOf(
            UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male") to 1755.0,
            UserProfile(weightKg = 60.0, heightCm = 165.0, age = 30.0, sex = "female") to 1320.25,
            UserProfile(weightKg = 70.0, heightCm = 170.0, age = 30.0, sex = "nonbinary") to 1534.5,
        )) {
            val e = Calories.estimateDayEnergy(rest, p, hrmax = 185.0, restingHR = 55.0)
            assertEquals(p.sex, bmr, e.restingKcal, 1e-9)
            assertEquals(p.sex, 0.0, e.activeKcal, 1e-12)
        }
    }

    // ---- Branched model ----

    @Test
    fun walkingDayWithLowHrGetsMoreThanHrOnly() {
        val hrOnly = energy(walkingDay, withMotion = false)
        val blended = energy(walkingDay, withMotion = true)
        assertEquals(0.0, hrOnly.activeKcal, 1e-12)
        assertEquals(925.388417125604, blended.activeKcal, 1e-9)
        assertTrue(blended.totalKcal > hrOnly.totalKcal + 800)
        assertEquals("motion changes active energy only, never the resting floor",
            hrOnly.restingKcal, blended.restingKcal, 1e-12)
    }

    @Test
    fun highHrWithoutMotionGetsLessThanHrOnly() {
        val hrOnly = energy(stressDay, withMotion = false)
        val blended = energy(stressDay, withMotion = true)
        assertEquals(1810.1339953064933, hrOnly.activeKcal, 1e-9)
        assertEquals(452.5334988266233, blended.activeKcal, 1e-9)
        assertEquals(Calories.dayStillHRWeight * hrOnly.activeKcal, blended.activeKcal, 1e-9)
    }

    @Test
    fun runDayKeepsHrForTheRunAndAddsTheCooldownWalk() {
        assertEquals(670.7361756909139, energy(runDay, withMotion = false).activeKcal, 1e-9)
        assertEquals(783.4215015801623, energy(runDay, withMotion = true).activeKcal, 1e-9)
    }

    @Test
    fun noMotionIsIdenticalToHrOnly() {
        for (blocks in listOf(walkingDay, stressDay, runDay, strengthHour)) {
            val (hr, _) = build(blocks)
            val plain = Calories.estimateDayEnergy(hr, profile, hrmax = 185.0, restingHR = 55.0)
            val empty = Calories.estimateDayEnergy(hr, profile, hrmax = 185.0, restingHR = 55.0, motion = emptyList())
            assertEquals(plain, empty)
        }
        assertEquals(1810.1339953064933, energy(stressDay, withMotion = false).activeKcal, 1e-9)
        assertEquals(667.0204458543164, energy(strengthHour, withMotion = false).activeKcal, 1e-9)
    }

    @Test
    fun coarseMotionFallsBackToHrOnly() {
        // One gravity record per 30 s covers 1/30 of each window, below dayMotionMinCoverage.
        val (hr, motion) = build(stressDay)
        val coarse = motion.filter { it.ts % 30 == 0L }
        val hrOnly = Calories.estimateDayEnergy(hr, profile, hrmax = 185.0, restingHR = 55.0)
        val withCoarse = Calories.estimateDayEnergy(hr, profile, hrmax = 185.0, restingHR = 55.0, motion = coarse)
        assertEquals(hrOnly, withCoarse)
    }

    @Test
    fun bothSignalsLowStaysAtTheRestingFloor() {
        assertEquals(0.0, energy(listOf(Block(2 * h, 66, 0.03)), withMotion = true).activeKcal, 1e-12)
    }

    @Test
    fun motionMetAnchors() {
        assertEquals(1.0, Calories.motionMET(0.0), 1e-12)
        assertEquals(1.0, Calories.motionMET(0.05), 1e-12)
        assertEquals(2.75, Calories.motionMET(0.15), 1e-12)
        assertEquals(3.5, Calories.motionMET(0.20), 1e-12)
        assertEquals(5.25, Calories.motionMET(0.40), 1e-12)
        assertEquals("capped at the top anchor", 7.0, Calories.motionMET(2.0), 1e-12)
    }

    // ---- Strength ----

    @Test
    fun strengthBoutIsDamped() {
        val (hr, _) = build(strengthHour)
        val plain = Calories.estimateBoutCalories(hr, profile, hrmax = 185.0, restingHR = 55.0).first
        val strength = Calories.estimateBoutCalories(hr, profile, hrmax = 185.0, restingHR = 55.0, strength = true).first
        assertEquals(740.1454458543643, plain, 1e-9)
        assertEquals(518.1018120980475, strength, 1e-9)
        assertEquals(plain * Calories.strengthKeytelFactor, strength, 1e-6)
    }

    @Test
    fun strengthBoutNeverDropsBelowResting() {
        val hr = (0 until 600).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = 95) }
        val restOnly = Calories.estimateBoutCalories(
            (0 until 600).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = 60) },
            profile, hrmax = 185.0, restingHR = 55.0,
        ).first
        val strength = Calories.estimateBoutCalories(hr, profile, hrmax = 185.0, restingHR = 55.0, strength = true).first
        assertTrue(strength >= restOnly - 1e-9)
    }

    @Test
    fun strengthWindowDampsTheDay() {
        val window = listOf(0L..(h - 1).toLong())
        assertEquals(444.97681209804904, energy(strengthHour, false, window).activeKcal, 1e-9)
        assertEquals(442.06249882184744, energy(strengthHour, true).activeKcal, 1e-9)
        assertEquals(308.7376325086525, energy(strengthHour, true, window).activeKcal, 1e-9)
        assertEquals(
            energy(strengthHour, false),
            energy(strengthHour, false, listOf((10L * h)..(11L * h))),
        )
    }

    @Test
    fun isStrengthSport() {
        for (s in listOf("Strength", "Strength Training", "TraditionalStrengthTraining", "Weightlifting",
            "Powerlifting", "Bodybuilding", "functional strength training")) {
            assertTrue(s, Calories.isStrengthSport(s))
        }
        for (s in listOf("Running", "Walking", "Cycling", "HIIT", "Yoga", "")) {
            assertFalse(s, Calories.isStrengthSport(s))
        }
        assertFalse(Calories.isStrengthSport(null))
    }

    // ---- analyzeDay wiring ----

    private val dayUtc = "2026-01-02"
    private val noonUtc = 1_767_355_200L // 2026-01-02T12:00:00Z

    /** One hour at [bpm] from noon, with gravity alternating by [step] g each second (intensity = step). */
    private fun noonHour(bpm: Int, step: Double): Pair<List<HrSample>, List<GravitySample>> {
        val hr = (0 until h).map { HrSample(deviceId = "t", ts = noonUtc + it, bpm = bpm) }
        val gravity = (0 until h).map {
            GravitySample(deviceId = "t", ts = noonUtc + it, x = if (it % 2 == 0) 0.0 else step, y = 0.0, z = 1.0)
        }
        return hr to gravity
    }

    @Test
    fun analyzeDayUsesGravityForTheDayTotal() {
        val (walkHr, walkGrav) = noonHour(98, 0.25)
        val hrOnly = AnalyticsEngine.analyzeDay(day = dayUtc, hr = walkHr, profile = profile,
            maxHROverride = 185.0).daily.activeKcalEst
        val withMotion = AnalyticsEngine.analyzeDay(day = dayUtc, hr = walkHr, dayGravity = walkGrav,
            profile = profile, maxHROverride = 185.0).daily.activeKcalEst
        assertNotNull(hrOnly)
        assertNotNull(withMotion)
        assertTrue("a walk at low HR must add energy once motion is seen", withMotion!! > hrOnly!!)

        val (stillHr, stillGrav) = noonHour(150, 0.0)
        val stillHrOnly = AnalyticsEngine.analyzeDay(day = dayUtc, hr = stillHr, profile = profile,
            maxHROverride = 185.0).daily.activeKcalEst!!
        val stillWithMotion = AnalyticsEngine.analyzeDay(day = dayUtc, hr = stillHr, dayGravity = stillGrav,
            profile = profile, maxHROverride = 185.0).daily.activeKcalEst!!
        assertTrue("high HR while still must count for less", stillWithMotion < stillHrOnly)
    }

    @Test
    fun analyzeDayDampsEnteredStrengthWorkouts() {
        val (liftHr, _) = noonHour(150, 0.0)
        val plain = AnalyticsEngine.analyzeDay(day = dayUtc, hr = liftHr, profile = profile,
            maxHROverride = 185.0).daily.activeKcalEst!!
        val damped = AnalyticsEngine.analyzeDay(day = dayUtc, hr = liftHr,
            strengthWorkoutWindows = listOf(noonUtc..(noonUtc + h - 1)),
            profile = profile, maxHROverride = 185.0).daily.activeKcalEst!!
        assertTrue(damped < plain)
    }
}
