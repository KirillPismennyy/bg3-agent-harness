"""Render the tables of reports/benchmark-*.txt from a bench/bench.lua results JSON (no numbers typed by hand).

usage: python bench/summarize.py work/bench/full-NNN.json
"""
import json
import math
import sys


def main(path):
    r = json.load(open(path))
    m = r["meta"]
    out = []
    w = out.append
    w("source: %s; Lua %s, lupa %s; tick %d ms; trials %d; lifetime violations %d" % (
        path.replace("\\", "/").split("/")[-1], m["lua"], m["lupa"], m["tick_ms"], len(r["runs"]),
        sum(x["violations"] for x in r["runs"])))
    w("sha256: " + ", ".join("%s %s" % (k, v) for k, v in sorted(m["sha256"].items())))
    w("timer pair overhead p50 %.1f us / p99 %.1f us (n=%d), not subtracted" % (
        r["calibration"]["p50_us"], r["calibration"]["p99_us"], r["calibration"]["n"]))
    w("")
    w("config      N  E     trials ev_n  tick_n ev_p50 ev_p99 ev_max_all tick_p99 tick_max_all  req_MB disk_KB saves heap null")
    for s in r["summary"]:
        w("%-11s %-2d %-5d %-6d %-5d %-6d %6.0f %6.0f %10.0f %8.0f %12.0f %7.1f %7.0f %5d %4.0f %4.0f" % (
            s["config"], s["N"], s["E"], s["trials"], s["event_samples"], s["tick_samples"], s["ev_p50_us_med_trial"],
            s["ev_p99_us_med_trial"], s["ev_max_us_max_all"], s["tick_p99_us_med_trial"], s["tick_max_us_max_all"],
            s["bytes_requested"] / 1e6, s["final_disk_bytes"] / 1024, s["save_calls"], s["live_in_fight_delta_kb"],
            s["null_control_live_kb"] or -1))
    w("")
    for c in ("baseline", "v2_default", "v2_lean", "v2_full"):
        for n in (8, 24):
            xs = [(s["E"], s["bytes_requested"]) for s in r["summary"] if s["config"] == c and s["N"] == n]
            sl = ["%.2f" % (math.log(b2 / b1) / math.log(e2 / e1)) for (e1, b1), (e2, b2) in zip(xs, xs[1:])]
            w("slope bytes_requested vs E  %-11s N=%-2d %s" % (c, n, " ".join(sl)))
    w("")
    for x in r["long"]:
        w("long %-11s E=%-6d heap +%5.0f KB active_part %-7s req %12d B disk %9d B tick p99 %6.0f max %7.0f us" % (
            x["config"], x["E"], x["live_in_fight_delta_kb"], x.get("active_part_bytes"), x["bytes_requested"],
            x["final_disk_bytes"], x["tick_p99_us"], x["tick_max_us"]))
    w("")
    for x in r["writer_only"]:
        w("writer-only %-3s E=%-6d req %12d B saves %5d service total %9.1f ms p99 %7.1f max %8.1f us n=%d heap +%5.0f KB" % (
            x["writer"], x["E"], x["bytes_requested"], x["save_calls"], x["service_total_ms"], x["service_p99_us"],
            x["service_max_us"], x["service_calls"], x["heap_mid_kb"]))
    w("")
    for x in r["host_disk"]:
        w("host-disk %-11s E=%-5d trials %d tick p99(med) %6.0f us max(all) %8.0f us req %d B" % (
            x["config"], x["E"], x["trials"], x["tick_p99_us"], x["tick_max_us_max_all"], x["bytes_requested"]))
    w("")
    w("alloc (GC stopped, whole harness): " + "; ".join("%s E=%d %.1f MB" % (a["config"], a["E"], a["alloc_kb"] / 1024)
                                                      for a in r["alloc"]))
    w("")
    for k in ("baseline", "v2_lean", "v2_default"):
        v = r["bytes_by_kind"][k]
        top = sorted(v["by"].items(), key=lambda kv: -kv[1])[:6]
        w("bytes by kind %-10s total %8d: %s" % (k, v["total"], " ".join("%s=%d" % kv for kv in top)))
    w("")
    for x in r["ui"]:
        w("ui defer-delay %5d ms %-8s max queued %d callbacks run %d" % (
            x["defer_delay_ms"], x["config"], x["max_queued_defers"], x["callbacks_run"]))
    for x in r["ui_search"]:
        w("ui search V=%-6d %-8s p50 %8.0f us max %8.0f us n=%d" % (x["V"], x["config"], x["p50_us"], x["max_us"], x["n"]))
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1])
