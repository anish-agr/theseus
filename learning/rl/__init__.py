"""Lane C — learned steering by reinforcement learning.

env.py defines a Gymnasium-style navigation environment that wraps the
SAME theseus_engine.Simulator the golden demos use, so a policy trained
here can be dropped behind steering.SteeringPolicy in the app (M5). The
gymnasium and stable-baselines3 dependencies are optional and isolated
to this subpackage; the env core is stdlib and unit-tested without them.
"""
