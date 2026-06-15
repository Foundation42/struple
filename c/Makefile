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

clean:
	rm -f test_struple test_conformance

.PHONY: test clean
