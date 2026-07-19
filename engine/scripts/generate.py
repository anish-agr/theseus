"""Regenerate demo traces and golden fixtures.

Usage (from anywhere):  python engine/scripts/generate.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

from theseus_engine.demo import main  # noqa: E402

if __name__ == "__main__":
    main()
