package struple

// Recursion-depth caps (HARDENING.md Item 5): hostile deeply-nested input must
// be rejected with the port's own error, never a stack-overflow panic. Mirrors
// the Zig reference test "depth cap: deeply nested input is rejected".

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestDepthCapRejectsDeeplyNested(t *testing.T) {
	// FromJson: a 1000-deep JSON array (> maxDepth) must be rejected while
	// parsing, never recursing deep enough to overflow the stack.
	{
		deep := strings.Repeat("[", 1000) + strings.Repeat("]", 1000)
		err := safeCall(t, "FromJson(1000-deep array)", func() error {
			_, e := FromJson(deep)
			return e
		})
		if err == nil {
			t.Errorf("FromJson(1000-deep array): expected a non-nil error, got nil")
		} else if !errors.Is(err, ErrNestingTooDeep) {
			t.Errorf("FromJson(1000-deep array): expected ErrNestingTooDeep, got %v", err)
		}
	}

	// Build a ~300-deep nested array via the port's OWN encoder (wrap the prior
	// bytes in an array 300 times), then ToJson and SemanticOrder must both
	// reject it at the cap rather than recursing to overflow.
	{
		inner := NewWriter()
		inner.AppendInt(0)
		buf := append([]byte(nil), inner.Bytes()...)
		for d := 0; d < 300; d++ {
			p := NewWriter()
			p.AppendArray(buf)
			buf = append([]byte(nil), p.Bytes()...)
		}

		errJSON := safeCall(t, "ToJson(300-deep array)", func() error {
			_, e := ToJson(buf)
			return e
		})
		if errJSON == nil {
			t.Errorf("ToJson(300-deep array): expected a non-nil error, got nil")
		} else if !errors.Is(errJSON, ErrNestingTooDeep) {
			t.Errorf("ToJson(300-deep array): expected ErrNestingTooDeep, got %v", errJSON)
		}

		errSem := safeCall(t, "SemanticOrder(300-deep array)", func() error {
			_, e := SemanticOrder(buf, buf)
			return e
		})
		if errSem == nil {
			t.Errorf("SemanticOrder(300-deep array): expected a non-nil error, got nil")
		} else if !errors.Is(errSem, ErrNestingTooDeep) {
			t.Errorf("SemanticOrder(300-deep array): expected ErrNestingTooDeep, got %v", errSem)
		}
	}
}

// safeCall runs fn and converts any panic (e.g. a recursion blow-up surfacing
// as a recoverable panic) into a test FAILURE, so a missing depth cap is
// reported as a failing test rather than crashing the run.
func safeCall(t *testing.T, what string, fn func() error) (err error) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("%s: panicked instead of returning an error: %v", what, r)
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	return fn()
}
