use struple::{compare, encode, pack, unpack, Value, Writer};
use std::cmp::Ordering;

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
    assert_eq!(hex(&encode(&Value::Int(1i128 << 64))), "310109010000000000000000");
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
