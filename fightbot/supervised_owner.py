"""Persistent local stdin JSON owner; its input thread never connects to BG3."""
import argparse
import json
from pathlib import Path
import queue
import sys
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument("--probe", action="store_true")
parser.add_argument("--log", type=Path, required=True)
parser.add_argument("--expected-recorder-hash")
parser.add_argument("--trial-root", type=Path)
parser.add_argument("--script-extender-dir", type=Path)
args = parser.parse_args()
args.trial_root = (args.trial_root or (args.log.parent / "trials")).resolve()
args.repo = args.repo.resolve()
if not (args.repo / "fightbot" / "fightbot_mcp.py").is_file() or not (args.repo / "bridge" / "src" / "bg3ai").is_dir():
    parser.error("--repo must contain fightbot/fightbot_mcp.py and bridge/src/bg3ai (defaults to this script's repository)")
sys.path[:0] = [str(args.repo / "fightbot"), str(args.repo / "bridge" / "src")]
from fightbot_mcp import Bot
from trial_owner import TrialOwner, owned_game

owner = TrialOwner(probe=args.probe, expected_recorder_hash=args.expected_recorder_hash)
game = owned_game(owner)
bot, bot_generation = None, None
inbox = queue.Queue()
args.log.parent.mkdir(parents=True, exist_ok=True)


def output(row):
    row = {"time": time.time(), **row}
    line = json.dumps(row, default=str)
    with args.log.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")
    print(line, flush=True)


def read_stdin():
    for line in sys.stdin:
        inbox.put(line)
    inbox.put(None)


threading.Thread(target=read_stdin, daemon=True).start()
last_state = None
try:
    while True:
        state = owner.poll()
        if state != last_state:
            output({"type": "readiness", **state})
            last_state = dict(state)
        generation = (state.get("server_session"), state.get("client_session"), state.get("combat_id"))
        if state.get("ready") and bot_generation != generation:
            # Avoid retaining short IDs, event cursors or roll bindings across VM resets.
            game.close()  # OwnedGame has no owned socket; TrialOwner stays connected.
            game = owned_game(owner)
            bot = Bot(game, log_path=args.log.with_suffix(".bot.jsonl"))
            bot_generation = generation
        try:
            line = inbox.get(timeout=0.5)
        except queue.Empty:
            continue
        if line is None:
            break
        try:
            request = json.loads(line)
            kind = request.get("kind", "tool")
            if kind == "poll":
                result = owner.poll()
            elif kind == "acknowledge_resolution":
                result = owner.acknowledge_resolution(request.get("note"))
            elif kind == "trial_cast":
                if not state.get("ready") or bot is None:
                    raise ValueError("recorders and combat are not READY")
                from trial_capture import capture_trial, summarize_trial
                params = dict(request.get("args", {}))
                if set(params) - {"char", "spell", "target", "source"}:
                    raise ValueError("trial_cast accepts char, spell, target and optional source")
                trial_destination = args.trial_root
                name = request.get("directory")
                if name is not None:
                    import re
                    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", name):
                        raise ValueError("trial directory must be a simple local basename")
                    trial_destination = args.trial_root / name
                if not isinstance(request.get("numerical_probe", False), bool):
                    raise ValueError("numerical_probe must be a boolean")
                result = capture_trial(owner, bot, actor=params["char"], target=params["target"],
                    spell=params["spell"], source=params.get("source"), ready_token=request.get("ready_token"),
                    destination=trial_destination, recorder_dir=bot.reader.folder,
                    script_extender_dir=args.script_extender_dir,
                    numerical_probe=request.get("numerical_probe", False),
                    flush_timeout_s=request.get("flush_timeout_s", 2.0))
                result = summarize_trial(result)
            elif kind == "eval":
                # Explicit root-controlled Lua; mutations need the current readiness token.
                fn = lambda: owner.evaluate(request["code"], context=request.get("context", "client"),
                                             statement=request.get("statement"))
                result = owner.run_action(request.get("ready_token"), fn) if request.get("mutation") else fn()
            else:
                tool = request["tool"]
                if tool not in {"fight_state", "actions", "cast", "move", "end_turn", "rolls", "wait_for_turn"}:
                    raise ValueError("unsupported tool")
                if not state.get("ready") or bot is None:
                    raise ValueError("recorders and combat are not READY")
                params = dict(request.get("args", {}))
                if tool == "wait_for_turn":
                    params["timeout_s"] = min(float(params.get("timeout_s", 5)), 5)
                fn = lambda: getattr(bot, tool)(**params)
                result = owner.run_action(request.get("ready_token"), fn) if tool in {"cast", "move", "end_turn"} else fn()
            output({"type": "result", "request": request, "result": result})
        except Exception as exc:
            output({"type": "error", "error": str(exc), "error_type": type(exc).__name__})
finally:
    owner.close()
