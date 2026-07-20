"""Lane C training: PPO over NavEnv, curriculum static -> movers.

    pip install -r learning/requirements.txt   # gymnasium, sb3, torch
    python learning/rl/train.py --stage static --steps 300000

The env (env.py) and the metrics (evaluate.py) are dependency-free and
already tested; this script only adds the PPO loop and a held-out
comparison against the scripted baseline, so a green run means the
POLICY improved, not that the harness changed. Trained weights go to
learning/rl/runs/ (gitignored). Core ML export (M5, on the Mac) is a
documented follow-up via coremltools.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "engine" / "src"))

from rl.env import NavEnv, greedy_policy
from rl.evaluate import evaluate
from rl.rooms import CURRICULUM


def _require():
    try:
        import gymnasium  # noqa: F401
        import stable_baselines3  # noqa: F401
        import torch  # noqa: F401
    except Exception:
        sys.exit("[train] missing RL deps. Install the lane:\n"
                 "    pip install -r learning/requirements.txt")


def make_env(difficulty: dict, seed: int):
    def _thunk():
        env = NavEnv(difficulty, seed=seed)
        return env
    return _thunk


def policy_from_model(model):
    """Wrap an SB3 model as the (env, obs) -> action callable evaluate()
    expects, so the trained net and the baseline are scored identically."""
    def _policy(_env, obs):
        action, _ = model.predict(obs, deterministic=True)
        return int(action)
    return _policy


def train(stage: str, steps: int, seed: int, out: Path):
    _require()
    from stable_baselines3 import PPO
    from stable_baselines3.common.vec_env import SubprocVecEnv

    difficulty = CURRICULUM[stage]
    n_envs = 8
    venv = SubprocVecEnv([make_env(difficulty, seed + i) for i in range(n_envs)])
    model = PPO("MlpPolicy", venv, verbose=1, n_steps=1024, batch_size=2048,
                gae_lambda=0.95, gamma=0.99, ent_coef=0.005, seed=seed)
    model.learn(total_timesteps=steps)
    out.mkdir(parents=True, exist_ok=True)
    model.save(out / f"ppo_{stage}")

    held_out = range(1000, 1030)          # disjoint from training seeds
    base = evaluate(greedy_policy, difficulty, held_out)
    learned = evaluate(policy_from_model(model), difficulty, held_out)
    print(f"\n[{stage}] held-out (n={base.n})")
    print(f"  baseline : success {base.success_rate:.2f}  SPL {base.spl:.2f}"
          f"  steps {base.mean_steps:.0f}")
    print(f"  learned  : success {learned.success_rate:.2f}  "
          f"SPL {learned.spl:.2f}  steps {learned.mean_steps:.0f}")
    return model


def main() -> None:
    ap = argparse.ArgumentParser(description="PPO steering trainer")
    ap.add_argument("--stage", default="static", choices=list(CURRICULUM))
    ap.add_argument("--steps", type=int, default=300_000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default="learning/rl/runs")
    args = ap.parse_args()
    train(args.stage, args.steps, args.seed, Path(args.out))


if __name__ == "__main__":
    main()
