#!/usr/bin/env python3
"""Runs everything: rule checks, a 2-player camcorder test, then a real 4-player session (plus a rejected
fifth player, and a friend who joins late while the ship is in orbit) as separate
game processes. Prints every problem it finds."""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GODOT = ROOT / "tools/Godot.app/Contents/MacOS/Godot"
GAME_PORT = 24611
MOCK_PORT = 24612
TIMEOUT = 240
SCENE = "res://tests/test_main.tscn"
# Harmless: a position update still in flight reaches a machine just after that
# player was removed at round end or on disconnect, and the engine ignores it.
# Also expected: the shop test deliberately tries to buy something it already owns.
IGNORED = re.compile(r"Ignoring sync data from non-authority or for missing node"
                     r"|create-qris-order failed \(result 0, HTTP 409\)")


def launch(logs, name, *args, env=None):
    log = open(Path(logs) / f"{name}.log", "w")
    cmd = [str(GODOT), "--headless", "--path", str(ROOT), SCENE, "--", *args]
    return subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)


def read(logs, name):
    return (Path(logs) / f"{name}.log").read_text(errors="replace")


def main():
    failures = []
    # Models and sounds must be imported before any test can load them.
    subprocess.run([str(GODOT), "--headless", "--path", str(ROOT), "--import"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    # The payment rules, in the same code the server runs.
    node = subprocess.run(["node", "--test", "tests/payments.test.ts"], cwd=ROOT, capture_output=True, text=True, timeout=60)
    node_passed = int((re.search(r"pass (\d+)", node.stdout) or [0, 0])[1])
    if node.returncode != 0 or node_passed == 0:
        failures.append("payment rule tests failed:\n" + node.stdout[-2000:])
    # The game must never contain anything that can move money or read other players' data.
    for path in list((ROOT / "scripts").rglob("*.gd")) + [ROOT / "project.godot"]:
        text = path.read_text()
        for forbidden in ("MIDTRANS_SERVER_KEY", "SB-Mid-server", "Mid-server-", "api.midtrans.com", "api.sandbox.midtrans.com", "SERVICE_ROLE"):
            if forbidden in text:
                failures.append(f"{path.name} contains {forbidden}: it belongs on the server only")
    with tempfile.TemporaryDirectory() as logs:
        unit = launch(logs, "unit", "role=unit")
        unit.wait(timeout=60)
        procs = {}
        mock_log = open(Path(logs) / "mock.log", "w")
        mock = subprocess.Popen([sys.executable, "-I", str(ROOT / "tests/mock_supabase.py"), str(MOCK_PORT)],
                                stdout=mock_log, stderr=subprocess.STDOUT)
        try:
            time.sleep(0.5)
            cloud = [f"cloud_url=http://127.0.0.1:{MOCK_PORT}", "cloud_key=test-publishable-key"]
            common = [f"port={GAME_PORT}", *cloud]
            # Each test player gets a throwaway login file, so tests start signed out.
            login = lambda name: f"cloud_session={Path(logs) / (name + '.cfg')}"
            for role, extra in (("store", []), ("store_steam", ["fake_steam"]), ("entities", [f"port={GAME_PORT - 1}"]), ("settings", []), ("carry", [f"port={GAME_PORT - 2}"]), ("days", [f"port={GAME_PORT - 3}"]), ("gear", [f"port={GAME_PORT - 4}"]), ("slots", [f"port={GAME_PORT - 5}"]), ("kit", [f"port={GAME_PORT - 7}"]), ("video", [f"video={Path(logs) / 'test_clip.mov'}"])):
                procs[f"{role}0"] = launch(logs, f"{role}0", f"role={role}", login(role), *cloud, *extra)
                try:
                    procs[f"{role}0"].wait(timeout=150)
                except subprocess.TimeoutExpired:
                    procs[f"{role}0"].kill()
                    failures.append(f"{role}: timed out")
            # The camcorder: one player films, a second one picks it up and watches.
            tape_port = f"port={GAME_PORT - 6}"
            procs["tape0"] = launch(logs, "tape0", "role=tape", login("tape0"), *cloud, tape_port)
            time.sleep(1.0)
            procs["tape_client0"] = launch(logs, "tape_client0", "role=tape_client", login("tape_client0"), *cloud, tape_port)
            for name in ("tape0", "tape_client0"):
                try:
                    procs[name].wait(timeout=150)
                except subprocess.TimeoutExpired:
                    procs[name].kill()
                    failures.append(f"{name}: timed out")
            procs["host0"] = launch(logs, "host0", "role=host", "idx=0", login("host0"), *common)
            time.sleep(1.0)
            for i in (1, 2, 3):
                procs[f"client{i}"] = launch(logs, f"client{i}", "role=client", f"idx={i}", login(f"client{i}"), *common)
            deadline = time.time() + 60
            while "LOBBY_FULL" not in read(logs, "host0") and time.time() < deadline:
                time.sleep(0.2)
            procs["extra0"] = launch(logs, "extra0", "role=extra", login("extra0"), *common)
            # A friend who joins late, once the ship is back in orbit after the run.
            deadline = time.time() + TIMEOUT
            while "ORBIT_OPEN" not in read(logs, "host0") and time.time() < deadline and procs["host0"].poll() is None:
                time.sleep(0.2)
            procs["late0"] = launch(logs, "late0", "role=late", login("late0"), *common)
            end = time.time() + TIMEOUT
            for name, proc in procs.items():
                try:
                    proc.wait(timeout=max(1, end - time.time()))
                except subprocess.TimeoutExpired:
                    proc.kill()
                    failures.append(f"{name}: timed out")
        finally:
            for proc in procs.values():
                if proc.poll() is None:
                    proc.kill()
            mock.kill()
            mock_log.close()

        names = ["unit", *procs]
        passed = node_passed
        # The saved video format, checked with Apple's own video framework where available.
        if shutil.which("swift"):
            check = subprocess.run(["swift", str(ROOT / "tests/check_video.swift"), str(Path(logs) / "test_clip.mov")],
                                   capture_output=True, text=True, timeout=180)
            found = re.search(r"VIDEO_OK duration=([\d.]+) size=(\d+x\d+) .*brightness=([\d.]+),([\d.]+),([\d.]+)", check.stdout)
            if found and float(found[1]) == 5.0 and found[2] == "640x360" and float(found[3]) < float(found[4]) < float(found[5]):
                passed += 1
                print(f"PASS Apple's video framework plays the clip correctly: {check.stdout.strip()}")
            else:
                failures.append(f"video check failed: {check.stdout.strip()} {check.stderr.strip()[-500:]}")
        for name in names:
            text = read(logs, name)
            passed += len(re.findall(r"^PASS ", text, re.M))
            failures += [line for line in text.splitlines() if line.startswith("FAIL ")]
            if not re.search(r"^RESULT \w+ fails=\d+", text, re.M):
                failures.append(f"{name}: did not finish")
            for line in text.splitlines():
                if re.match(r"(SCRIPT )?ERROR|WARNING", line) and not IGNORED.search(line):
                    failures.append(f"{name}: {line}")

        for tag in ("FACILITY_R1", "FACILITY_R2", "FACILITY_R3"):
            seen = set()
            for name in procs:
                seen.update(re.findall(rf"^{tag} (-?\d+)", read(logs, name), re.M))
            if len(seen) != 1:
                failures.append(f"{tag}: machines built different facilities: {seen}")
            else:
                passed += 1
                print(f"PASS all machines built the same facility ({tag})")

        inserts = (Path(logs) / "mock.log").read_text().count("MOCK_INSERT")
        # One from each of the 3 players left in the session, and one each from the days and gear tests' finished runs.
        if inserts == 5:
            passed += 1
            print("PASS the database received one record for each finished run")
        else:
            failures.append(f"expected 5 database inserts, got {inserts}")

        print(f"\n{passed} checks passed, {len(failures)} problems")
        for line in dict.fromkeys(failures):
            print("  " + line)
        if failures:
            print("\n--- full logs ---")
            for name in names:
                print(f"\n=== {name} ===\n{read(logs, name)[-3000:]}")
    return 1 if failures else 0


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main())
