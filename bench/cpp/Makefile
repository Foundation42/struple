# C++ struple benchmark. Run from this directory (bench/cpp/):
#   make            # build the benchmark
#   make run        # build + run (resolves bench/ paths via ../.. repo root)
#
# Or from the repo root:
#   g++ -std=c++17 -O2 -Icpp/include -o bench/cpp/bench bench/cpp/bench.cpp
#   ./bench/cpp/bench
#
# Does not touch cpp/Makefile (conformance `make test` is unaffected).

CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -I../../cpp/include
REPO_ROOT := ../..

bench: bench.cpp ../../cpp/include/struple.hpp
	$(CXX) $(CXXFLAGS) -o $@ bench.cpp

run: bench
	./bench $(REPO_ROOT)

clean:
	rm -f bench

.PHONY: run clean
