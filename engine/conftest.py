# Makes `import theseus_engine` work no matter which directory pytest is
# invoked from (repo root, engine/, CI), with no install step.
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "src"))
