#!/bin/bash
tee "$PWD/.bench/mock-in.log" | "$PWD/zig-out/bin/mock_lsp" --verbose 2>"$PWD/.bench/mock-debug.log" | tee "$PWD/.bench/mock-out.log"
