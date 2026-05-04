# OGRE 1.9 → 1.12 Migration Benchmark

Performance comparison between `gz-rendering` on **OGRE 1.9** (current main branch)
and **OGRE 1.12** (migration branch `jrivero/ogre112`) running inside
[Gazebo Sim](https://gazebosim.org).

## What was tested

Two build conditions are compared head-to-head:

| Condition | gz-rendering branch | OGRE version |
|---|---|---|
| `main_ogre19` | `main` | 1.9.1 (built from source) |
| `ogre112` | `jrivero/ogre112` | 1.12 (system package) |

Each condition runs the **`3k_shapes_camera`** world: ~3000 geometry shapes
(the standard `gz-sim` shapes-population world) plus a static 1280×720 @ 30 Hz
camera sensor pointed at the scene.  The simulation runs in headless/server-only
mode with offscreen rendering (`--headless-rendering`).

### Metrics collected per run (80 s window, 10 s warmup discarded)

| Metric | Source |
|---|---|
| RTF — Real-Time Factor (p50, p10) | `gz topic` world stats |
| Camera publish rate (mean Hz) | `gz topic --frequency` on `/bench/camera/image` |
| CPU % of the gz-sim server process | `/proc/<pid>/stat` sampled at 1 Hz |
| RSS peak (MB) | same source |
| GPU utilisation % (p50) | `nvidia-smi` at 1 Hz |
| VRAM peak (MB) | `nvidia-smi` |
| GPU power draw (p50, W) | `nvidia-smi` |
| Disk write throughput (p50, MB/s) | `iostat` |

### Runs

5 independent runs per condition.  Between runs the process fully exits and a
5-second pause lets the GPU and CPU settle.  Summary statistics are median ± IQR
across the 5 runs.

## Results

The latest complete benchmark run is in [`results/2026-05-04-1700/`](results/2026-05-04-1700/).
See [`results/2026-05-04-1700/report.md`](results/2026-05-04-1700/report.md) for the
full table.  Headline numbers:

| Metric | main_ogre19 | ogre112 | Δ |
|---|---|---|---|
| RTF p50 | 0.521 | 0.526 | +0.8% |
| RTF p10 (tail) | 0.351 | 0.359 | +2.3% * |
| Camera Hz | 15.05 | 15.05 | ≈0% |
| CPU % | 116 | 116 | ≈0% |
| RSS peak (MB) | 828 | 817 | −1.3% * |
| VRAM peak (MB) | 4395 | 3945 | **−10.2%** * |
| GPU power (W) | 16.8 | 16.7 | ≈0% |

`*` = IQRs do not overlap (informally significant).

**Conclusion**: OGRE 1.12 matches OGRE 1.9 on throughput (RTF, camera Hz, CPU)
and reduces VRAM consumption by ~10%.  No regressions were observed.

## Repository layout

```
bench/
├── run_bench.sh          # top-level driver — call this to run everything
├── lib/
│   ├── build_ogre_19.sh  # build OGRE 1.9.1 into a local prefix
│   ├── build_condition.sh# build one (branch, ogre) pair with colcon
│   ├── build_world.sh    # inject sensors plugin + camera into the SDF world
│   ├── run_condition.sh  # run N samples for one condition
│   ├── collect_samples.sh# single 90 s sample (warmup + measure + samplers)
│   └── aggregate.py      # summarise per-run CSVs → summary.csv + report.md
├── worlds/
│   └── 3k_shapes_camera.sdf   # pre-generated world (3000 shapes + camera)
└── results/
    └── YYYY-MM-DD-HHMM/
        ├── <condition>/run_NN/{rtf,cpu,gpu,io,cam_hz}.csv
        ├── summary.csv
        └── report.md
```

## Prerequisites

- Ubuntu 24.04 with `gz-sim` (Harmonic) installed from the OSRF APT repository
- `libogre-1.12-dev` (system package)
- `nvidia-smi` — NVIDIA driver present (GPU required for `--headless-rendering`)
- `sysstat` (`iostat`): `sudo apt install sysstat`
- `colcon`, `cmake`, `git`
- The parent workspace must be set up with `gz-rendering` and friends under `ws/src/`

## How to run

```bash
# Full run (builds everything, then benchmarks, then aggregates):
./run_bench.sh

# Skip the colcon build if already built:
./run_bench.sh --skip-build

# Change the number of runs (default 5):
./run_bench.sh --n-runs 3

# Use a different world:
./run_bench.sh --world 166_shapes_camera

# Override GPU-busy / high-load checks:
./run_bench.sh --force
```

Results are written to `results/YYYY-MM-DD-HHMM/` and a Markdown report is
generated at `results/YYYY-MM-DD-HHMM/report.md`.

To re-aggregate an existing result directory without re-running:

```bash
python3 lib/aggregate.py results/2026-05-04-1700
```
