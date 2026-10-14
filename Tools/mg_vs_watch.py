#!/usr/bin/env python3
"""Per-night comparison of a WHOOP 5.0/MG strap (NOOP store) against an Apple Watch (Health export).

Inputs:
  --noop    a NOOP backup (`.noopbak`, a ZIP holding `noop-backup.sqlite`) or a bare `.sqlite` store
  --health  an Apple Health export (`export.zip` from Health > profile > Export All Health Data,
            or the `export.xml` inside it)

Per night it reports, for the strap:
  - HR samples, minute coverage of the night, gaps longer than --gap-min and the longest one
  - RR intervals (all / scorable: WHOOP 5 channels 5+7, not flagged tsSuspect), clean RMSSD + SDNN
and against the Watch:
  - HR: pairs within +/- --pair-sec of each Watch sample, bias (strap - watch), MAE, Pearson r
  - HRV: for each Watch HRV (SDNN) reading, the strap SDNN over the SAME window, then bias / MAE

The Watch's HRV is SDNN over a ~60 s reading, so it is compared to strap SDNN on the same window, never
to the strap's whole-night RMSSD. Only Watch-recorded samples count: NOOP writes its own HR back into
Health, and those rows carry no Apple Watch device, so --watch-device filters them out.

Night window: the Watch's own asleep span (sleep analysis, asleep stages), else the strap's
sleepSession, else 23:00-07:00 local. The column `win` says which one was used.

Only the standard library; runs with `python3 -I Tools/mg_vs_watch.py ...`.
"""
from __future__ import annotations

import argparse
import csv
import io
import math
import re
import sqlite3
import statistics
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from pathlib import Path

# Mirrors HRVAnalyzer (Packages/StrandAnalytics) so the strap numbers match what the app computes.
RR_MIN_MS = 300.0
RR_MAX_MS = 2000.0
MIN_BEATS = 20
ECTOPIC_THRESHOLD = 0.20
ECTOPIC_RADIUS = 2
SCORABLE_WHOOP5_CHANNELS = (5, 7)

HK_HR = "HKQuantityTypeIdentifierHeartRate"
HK_HRV = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
HK_SLEEP = "HKCategoryTypeIdentifierSleepAnalysis"
ASLEEP_VALUES = {
    "HKCategoryValueSleepAnalysisAsleep",
    "HKCategoryValueSleepAnalysisAsleepUnspecified",
    "HKCategoryValueSleepAnalysisAsleepCore",
    "HKCategoryValueSleepAnalysisAsleepDeep",
    "HKCategoryValueSleepAnalysisAsleepREM",
}
NON_STRAP_ID = re.compile(r"apple|health|import|csv|oura", re.I)


# ---------------------------------------------------------------- HRV maths (HRVAnalyzer twin)

def clean_rr(rr: list[float]) -> list[float]:
    in_range = [x for x in rr if RR_MIN_MS <= x <= RR_MAX_MS]
    out = []
    for i, x in enumerate(in_range):
        lo, hi = max(0, i - ECTOPIC_RADIUS), min(len(in_range), i + ECTOPIC_RADIUS + 1)
        med = statistics.median(in_range[lo:hi])
        if med > 0 and abs(x - med) / med <= ECTOPIC_THRESHOLD:
            out.append(x)
    return out


def rmssd(nn: list[float]) -> float | None:
    if len(nn) < MIN_BEATS:
        return None
    diffs = [(b - a) ** 2 for a, b in zip(nn, nn[1:])]
    return math.sqrt(sum(diffs) / len(diffs))


def sdnn(nn: list[float], min_beats: int = MIN_BEATS) -> float | None:
    if len(nn) < max(2, min_beats):
        return None
    return statistics.stdev(nn)


def pearson(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) < 3:
        return None
    try:
        return statistics.correlation(xs, ys)
    except statistics.StatisticsError:
        return None


# ---------------------------------------------------------------- inputs

def open_noop(path: Path, tmp: Path) -> sqlite3.Connection:
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            name = next((n for n in z.namelist() if n.endswith(".sqlite")), None)
            if name is None:
                sys.exit(f"{path}: no .sqlite entry in the archive")
            z.extract(name, tmp)
            path = tmp / name
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def columns(con: sqlite3.Connection, table: str) -> set[str]:
    return {r[1] for r in con.execute(f"PRAGMA table_info({table})")}


def pick_strap(con: sqlite3.Connection, wanted: str | None) -> str:
    rows = con.execute("SELECT deviceId, COUNT(*) n, MIN(ts) a, MAX(ts) b FROM hrSample GROUP BY deviceId "
                       "ORDER BY n DESC").fetchall()
    print("hrSample devices:", file=sys.stderr)
    for r in rows:
        print(f"  {r['deviceId']}: {r['n']} rows, {fmt_ts(r['a'])} .. {fmt_ts(r['b'])}", file=sys.stderr)
    if wanted:
        return wanted
    for r in rows:
        if not NON_STRAP_ID.search(r["deviceId"]):
            return r["deviceId"]
    sys.exit("no strap device found in hrSample; pass --device")


def parse_hk_date(s: str) -> float:
    return datetime.strptime(s, "%Y-%m-%d %H:%M:%S %z").timestamp()


@dataclass
class Health:
    hr: list[tuple[float, float]] = field(default_factory=list)          # (ts, bpm)
    hrv: list[tuple[float, float, float]] = field(default_factory=list)  # (start, end, sdnn ms)
    sleep: list[tuple[float, float]] = field(default_factory=list)       # asleep spans
    skipped_sources: dict[str, int] = field(default_factory=dict)


def load_health(path: Path, since_ts: float, watch_device: re.Pattern) -> Health:
    h = Health()
    if zipfile.is_zipfile(path):
        z = zipfile.ZipFile(path)
        name = next(n for n in z.namelist() if n.endswith("export.xml") and "cda" not in n)
        stream = z.open(name)
    else:
        stream = open(path, "rb")
    root = None
    with stream:
        # Exports run to millions of Records: drop each one from the root once read.
        for event, el in ET.iterparse(stream, events=("start", "end")):
            if root is None:
                root = el
            if event != "end" or el.tag != "Record":
                continue
            typ = el.get("type")
            if typ in (HK_HR, HK_HRV, HK_SLEEP):
                start = parse_hk_date(el.get("startDate"))
                if start >= since_ts:
                    device = el.get("device") or ""
                    if not watch_device.search(device):
                        src = el.get("sourceName", "?")
                        h.skipped_sources[src] = h.skipped_sources.get(src, 0) + 1
                    elif typ == HK_HR:
                        h.hr.append((start, float(el.get("value"))))
                    elif typ == HK_HRV:
                        h.hrv.append((start, parse_hk_date(el.get("endDate")), float(el.get("value"))))
                    elif el.get("value") in ASLEEP_VALUES:
                        h.sleep.append((start, parse_hk_date(el.get("endDate"))))
            root.clear()
    h.hr.sort()
    h.hrv.sort()
    h.sleep.sort()
    return h


# ---------------------------------------------------------------- nights

def night_of(ts: float) -> date:
    """A night is named by the evening it starts: anything before noon belongs to the previous day."""
    dt = datetime.fromtimestamp(ts)
    return (dt - timedelta(hours=12)).date()


def windows(nights: list[date], health: Health, strap_sleep: list[tuple[float, float]]):
    watch, strap = {}, {}
    for a, b in health.sleep:
        n = night_of(a)
        lo, hi = watch.get(n, (a, b))
        watch[n] = (min(lo, a), max(hi, b))
    for a, b in strap_sleep:
        n = night_of(a)
        if n not in strap or (b - a) > (strap[n][1] - strap[n][0]):
            strap[n] = (a, b)
    for n in nights:
        if n in watch:
            yield n, "watch", watch[n]
        elif n in strap:
            yield n, "strap", strap[n]
        else:
            a = datetime.combine(n, time(23, 0)).timestamp()
            yield n, "fixed", (a, a + 8 * 3600)


# ---------------------------------------------------------------- per-night stats

def gaps(ts_list: list[int], start: float, end: float, gap_s: float) -> tuple[int, float]:
    points = [start] + ts_list + [end]
    big = [b - a for a, b in zip(points, points[1:]) if b - a > gap_s]
    return len(big), (max(big) if big else 0.0)


def fmt(x, digits=1):
    return "" if x is None else f"{x:.{digits}f}"


def fmt_ts(ts) -> str:
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M") if ts else "-"


def analyse(con, device: str, health: Health, nights: int, gap_min: float, pair_sec: float,
            now: datetime | None = None):
    rr_cols = columns(con, "rrInterval")
    scorable = "1"
    if "srcChannel" in rr_cols:
        scorable = f"srcChannel IN {SCORABLE_WHOOP5_CHANNELS}"
    if "tsSuspect" in rr_cols:
        scorable += " AND tsSuspect IS NULL"
    strap_sleep = [(r[0], r[1]) for r in con.execute(
        "SELECT startTs, endTs FROM sleepSession WHERE deviceId = ?", (device,))]

    # The most recent night that has started at least 12 h ago: last night in the morning and evening alike.
    last = night_of((now or datetime.now()).timestamp() - 12 * 3600)
    wanted = [last - timedelta(days=i) for i in range(nights - 1, -1, -1)]
    out = []
    for n, kind, (a, b) in windows(wanted, health, strap_sleep):
        hr = con.execute("SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts < ? ORDER BY ts",
                         (device, int(a), int(b))).fetchall()
        rr_all = con.execute("SELECT COUNT(*) FROM rrInterval WHERE deviceId = ? AND ts >= ? AND ts < ?",
                             (device, int(a), int(b))).fetchone()[0]
        rr = con.execute(f"SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND ts >= ? AND ts < ? "
                         f"AND {scorable} ORDER BY ts, {'ord' if 'ord' in rr_cols else 'seq'}",
                         (device, int(a), int(b))).fetchall()
        hr_ts = [r[0] for r in hr]
        minutes = (b - a) / 60
        covered = len({t // 60 for t in hr_ts})
        n_gaps, longest = gaps(hr_ts, a, b, gap_min * 60)
        nn = clean_rr([float(r[1]) for r in rr])

        # HR pairing: each Watch sample against the strap median within +/- pair_sec.
        by_sec = {}
        for t, bpm in hr:
            by_sec.setdefault(t, []).append(bpm)
        diffs, xs, ys = [], [], []
        for t, w in (s for s in health.hr if a <= s[0] < b):
            near = [v for s in range(int(t - pair_sec), int(t + pair_sec) + 1) for v in by_sec.get(s, ())]
            if near:
                m = statistics.median(near)
                diffs.append(m - w)
                xs.append(m)
                ys.append(w)
        watch_hr_n = sum(1 for s in health.hr if a <= s[0] < b)

        # HRV pairing: strap SDNN over each Watch reading's own window (at least 30 clean beats).
        hrv_d = []
        for s, e, w in (r for r in health.hrv if a <= r[0] < b):
            seg = clean_rr([float(r[1]) for r in rr if s <= r[0] <= e])
            m = sdnn(seg, min_beats=30)
            if m is not None:
                hrv_d.append((m, w))

        out.append({
            "night": n.isoformat(),
            "win": kind,
            "hours": round((b - a) / 3600, 1),
            "hr_n": len(hr),
            "hr_cov_%": fmt(100 * covered / minutes if minutes else None, 0),
            f"gaps>{gap_min:g}m": n_gaps,
            "longest_gap_m": fmt(longest / 60, 0),
            "rr_all": rr_all,
            "rr_scorable": len(rr),
            "rr_clean": len(nn),
            "strap_rmssd": fmt(rmssd(nn)),
            "strap_sdnn": fmt(sdnn(nn)),
            "watch_hr_n": watch_hr_n,
            "hr_pairs": len(diffs),
            "hr_bias": fmt(statistics.fmean(diffs) if diffs else None),
            "hr_mae": fmt(statistics.fmean(abs(d) for d in diffs) if diffs else None),
            "hr_r": fmt(pearson(xs, ys), 2),
            "watch_hrv_n": sum(1 for r in health.hrv if a <= r[0] < b),
            "hrv_pairs": len(hrv_d),
            "watch_sdnn": fmt(statistics.fmean(w for _, w in hrv_d) if hrv_d else None),
            "strap_sdnn_paired": fmt(statistics.fmean(m for m, _ in hrv_d) if hrv_d else None),
            "hrv_mae": fmt(statistics.fmean(abs(m - w) for m, w in hrv_d) if hrv_d else None),
        })
    return out


def print_table(rows: list[dict]) -> None:
    if not rows:
        return
    keys = list(rows[0])
    width = {k: max(len(k), *(len(str(r[k])) for r in rows)) for k in keys}
    print("  ".join(k.rjust(width[k]) for k in keys))
    for r in rows:
        print("  ".join(str(r[k]).rjust(width[k]) for k in keys))


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--noop", type=Path, required=True)
    p.add_argument("--health", type=Path, required=True)
    p.add_argument("--nights", type=int, default=14)
    p.add_argument("--device", help="strap deviceId (default: the non-import device with most HR rows)")
    p.add_argument("--watch-device", default=r"Apple Watch|Watch\d",
                   help="regex the Health record's device must match (default: %(default)s)")
    p.add_argument("--gap-min", type=float, default=5.0)
    p.add_argument("--pair-sec", type=float, default=30.0)
    p.add_argument("--csv", type=Path, help="also write the table here")
    args = p.parse_args(argv)

    since = (datetime.now() - timedelta(days=args.nights + 2)).timestamp()
    with tempfile.TemporaryDirectory() as tmp:
        con = open_noop(args.noop, Path(tmp))
        device = pick_strap(con, args.device)
        print(f"strap: {device}", file=sys.stderr)
        health = load_health(args.health, since, re.compile(args.watch_device))
        print(f"watch: {len(health.hr)} HR, {len(health.hrv)} HRV, {len(health.sleep)} asleep spans", file=sys.stderr)
        if health.skipped_sources:
            print("skipped (not Apple Watch): " + ", ".join(f"{k} {v}" for k, v in
                  sorted(health.skipped_sources.items(), key=lambda kv: -kv[1])), file=sys.stderr)
        rows = analyse(con, device, health, args.nights, args.gap_min, args.pair_sec)
        con.close()

    print_table(rows)
    if args.csv and rows:
        with open(args.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
