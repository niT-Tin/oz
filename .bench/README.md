# Reproducing the editor benchmarks

The [results](https://nit-tin.github.io/oz/benchmark/) include every timing trial as CSV and flame graphs per operation. Measurements use Linux, tmux, Python 3, Git, Neovim and, for profiling, Linux perf with user-space hardware cycle sampling enabled. The timing endpoint is the first captured frame showing the destination. The test does not save changes to the Git-tracked log.

## Large logs

Run from the repository root. Build with the repository's normal bootstrap procedure, then create an isolated synthetic Git repository. The example uses 1 GiB. Use 2048 for the 2 GiB run, and choose a fresh output folder for each run. Allow room for the logs, Git objects and traces.

```sh
zig build -Doptimize=ReleaseFast -Dstrip -p .verify/bench-timing
zig build -Doptimize=ReleaseFast -Dprofile -p .verify/bench-profile
mib=1024
root="$PWD/.verify/reproduce"
fixture="$root/$mib"
python3 .bench/large_file_frames.py --corpus "$root" --mib "$mib"
git init -q "$fixture"
git -C "$fixture" config core.trustctime false
git -C "$fixture" add -f large.log
git -C "$fixture" -c user.name=Benchmark -c user.email=bench@localhost -c commit.gpgsign=false commit -qm 'Track synthetic log'
python3 .bench/large_file_frames.py --corpus "$root" --mib "$mib" --fixture-repo "$fixture" \
  --editor final=.verify/bench-timing/bin/oz --editor nvim_clean=nvim --editor-arg nvim_clean=--clean \
  --trials 3 --output "$fixture/timing.json"
python3 .bench/large_file_frames.py --corpus "$root" --mib "$mib" --fixture-repo "$fixture" \
  --editor final=.verify/bench-profile/bin/oz --editor nvim_clean=nvim --editor-arg nvim_clean=--clean \
  --trials 2 --perf-dir "$fixture/traces" --output "$fixture/profile.json"
python3 .bench/perf_report.py --timing "$fixture/timing.json" \
  --profile "$fixture/profile.json=$fixture/traces" --output "$fixture/report.html"
```

The published 1 and 2 GiB Git blob IDs are `235750a8c5de53c0577eaee706324517b33fbe7f` and `f96191d723057b52e077605209aef711ec08e8ca`. The measured optimized source is [49e3cdd](https://github.com/niT-Tin/oz/commit/49e3cddd62e8749fe8ab5dcc4d0610086e90a06e).

The warm and cold conditions refer to the generated file's pages at editor start. The harness checks residency with mincore. It uses a private file name per trial and verifies the destination text after every operation.

## Everyday editing

Use `compare_frames.py --file code.zig` with `--editor final=.verify/bench-timing/bin/oz --editor nvim_clean=nvim --editor-arg nvim_clean=--clean`, `--trials 7` and `--output PATH`. Run it again with frame-pointer builds, a fresh `--perf-dir` and a separate manifest. Pass both runs to `perf_report.py` as in the example. The generated 33,801-byte source includes screen markers for navigation, search, typing, undo and switching buffers.
