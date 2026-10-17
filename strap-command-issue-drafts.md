# Issue drafts: WHOOP 5/MG strap commands (not posted)

Each follows the AGENTS.md bar for a new non-trivial command: why it is reversible, confirmation-gated,
never sent automatically, payload and on-device verification documented before code. Facts are from
`docs/PROTOCOL_COMMANDS.md` and `docs/PROTOCOL_CONFIGURATION.md`; nothing is from a decompile.

---

## 1. Opt-in for `whoop_live_2_hrm_devices` (live HR to two receivers)

**What.** The strap lists the device-config key `whoop_live_2_hrm_devices` (tri-state) in its own
enumeration (115/116). `DeviceConfigWriteGate` refuses it today (`outOfScopeKeys`). Proposal: admit it as a
third key behind its own default-off opt-in, through the same path as Broadcast HR (#181).

**Why it is reversible.** Named SET (119) of a tri-state value. The current value is read with GET (121)
before the first write, stored, and written back on switch-off (writing `0` is not a universal reset).
Config writes on this firmware land and read back (`enable_sig12` moved `2`→`1`, confirmed by 121).

**Payload.** `0x01` + 32-byte key `whoop_live_2_hrm_devices` + 32-byte value `1` (0x31), zero-filled.
Only the 121 read-back is reported, never the ack.

**On-device verification.**
1. Read the value (121), note the factory state.
2. Write `1`, read back; pair NOOP and a second receiver (gym machine or second phone, standard HRS
   0x180D) and record whether both get live HR at the same time.
3. Reboot: is the value still stored?
4. Restore the original value and read it back.

**Open.** Connection limit, battery cost, effect on the history offload.

Refs #181

---

## 2. Read-only probe for `enable_passive_strap_fit_gen5` (strap-fit hint)

**What.** Feature flag `enable_passive_strap_fit_gen5` is eligible for named lookup; its consumer
semantics are unresolved. Proposal, step 1 only: a **read** (128) in the Test Centre to record the
current value across straps. No write until the read data says what the default is.

**Why it is safe.** Command 128 reads configuration storage; no state changes.

**Later write (separate issue, only after step 1).** Feature SET (120) with the same read-before /
restore-after contract as #1, behind a confirmation. The visible effect to look for: a fit-related
event or console line after loosening the strap.

**Open.** Polarity, default, which event or packet would carry a "poor fit" signal.

---

## 3. Gyro off/on (commands 150/152) for battery

**What.** 150 sets gyro mode (0 disabled, 1 enabled) on the ICM-45686 IMU; 152 reports the mode.
Proposal: an Experimental switch that turns the gyro off, to measure the battery effect.

**Why it is reversible.** One boolean, readable through 152. Read 152 before, write, read 152 after,
including after a **failed** SET (the docs warn a failed SET can still have changed the mode).
Switch-off writes the value read before.

**Risk to check first.** Whether sleep staging, step counting or R21 IMU data depend on the gyro. The
switch must stay default-off and must not be on while those are being evaluated.

**On-device verification.** 152 before/after; 24 h battery slope with gyro off against the previous
24 h with similar wear; confirm step counts and sleep detection still look normal; reboot persistence.

**Open.** Whether 152 reflects actual sample output (docs: it does not prove it).

---

## 4. LED accessibility (command 149)

**What.** 149 sets a persistent LED accessibility option, accepts only 0 and 1.

**Why it is reversible, with a gap.** Only two values, so the opposite write undoes it. **No GET is
documented**, so the original value cannot be read first. Proposal: the UI asks the user which LED
behaviour they see now before the first write, and the switch-off writes that value back.

**On-device verification.** Describe the indicator pattern before and after (photo or video), during
charge and on a double tap; reboot persistence.

**Open.** Whether a read exists; what exactly changes visually.

---

## 5. Rename the strap on WHOOP 5 (commands 140/141)

**What.** WHOOP 4 rename exists (`renameStrap`, command 77). WHOOP 5 uses 140 (set, 0–15 bytes) and
141 (get, fixed 19 bytes).

**Why it is reversible.** Read the current name with 141 first and keep it; "Reset name" writes it
back. Restrict input to printable ASCII, 1–15 bytes (no character-set validation is established on
the strap).

**On-device verification.** 141 before/after; the new name visible in iOS Bluetooth settings and to
a second scanner (may lag); reconnect still works by identifier (NOOP must not match the strap by
name); reboot persistence.

**Open.** Whether the name change disturbs pairing or WHOOP-side recognition.

---

Out of scope, unchanged: firmware 142–144, certificates 155–158, `LOCK_DEVICE` 159.
