"""Theseus navigation engine — platform-free reference implementation.

This package is the source of truth for all navigation logic. It runs on
Windows/Linux/macOS with zero dependencies (stdlib only) so it can be
developed and property-tested long before any Apple hardware is involved,
then ported module-by-module to Swift (see docs/ARCHITECTURE.md, "Port
strategy"). The golden traces in fixtures/golden/ freeze its behavior; the
Swift port must reproduce them.

Module map:
  geometry  — vectors, angles, octile distance, conventions
  grid      — occupancy world model (log-odds, semantics, clearance field)
  astar     — optimal reference planner + path smoothing
  dstar_lite— incremental replanner (the one that ships)
  steering  — reactive local steering ("walk mode", VFH-style)
  guidance  — path -> egocentric cues for a guided human ("Ariadne mode")
  fsm       — navigation state machine
  sim       — headless sensor/motion simulator for tests and demos
  trace     — JSONL trace writing for the viewer and golden fixtures
"""

__version__ = "0.1.0"
