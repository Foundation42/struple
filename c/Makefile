CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -O2
LDLIBS = -lm
SRC = struple.c struple_json.c
HDR = struple.h struple_json.h

test: test_struple test_conformance
	./test_struple
	./test_conformance

test_struple: test_struple.c $(SRC) $(HDR)
	$(CC) $(CFLAGS) -o $@ test_struple.c $(SRC) $(LDLIBS)

test_conformance: test_conformance.c $(SRC) $(HDR)
	$(CC) $(CFLAGS) -o $@ test_conformance.c $(SRC) $(LDLIBS)

# Encode/decode throughput benchmark (see bench/c/bench.c). Built at -O3 and run
# from the repo root so it can find bench/payloads.json and bench/data/*.json.
BENCH_CFLAGS = -std=c11 -O3 -Wall -Wextra
bench: ../bench/c/bench
	cd .. && bench/c/bench

../bench/c/bench: ../bench/c/bench.c $(SRC) $(HDR)
	$(CC) $(BENCH_CFLAGS) -I. -o $@ ../bench/c/bench.c $(SRC) $(LDLIBS)

clean:
	rm -f test_struple test_conformance ../bench/c/bench

.PHONY: test bench clean
