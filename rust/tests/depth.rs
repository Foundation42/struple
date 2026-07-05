//! Recursion-depth caps (HARDENING Item 5) — a port of the Zig reference's
//! `"depth cap: deeply nested input is rejected, not a stack overflow"` test.
//!
//! Hostile deeply-nested input must be rejected with the port's own error, not a
//! stack overflow / panic, across all three recursive walks: JSON parse, JSON
//! render, and semantic compare.

use struple::json::{from_json, to_json};
use struple::{semantic_order, Error, Writer};

#[test]
fn deeply_nested_input_is_rejected_not_stack_overflow() {
    // from_json: a 1000-deep JSON array (> MAX_DEPTH) is rejected by the parser's
    // depth counter rather than recursing to overflow the stack.
    {
        let mut s = String::with_capacity(2000);
        for _ in 0..1000 {
            s.push('[');
        }
        for _ in 0..1000 {
            s.push(']');
        }
        assert!(from_json(&s).is_err(), "1000-deep JSON array must be rejected");
    }

    // Build a ~300-deep nested array encoding via the port's OWN encoder, then
    // to_json / semantic_order must reject it at the cap rather than overflowing.
    {
        let mut buf = {
            let mut w = Writer::new();
            w.append_int(0);
            w.into_bytes()
        };
        for _ in 0..300 {
            let mut w = Writer::new();
            w.append_array(&buf);
            buf = w.into_bytes();
        }
        assert_eq!(to_json(&buf), Err(Error::NestingTooDeep), "to_json must reject 300-deep nesting");
        assert_eq!(
            semantic_order(&buf, &buf),
            Err(Error::NestingTooDeep),
            "semantic_order must reject 300-deep nesting"
        );
    }
}
