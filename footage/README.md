# footage/ — local test videos (gitignored)

Videos in this directory are NOT committed (100 MB binaries don't
belong in git
for how to record and why). This manifest IS committed: one line per
clip so the repo remembers what footage exists and how it was shot.

| file | date | height (m) | hfov | contents / notes |
|------|------|------------|------|------------------|
| _example: room-sweep-01.mp4_ | _2026-07-20_ | _1.40_ | _calib pending_ | _full room lap; mirror on closet door (N wall)_ |
| pexels-hallway-7578548.mp4 | 2026-07-26 | unknown | ~68 est | house hallway dolly; Lane A static-pose slice test (Pexels License) |
| pexels-house-7578540.mp4 | 2026-07-26 | unknown | ~68 est | house interior; spare Lane A/B clip (Pexels License) |
| pexels-dining-5823595.mp4 | 2026-07-26 | unknown | ~68 est | dining room; Lane B found table + 2 chairs (Pexels License) |
| pexels-kitchen-3444431.mp4 | 2026-07-26 | unknown | ~68 est | kitchen; Lane B found fridge + 2 ovens (Pexels License) |
| tum_fr1_desk.tgz (+ derived .avi/.json) | 2026-07-26 | GT per frame | fx 517.3 | TUM RGB-D freiburg1_desk: real handheld office footage WITH mocap ground-truth poses + depth — full-trajectory rehearsal (CC-BY 4.0, Sturm et al. IROS 2012; prep: learning/tum_prep.py) |
