"""Synthetic night for mg_vs_watch: known HR bias, a known gap, and a NOOP write-back row that must be ignored."""
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mg_vs_watch as m  # noqa: E402

DEVICE = "whoop5-test"


def hk(ts: float) -> str:
    return datetime.fromtimestamp(ts).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


class MgVsWatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.now = datetime(2026, 10, 14, 9, 0)
        self.start = datetime(2026, 10, 13, 23, 0).timestamp()
        self.end = self.start + 8 * 3600
        gap = (self.start + 3600, self.start + 3600 + 20 * 60)  # 20 min without strap data

        db = d / "noop-backup.sqlite"
        con = sqlite3.connect(db)
        con.executescript("""
            CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY (deviceId, ts));
            CREATE TABLE rrInterval (deviceId TEXT, ts INTEGER, rrMs INTEGER, seq INTEGER, synced INTEGER,
                                     ord INTEGER, srcChannel INTEGER, tsSuspect INTEGER);
            CREATE TABLE sleepSession (deviceId TEXT, startTs INTEGER, endTs INTEGER);
        """)
        t = int(self.start)
        i = 0
        while t < self.end:
            if not gap[0] <= t < gap[1]:
                con.execute("INSERT INTO hrSample VALUES (?, ?, 60)", (DEVICE, t))
                rr = 1000 + (20 if i % 2 else -20)
                con.execute("INSERT INTO rrInterval VALUES (?, ?, ?, 0, 0, ?, 7, NULL)", (DEVICE, t, rr, i))
                # A flagged 500 ms fill beat must not reach the scorable set.
                if i % 50 == 0:
                    con.execute("INSERT INTO rrInterval VALUES (?, ?, 500, 1, 0, ?, 7, 1)", (DEVICE, t, i))
            t += 1
            i += 1
        con.commit()
        con.close()
        self.noopbak = d / "test.noopbak"
        with zipfile.ZipFile(self.noopbak, "w") as z:
            z.write(db, "noop-backup.sqlite")

        watch = 'device="&lt;&lt;HKDevice: 0x1, name:Apple Watch, manufacturer:Apple Inc., model:Watch&gt;&gt;"'
        recs = [f'<Record type="{m.HK_SLEEP}" sourceName="Watch" {watch} value="HKCategoryValueSleepAnalysisAsleepCore" '
                f'startDate="{hk(self.start)}" endDate="{hk(self.end)}"/>']
        self.watch_hr = 0
        for k in range(0, 8 * 60, 5):
            ts = self.start + k * 60 + 30
            recs.append(f'<Record type="{m.HK_HR}" sourceName="Watch" {watch} unit="count/min" value="58" '
                        f'startDate="{hk(ts)}" endDate="{hk(ts)}"/>')
            self.watch_hr += 1
        self.paired = sum(1 for k in range(0, 8 * 60, 5)
                          if not gap[0] - 30 <= self.start + k * 60 + 30 < gap[1] + 30)
        hs = self.start + 3 * 3600
        recs.append(f'<Record type="{m.HK_HRV}" sourceName="Watch" {watch} unit="ms" value="25" '
                    f'startDate="{hk(hs)}" endDate="{hk(hs + 60)}"/>')
        # NOOP's own write-back: no Apple Watch device, so it must be skipped.
        recs.append(f'<Record type="{m.HK_HR}" sourceName="NOOP" unit="count/min" value="200" '
                    f'startDate="{hk(self.start + 600)}" endDate="{hk(self.start + 600)}"/>')
        self.export = d / "export.zip"
        with zipfile.ZipFile(self.export, "w") as z:
            z.writestr("apple_health_export/export.xml",
                       "<?xml version='1.0'?><HealthData>" + "".join(recs) + "</HealthData>")

    def tearDown(self):
        self.tmp.cleanup()

    def test_night(self):
        since = (self.now - timedelta(days=5)).timestamp()
        import re
        health = m.load_health(self.export, since, re.compile(r"Apple Watch"))
        self.assertEqual(len(health.hr), self.watch_hr)
        self.assertEqual(health.skipped_sources, {"NOOP": 1})
        with tempfile.TemporaryDirectory() as tmp:
            con = m.open_noop(self.noopbak, Path(tmp))
            rows = m.analyse(con, DEVICE, health, 2, 5.0, 30.0, now=self.now)
            con.close()
        self.assertEqual([r["night"] for r in rows], ["2026-10-12", "2026-10-13"])
        r = rows[-1]
        self.assertEqual(r["win"], "watch")
        self.assertEqual(r["gaps>5m"], 1)
        self.assertEqual(r["longest_gap_m"], "20")
        self.assertEqual(r["hr_pairs"], self.paired)
        self.assertEqual(r["hr_bias"], "2.0")
        self.assertEqual(r["hr_mae"], "2.0")
        self.assertEqual(r["rr_scorable"], r["hr_n"])  # the flagged 500 ms beats are excluded
        self.assertEqual(r["strap_rmssd"], "40.0")
        self.assertEqual(r["hrv_pairs"], 1)
        self.assertEqual(r["watch_sdnn"], "25.0")
        self.assertEqual(r["strap_sdnn_paired"], "20.2")  # +/-20 ms alternation over 61 beats
        self.assertEqual(rows[0]["hr_n"], 0)


if __name__ == "__main__":
    unittest.main()
