use struple::{compare, encode, pack, semantic_order, unpack, Value, Writer};
use std::cmp::Ordering;

fn dec(s: &str) -> Vec<u8> {
    let mut w = Writer::new();
    w.append_decimal_string(s).unwrap();
    w.into_bytes()
}

#[test]
fn decimal_golden_and_roundtrip() {
    // Sanity hex values pinned by the cross-language corpus.
    assert_eq!(hex(&dec("12.345")), "380321020d233300");
    assert_eq!(hex(&dec("-12.345")), "3801defdf2dcccff");
    assert_eq!(hex(&dec("0")), "3802");
    // Canonicalization: trailing/leading zeros collapse; scaled forms agree.
    assert_eq!(dec("12.300"), dec("12.3"));
    assert_eq!(dec("0.5"), dec("000.5000"));
    assert_eq!(dec("1e30"), dec("1000000000000000000000000000000"));

    // Round-trip through Value::Decimal.
    for s in ["12.345", "-12.345", "0", "100", "0.001", "-0.5", "1e-9"] {
        let bytes = dec(s);
        match &unpack(&bytes).unwrap()[0] {
            Value::Decimal { .. } => {}
            other => panic!("expected decimal, got {other:?}"),
        }
        // Re-encoding the decoded value reproduces the canonical bytes.
        assert_eq!(encode(&unpack(&bytes).unwrap()[0]), bytes, "reencode {s}");
    }
}

#[test]
fn decimal_byte_order_and_semantics() {
    // memcmp byte order: negatives < zero < positives, magnitude-correct.
    let ordered = ["-12.345", "-0.5", "0", "0.001", "1.5", "12.345", "100", "1e30"];
    let enc: Vec<Vec<u8>> = ordered.iter().map(|s| dec(s)).collect();
    for i in 1..enc.len() {
        assert!(enc[i - 1] < enc[i], "decimal byte order at {i}");
    }
    // Semantic cross-type equality: decimal == int == float for the same value.
    let five_i = encode(&Value::Int(5));
    let five_f = encode(&Value::F64(5.0));
    assert_eq!(semantic_order(&dec("5"), &five_i).unwrap(), Ordering::Equal);
    assert_eq!(semantic_order(&dec("5.0"), &five_f).unwrap(), Ordering::Equal);
    assert_eq!(semantic_order(&dec("1.50"), &dec("1.5")).unwrap(), Ordering::Equal);
    // -0.0 == 0 == decimal 0.
    assert_eq!(semantic_order(&dec("0"), &encode(&Value::F64(-0.0))).unwrap(), Ordering::Equal);
}

#[test]
fn decimal_exponent_bounds_and_dos_shortcircuit() {
    // Encode bounds (Item 2): an exponent past i32, or an adjusted exponent
    // (sig-len + exp) past i32, is rejected; the i32-max adjusted exponent is fine.
    let try_dec = |s: &str| Writer::new().append_decimal_string(s).map(|_| ());
    assert!(try_dec("1e9999999999").is_err(), "huge exponent must reject");
    assert!(try_dec("1e2147483647").is_err(), "adj_exp = i32::MAX + 1 must reject");
    assert!(try_dec("1e2147483646").is_ok(), "adj_exp = i32::MAX must be accepted");

    // The digits+exp Writer path is bounded too.
    assert!(Writer::new().append_decimal(false, &[1], i32::MAX).is_err());

    // DoS short-circuit: a huge-exponent decimal vs an int and vs a float must
    // resolve PROMPTLY (never materialize/scale by ~2e9) with the correct order.
    let big = dec("1e2000000000");
    let tiny = dec("1e-2000000000");
    let five = encode(&Value::Int(5));
    let one_f = encode(&Value::F64(1.0));
    assert_eq!(semantic_order(&big, &five).unwrap(), Ordering::Greater);
    assert_eq!(semantic_order(&big, &one_f).unwrap(), Ordering::Greater);
    assert_eq!(semantic_order(&tiny, &five).unwrap(), Ordering::Less);
    assert_eq!(semantic_order(&tiny, &one_f).unwrap(), Ordering::Less);
    // And the reverse orientation short-circuits identically.
    assert_eq!(semantic_order(&five, &big).unwrap(), Ordering::Less);
    assert_eq!(semantic_order(&one_f, &tiny).unwrap(), Ordering::Greater);
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::new();
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

#[test]
fn golden_bytes() {
    assert_eq!(hex(&encode(&Value::Nil)), "01");
    assert_eq!(hex(&encode(&Value::Bool(true))), "06");
    assert_eq!(hex(&encode(&Value::Int(0))), "20");
    assert_eq!(hex(&encode(&Value::Int(255))), "21ff");
    assert_eq!(hex(&encode(&Value::Int(256))), "220100");
    assert_eq!(hex(&encode(&Value::Int(-1))), "1fff");
    assert_eq!(hex(&encode(&Value::Int(-100))), "1f9c");
    assert_eq!(hex(&encode(&Value::Str("app".into()))), "4861707000");
    // wide integers now use the fixed slots (the i128 range)
    assert_eq!(hex(&encode(&Value::Int(1i128 << 64))), "29010000000000000000"); // 9-byte fixed positive
    assert_eq!(hex(&encode(&Value::Int(i128::MAX))), "307fffffffffffffffffffffffffffffff"); // i128 max
    assert_eq!(hex(&encode(&Value::Int(i128::MIN))), "1080000000000000000000000000000000"); // i128 min
    // 2^127 (one past i128 max) falls back to the big-int code
    assert_eq!(
        hex(&encode(&Value::BigInt { negative: false, magnitude: {
            let mut m = vec![0x80u8];
            m.extend(std::iter::repeat(0).take(15));
            m
        } })),
        "31011080000000000000000000000000000000"
    );
}

#[test]
fn uuid_bytes() {
    let u: [u8; 16] = [0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00];
    assert_eq!(hex(&encode(&Value::Uuid(u))), "44550e8400e29b41d4a716446655440000");
    assert_eq!(unpack(&encode(&Value::Uuid(u))).unwrap()[0], Value::Uuid(u));
}

#[test]
fn int_roundtrip() {
    let cases: [i128; 12] = [0, 1, -1, 255, 256, -256, -257, i64::MAX as i128, i64::MIN as i128, 1 << 40, -(1 << 40), 1 << 56];
    for v in cases {
        assert_eq!(unpack(&encode(&Value::Int(v))).unwrap()[0], Value::Int(v), "round-trip {v}");
    }
}

#[test]
fn ordering() {
    assert!(compare(&encode(&Value::Str("app".into())), &encode(&Value::Str("apple".into()))) == Ordering::Less);
    assert!(encode(&Value::Int(-256)) < encode(&Value::Int(-100)));
    assert!(encode(&Value::Int(-100)) < encode(&Value::Int(-1)));
    // big negatives via the BigInt path
    let neg_big = |bits: u32| {
        let mut mag = vec![1u8];
        mag.extend(std::iter::repeat(0).take((bits / 8) as usize));
        encode(&Value::BigInt { negative: true, magnitude: mag })
    };
    assert!(neg_big(100) < neg_big(64)); // -2^100 < -2^64
}

#[test]
fn sorted_chain() {
    let values = [
        Value::Nil,
        Value::Bool(false),
        Value::Bool(true),
        Value::Int(-1000),
        Value::Int(-1),
        Value::Int(0),
        Value::Int(1),
        Value::Int(1000),
        Value::Str("".into()),
        Value::Str("app".into()),
        Value::Str("apple".into()),
        Value::Str("b".into()),
    ];
    let mut enc: Vec<Vec<u8>> = values.iter().map(encode).collect();
    for i in 1..enc.len() {
        assert!(enc[i - 1] < enc[i], "index {i}");
    }
    let original = enc.clone();
    enc.reverse();
    enc.sort();
    assert_eq!(enc, original);
}

#[test]
fn containers() {
    // array round-trip
    let arr = pack(&[Value::Array(vec![Value::Int(1), Value::Int(2), Value::Int(3)])]);
    assert_eq!(unpack(&arr).unwrap()[0], Value::Array(vec![Value::Int(1), Value::Int(2), Value::Int(3)]));

    // map canonicalization: insertion order does not affect bytes
    let m1 = encode(&Value::Map(vec![(Value::Str("b".into()), Value::Int(2)), (Value::Str("a".into()), Value::Int(1))]));
    let m2 = encode(&Value::Map(vec![(Value::Str("a".into()), Value::Int(1)), (Value::Str("b".into()), Value::Int(2))]));
    assert_eq!(m1, m2);

    // array < map < set
    assert!(pack(&[Value::Array(vec![Value::Int(1)])]) < encode(&Value::Map(vec![(Value::Str("a".into()), Value::Int(1))])));
    assert!(encode(&Value::Map(vec![(Value::Str("a".into()), Value::Int(1))])) < encode(&Value::Set(vec![Value::Int(1)])));
}

#[test]
fn float_ordering() {
    let fb = |f: f64| {
        let mut w = Writer::new();
        w.append_f64(f);
        w.into_bytes()
    };
    let fs = [f64::NEG_INFINITY, -1.5, -1.0, 0.0, 1.0, 1.5, f64::INFINITY];
    let enc: Vec<Vec<u8>> = fs.iter().map(|&f| fb(f)).collect();
    for i in 1..enc.len() {
        assert!(enc[i - 1] < enc[i], "float order at {i}");
    }
    for f in [-3.5, -1.0, 0.0, 0.1, 1.5, 1e300] {
        let mut w = Writer::new();
        w.append_f64(f);
        if let Value::F64(g) = unpack(&w.into_bytes()).unwrap()[0] {
            assert_eq!(g, f);
        } else {
            panic!("not f64");
        }
    }
}
