CXX ?= g++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -O2 -Iinclude
HDR = include/struple.hpp include/struple_json.hpp

test: test_struple test_conformance
	./test_struple
	./test_conformance

test_struple: test/test_struple.cpp $(HDR)
	$(CXX) $(CXXFLAGS) -o $@ test/test_struple.cpp

test_conformance: test/test_conformance.cpp $(HDR)
	$(CXX) $(CXXFLAGS) -o $@ test/test_conformance.cpp

clean:
	rm -f test_struple test_conformance

.PHONY: test clean
