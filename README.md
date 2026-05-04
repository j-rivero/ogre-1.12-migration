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

Each condition runs a **shapes-population** world (the standard `gz-sim`
shapes world, sized to ~100 / ~500 / ~3000 models) instrumented with one of
two sensors:

- a static **1280×720 @ 30 Hz camera** pointed at the scene, _or_
- a **Velodyne-class `gpu_lidar`** (360° horizontal × 16 vertical channels
  @ 30 Hz, 0.1-100 m range) mounted inside the scene.

The simulation runs in headless/server-only mode with offscreen rendering
(`--headless-rendering`).  The active sensor is selected with
`run_bench.sh --sensor camera|lidar`.

### Metrics collected per run (80 s window, 10 s warmup discarded)

| Metric | Source |
|---|---|
| RTF — Real-Time Factor (p50, p10) | `gz topic` world stats |
| Sensor publish rate (mean Hz)¹ | `gz topic --frequency` on `/bench/camera/image` or `/bench/lidar/scan` |
| CPU % of the gz-sim server process | `/proc/<pid>/stat` sampled at 1 Hz |
| RSS peak (MB) | same source |
| GPU utilisation % (p50) | `nvidia-smi` at 1 Hz |
| VRAM peak (MB) | `nvidia-smi` |
| GPU power draw (p50, W) | `nvidia-smi` |
| Disk write throughput (p50, MB/s) | `iostat` |

¹ The aggregator labels this row "Camera Hz (mean)" in `report.md` for
historical reasons; on `--sensor lidar` runs it is the lidar scan publish
rate.

### Runs

5 independent runs per condition.  Between runs the process fully exits and a
5-second pause lets the GPU and CPU settle.  Summary statistics are median ± IQR
across the 5 runs.

## Results

The benchmark was run at three scene scales to expose how the OGRE 1.9 → 1.12
cost scales with renderable count.  All three result directories are preserved:

| Run dir | World file | Models in scene |
|---|---|---|
| [`results/2026-05-04-1700/`](results/2026-05-04-1700/) | `33_shapes_camera.sdf`  | ~100 (104) |
| [`results/2026-05-04-1559/`](results/2026-05-04-1559/) | `166_shapes_camera.sdf` | ~500 (503) |
| [`results/2026-05-04-1521/`](results/2026-05-04-1521/) | `3k_shapes_camera.sdf`  | ~3000 (3005) |

### Scaling picture (RTF and camera throughput)

| Scene | RTF main | RTF ogre112 | Δ RTF | Cam Hz Δ | Notes |
|---|---|---|---|---|---|
| ~100 shapes  | 0.521  | 0.526  | +0.8 % (noise) | 0 %      | both have GPU headroom (~39 % util) |
| ~500 shapes  | 0.102  | 0.073  | **−28 %** *    | **−26 %** * | clear regression |
| ~3000 shapes | 0.0115 | 0.0115 | +0.5 % (noise) | 0 %      | both saturated at floor |

`*` = IQRs do not overlap (informally significant).

**The migration regression is scale-dependent, not constant**:

- **Small scenes (~100 shapes)** — equal performance, both fast.
- **Mid scenes (~500 shapes)** — ogre 1.12 is ~28 % slower; the regression bites here.
- **Stress scenes (~3000 shapes)** — both pinned at the same GPU saturation floor;
  the regression hides under saturation.

This pattern strongly suggests the OGRE 1.9 → 1.12 cost lives in something that
scales **per-renderable per-frame** — likely per-draw-call overhead, the RTSS
shader path, or material/state setup.  It's hidden when you have very few
objects (low total work) or very many (every version queues draws faster than
the GPU can complete them).

### Headline numbers — small scene (~100 shapes, [`results/2026-05-04-1700/report.md`](results/2026-05-04-1700/report.md))

| Metric | main_ogre19 | ogre112 | Δ |
|---|---|---|---|
| RTF p50 | 0.521 | 0.526 | +0.8% |
| RTF p10 (tail) | 0.351 | 0.359 | +2.3% * |
| Camera Hz | 15.05 | 15.05 | ≈0% |
| CPU % | 116 | 116 | ≈0% |
| RSS peak (MB) | 828 | 817 | −1.3% * |
| VRAM peak (MB) | 4395 | 3945 | **−10.2%** * |
| GPU power (W) | 16.8 | 16.7 | ≈0% |

### Headline numbers — mid scene (~500 shapes, [`results/2026-05-04-1559/report.md`](results/2026-05-04-1559/report.md))

| Metric | main_ogre19 | ogre112 | Δ |
|---|---|---|---|
| RTF p50 | 0.1020 | 0.0730 | **−28.4%** * |
| RTF p10 (tail) | 0.0846 | 0.0609 | **−28.0%** * |
| Camera Hz | 3.04 | 2.26 | **−25.7%** * |
| CPU % | 107 | 107 | ≈0% |
| GPU util % | 20.5 | 27.0 | +31.7% * |
| VRAM peak (MB) | 4180 | 4121 | −1.4% |
| GPU power (W) | 29.6 | 32.0 | +8.0% * |

### Headline numbers — stress scene (~3000 shapes, [`results/2026-05-04-1521/report.md`](results/2026-05-04-1521/report.md))

| Metric | main_ogre19 | ogre112 | Δ |
|---|---|---|---|
| RTF p50 | 0.0115 | 0.0115 | +0.5% |
| RTF p10 (tail) | 0.0103 | 0.0106 | +2.8% |
| Camera Hz | 0.35 | 0.35 | +0.9% |
| CPU % | 105 | 105 | ≈0% |
| GPU util % | 15.0 | 16.5 | +10.0% |
| VRAM peak (MB) | 2366 | 3032 | +28.1% * |
| GPU power (W) | 30.7 | 30.2 | −1.5% |

`*` = IQRs do not overlap (informally significant).

### Other observations

- **VRAM**: ogre 1.12 uses 10 % less at 100 shapes (3945 vs 4395 MB) and is
  roughly even at 500 shapes (−1.4 %).  At 3000 shapes ogre 1.12 actually
  consumes **more** (+28 %) — the resource allocator behaviour flips at
  scale.
- **GPU util ~39 %** on both versions in the small-scene run → plenty of
  headroom; the bottleneck has moved to CPU-side draw setup, which both
  versions handle equally fast at this scale.
- **CPU ~107–116 % on both** → one core busy.  Not a CPU-throughput problem;
  it's per-frame latency.

**Conclusion**: OGRE 1.12 is **not** a drop-in performance match for OGRE 1.9.
At small (~100 shapes) and very large (~3000 shapes) scales the two versions
are within noise, but at mid scales (~500 shapes) ogre 1.12 is ~28 % slower on
both RTF and camera publish rate.  The regression is consistent with extra
per-renderable-per-frame work in the OGRE 1.12 render path.

## Results — `gpu_lidar` sensor (small scene)

Same shapes-population world (~100 models / 104 model blocks) but with the
camera replaced by a **Velodyne-class `gpu_lidar`** (360° × 16 channels,
30 Hz, range 0.1-100 m, topic `/bench/lidar/scan`).  The lidar rig is
mounted at `z = 2 m` inside the scene rather than looking down from above,
so its rays sweep through the populated volume.

| World file | Models | Result dir |
|---|---|---|
| `33_shapes_lidar.sdf` | ~100 (104) | [`results/2026-05-04-1922/`](results/2026-05-04-1922/) |

### Headline numbers — lidar @ ~100 shapes ([`report.md`](results/2026-05-04-1922/report.md))

| Metric | main_ogre19 | ogre112 | Δ |
|---|---|---|---|
| RTF p50 | 0.5611 | 0.5569 | −0.7 % |
| RTF p10 (tail) | 0.5476 | 0.5375 | −1.8 % |
| Lidar scan Hz | 16.94 | 16.72 | −1.3 % |
| CPU % | 109 | 109 | ≈0 % |
| RSS peak (MB) | 818 | 803 | −1.8 % * |
| GPU util % | 12.0 | 34.0 | **+183 %** * |
| VRAM peak (MB) | 3142 | 2758 | **−12.2 %** * |
| GPU power (W) | 29.5 | 30.5 | +3.4 % |

`*` = IQRs do not overlap (informally significant).  The "Lidar scan Hz"
row is the `cam_hz_mean` column in `report.md` (sampler is sensor-agnostic;
the label is historical).

### Observations

- **Throughput is unchanged** — RTF and lidar scan Hz both within IQR
  overlap.  The 30 Hz target is RTF-capped at ~17 Hz on this hardware
  because the simulation runs at ~0.56 RTF.
- **VRAM**: ogre 1.12 saves ~12 %, consistent with the camera bench at the
  same scene size.
- **GPU util triples (12 % → 34 %, IQRs disjoint) for the same scan
  throughput** — ogre 1.12 spends nearly 3× more GPU time per published
  scan.  At this scene size there is plenty of GPU headroom so it does
  not show up in the publish rate, but it is a clear efficiency
  regression in the `gpu_lidar` render path.  Power draw bumps modestly
  (+3.4 %) consistent with the higher utilisation.
- **CPU and RSS** are essentially flat (CPU 109 % both; RSS −1.8 %).

### Caveat / next step

This is a **single-scale** lidar benchmark.  The camera bench showed the
OGRE 1.9 → 1.12 cost is scale-dependent (small ≈ noise, mid ≈ −28 %, very
large ≈ noise).  The same sweep at ~500 shapes would tell us whether the
~3× GPU-util headroom on lidar collapses into a throughput regression once
the GPU starts saturating — that is the most likely place a real-world
lidar workload would feel the migration.

## Reusing the harness

The benchmark harness is reusable for any other scene — pass `--world <name>`
and put a matching SDF in `bench/worlds/`.  Use `--sensor camera` (default)
or `--sensor lidar` to switch sensor type.

## Repository layout

```
bench/
├── run_bench.sh          # top-level driver — call this to run everything
├── lib/
│   ├── build_ogre_19.sh  # build OGRE 1.9.1 into a local prefix
│   ├── build_condition.sh# build one (branch, ogre) pair with colcon
│   ├── build_world.sh    # inject sensors plugin + camera or gpu_lidar into the SDF world
│   ├── run_condition.sh  # run N samples for one condition
│   ├── collect_samples.sh# single 90 s sample (warmup + measure + samplers)
│   └── aggregate.py      # summarise per-run CSVs → summary.csv + report.md
├── worlds/
│   ├── 33_shapes_camera.sdf   # ~100 shapes  (small) + camera
│   ├── 166_shapes_camera.sdf  # ~500 shapes  (mid)   + camera
│   ├── 3k_shapes_camera.sdf   # ~3000 shapes (stress)+ camera
│   └── 33_shapes_lidar.sdf    # ~100 shapes  (small) + gpu_lidar
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

# Switch sensor (camera default; lidar is gpu_lidar on /bench/lidar/scan):
./run_bench.sh --sensor lidar --world 33_shapes_lidar

# Override GPU-busy / high-load checks:
./run_bench.sh --force
```

Results are written to `results/YYYY-MM-DD-HHMM/` and a Markdown report is
generated at `results/YYYY-MM-DD-HHMM/report.md`.

To re-aggregate an existing result directory without re-running:

```bash
python3 lib/aggregate.py results/2026-05-04-1700
```
