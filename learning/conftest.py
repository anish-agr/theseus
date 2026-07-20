import pathlib
import sys

_ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_ROOT))                              # learning modules
sys.path.insert(0, str(_ROOT.parent / "engine" / "src"))    # theseus_engine
