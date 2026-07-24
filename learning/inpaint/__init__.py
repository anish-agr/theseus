"""Lane D — map inpainting: predict what the unscanned parts of a room
look like from the parts already seen.

Use: prioritize exploration (guess where free space continues), prettier
map previews, faster "is there likely a path" answers. Predictions are
STRICTLY advisory — a predicted-free cell is never traversable (the
engine's unknown-is-a-wall rule stands; see grid.py).

Structure mirrors the other lanes: dataset.py and baseline.py are stdlib
and tested (the sim generates unlimited (partial, full) map pairs; the
baseline is nearest-known-cell voting). train_unet.py needs torch and
must beat the baseline on held-out rooms to earn its place.
"""
