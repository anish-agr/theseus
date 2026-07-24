"""Inpainting metrics, scored ONLY on cells that were unknown in the
partial map — predicting what you already know is not prediction.

- accuracy: fraction of unknown cells whose predicted state matches truth
- occupied IoU: intersection-over-union for the OCCUPIED class among
  unknown cells. This is the honest number: rooms are ~80% free, so an
  all-free predictor scores high accuracy while hallucinating away every
  wall. IoU_occ for all-free is 0 by construction.
"""

from __future__ import annotations

from dataclasses import dataclass

from .dataset import MapPair, generate_pair, unknown_indices


@dataclass
class Score:
    n_pairs: int
    n_cells: int
    accuracy: float
    iou_occupied: float
    known_fraction: float


def score_pairs(method, pairs: list[MapPair]) -> Score:
    correct = total = 0
    inter = union = 0
    known = 0.0
    for pair in pairs:
        pred = method(pair.partial, pair.w, pair.h)
        for i in unknown_indices(pair):
            total += 1
            p, t = pred[i], pair.full[i]
            if p == t:
                correct += 1
            p_occ, t_occ = p == 2, t == 2
            if p_occ and t_occ:
                inter += 1
            if p_occ or t_occ:
                union += 1
        known += pair.known_fraction
    n = max(1, len(pairs))
    return Score(
        n_pairs=len(pairs),
        n_cells=total,
        accuracy=correct / max(1, total),
        iou_occupied=inter / union if union else 0.0,
        known_fraction=known / n,
    )


def evaluate(method, seeds, **gen_kwargs) -> Score:
    return score_pairs(method, [generate_pair(s, **gen_kwargs) for s in seeds])
