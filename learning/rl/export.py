"""Lane C export: trained PPO policy -> ONNX, verified against SB3.

    python learning/rl/export.py                      # every stage found
    python learning/rl/export.py --stage movers3 --episodes 30

Why ONNX and not Core ML directly: coremltools wants macOS, and this
repo's whole build story is Mac-less. ONNX is the neutral, runnable
interchange — the depth lane already ships DA-V2 as .onnx and the same
onnxruntime executes both. Core ML conversion at M5 starts FROM this
file's output (onnx -> coremltools is the boring, documented half).

Export is only half the job; the other half is proving the exported
graph IS the policy. Two checks, increasingly end-to-end:

  1. logit parity — a batch of real observations through SB3 and
     through onnxruntime must produce the same argmax action, every
     single time (bit-identical logits are not guaranteed across
     runtimes; identical decisions are the actual contract).
  2. behavior — the ONNX policy drives full held-out episodes through
     evaluate.py, the same harness that scored training. Success/SPL
     should match the SB3 numbers, since check 1 makes the two
     policies pick identical actions.

The exported net takes the flat float32 observation (ego crop + goal
features, NavEnv.obs_dim) and returns action logits over env.ACTIONS;
argmax is the deterministic action. Consumers keep the logits so a
future on-device integration can mask actions or soften with
temperature without re-exporting.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "engine" / "src"))

from rl.env import NavEnv
from rl.evaluate import evaluate
from rl.rooms import CURRICULUM

RUNS = Path(__file__).resolve().parent / "runs"


def _require():
    try:
        import onnxruntime  # noqa: F401
        import stable_baselines3  # noqa: F401
        import torch  # noqa: F401
    except Exception:
        sys.exit("[export] missing deps. Install the lane:\n"
                 "    pip install -r learning/requirements.txt")


def _logit_head(policy):
    """The actor as pure tensor ops: obs -> action logits.

    SB3's predict() builds a Categorical and samples; none of that
    belongs in the graph. Walking the three submodules ourselves keeps
    the export free of control flow and stable across SB3 versions.
    """
    import torch

    class LogitHead(torch.nn.Module):
        def __init__(self, p):
            super().__init__()
            self.p = p

        def forward(self, obs):
            feats = self.p.extract_features(obs)
            if isinstance(feats, tuple):  # unshared pi/vf extractors
                feats = feats[0]
            return self.p.action_net(self.p.mlp_extractor.forward_actor(feats))

    return LogitHead(policy)


def _sample_observations(stage: str, n: int):
    """Real observations (resets + rollout steps), not random noise —
    parity on the data manifold is what matters."""
    import numpy as np

    rng = np.random.default_rng(7)
    out = []
    seed = 2000  # disjoint from training and from evaluate's held-out
    while len(out) < n:
        env = NavEnv(CURRICULUM[stage], seed=seed)
        obs, _ = env.reset()
        out.append(np.asarray(obs, dtype=np.float32))
        for _ in range(rng.integers(3, 25)):
            obs, _r, term, trunc, _i = env.step(int(rng.integers(0, 10)))
            out.append(np.asarray(obs, dtype=np.float32))
            if term or trunc or len(out) >= n:
                break
        seed += 1
    return np.stack(out[:n])


def export_stage(stage: str, episodes: int) -> Path:
    import numpy as np
    import onnxruntime as ort
    import torch
    from stable_baselines3 import PPO

    src = RUNS / f"ppo_{stage}.zip"
    dst = RUNS / f"ppo_{stage}.onnx"
    model = PPO.load(src, device="cpu")
    policy = model.policy.eval()

    head = _logit_head(policy)
    dummy = torch.zeros(1, policy.observation_space.shape[0],
                        dtype=torch.float32)
    torch.onnx.export(head, (dummy,), str(dst),
                      input_names=["obs"], output_names=["action_logits"],
                      dynamic_axes={"obs": {0: "batch"},
                                    "action_logits": {0: "batch"}},
                      opset_version=17, dynamo=False)

    sess = ort.InferenceSession(str(dst),
                                providers=["CPUExecutionProvider"])

    # check 1: same decision on every sampled observation
    obs = _sample_observations(stage, 256)
    onnx_actions = sess.run(None, {"obs": obs})[0].argmax(axis=1)
    sb3_actions = np.array([int(model.predict(o, deterministic=True)[0])
                            for o in obs])
    mismatches = int((onnx_actions != sb3_actions).sum())
    print(f"[{stage}] exported {dst.name} "
          f"({dst.stat().st_size / 1024:.0f} KiB), "
          f"action parity {len(obs) - mismatches}/{len(obs)}")
    if mismatches:
        sys.exit(f"[{stage}] export does NOT match the policy "
                 f"({mismatches} diverging actions) — not shipping that")

    # check 2: the artifact itself navigates held-out rooms
    if episodes:
        def onnx_policy(_env, o):
            logits = sess.run(
                None, {"obs": np.asarray(o, dtype=np.float32)[None]})[0]
            return int(logits.argmax())

        held_out = range(1000, 1000 + episodes)  # evaluate.py convention
        m = evaluate(onnx_policy, CURRICULUM[stage], held_out)
        print(f"[{stage}] onnx on held-out rooms (n={m.n}): "
              f"success {m.success_rate:.2f}  SPL {m.spl:.2f}  "
              f"steps {m.mean_steps:.0f}")
    return dst


def main() -> None:
    ap = argparse.ArgumentParser(description="PPO -> ONNX exporter")
    ap.add_argument("--stage", choices=list(CURRICULUM),
                    help="default: every stage with weights in runs/")
    ap.add_argument("--episodes", type=int, default=30,
                    help="held-out episodes for the behavior check "
                         "(0 skips it)")
    args = ap.parse_args()
    _require()
    stages = [args.stage] if args.stage else [
        s for s in CURRICULUM if (RUNS / f"ppo_{s}.zip").exists()]
    if not stages:
        sys.exit("[export] no trained weights in learning/rl/runs — "
                 "run train.py first")
    for stage in stages:
        export_stage(stage, args.episodes)


if __name__ == "__main__":
    main()
