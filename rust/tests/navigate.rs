use struple::{encode, pack, view, MapView, Reader, Value, View};

fn int_of(b: &[u8]) -> i128 {
    match Reader::new(b).next().unwrap().unwrap() {
        struple::Element::Int(i) => i,
        _ => panic!("not int"),
    }
}
fn str_of(b: &[u8]) -> String {
    match Reader::new(b).next().unwrap().unwrap() {
        struple::Element::Str(s) => s,
        _ => panic!("not string"),
    }
}

#[test]
fn stream_ops() {
    let buf = pack(&[
        Value::Str("users".into()),
        Value::Int(12345),
        Value::Bool(true),
        Value::Array(vec![Value::Int(1), Value::Int(2), Value::Int(3)]),
    ]);
    let v = view(&buf);
    assert_eq!(v.count().unwrap(), 4);
    assert_eq!(str_of(v.at(0).unwrap().unwrap()), "users");
    assert_eq!(int_of(v.at(1).unwrap().unwrap()), 12345);
    assert!(v.at(4).unwrap().is_none());
    assert_eq!(v.head().unwrap().unwrap(), v.at(0).unwrap().unwrap());
    assert_eq!(View::new(v.tail().unwrap()).count().unwrap(), 3);
    assert_eq!(View::new(v.nth_rest(2).unwrap()).count().unwrap(), 2);
    let tk = v.take(2).unwrap();
    assert_eq!(View::new(tk).count().unwrap(), 2);
    assert_eq!(tk, &buf[..tk.len()]);
}

#[test]
fn predicates_and_descent() {
    assert!(view(&encode(&Value::Str("x".into()))).is_string());
    assert!(view(&encode(&Value::Int(5))).is_int() && view(&encode(&Value::Int(5))).is_number());
    let f = encode(&Value::F64(1.5));
    assert!(view(&f).is_float() && !view(&f).is_int());
    assert!(view(&encode(&Value::Nil)).is_nil());
    assert!(view(&encode(&Value::Bool(true))).is_bool());

    let buf = pack(&[Value::Array(vec![Value::Int(10), Value::Int(20)])]);
    let v = view(&buf);
    assert!(v.is_array() && v.is_container());
    assert_eq!(v.count().unwrap(), 1);
    let inner = v.contained_items().unwrap().unwrap();
    let iv = View::new(&inner);
    assert_eq!(iv.count().unwrap(), 2);
    assert_eq!(int_of(iv.at(0).unwrap().unwrap()), 10);
    assert_eq!(int_of(iv.at(1).unwrap().unwrap()), 20);
}

#[test]
fn map_lookup() {
    let buf = pack(&[Value::Map(vec![
        (Value::Str("c".into()), Value::Int(3)),
        (Value::Str("a".into()), Value::Int(1)),
        (Value::Str("b".into()), Value::Int(2)),
    ])]);
    let v = view(&buf);
    assert!(v.is_map());
    let inner = v.contained_items().unwrap().unwrap();
    let m = MapView::new(&inner);
    assert_eq!(m.count().unwrap(), 3);

    let kb = encode(&Value::Str("b".into()));
    assert_eq!(int_of(m.get(&kb).unwrap().unwrap()), 2);
    assert!(m.get(&encode(&Value::Str("z".into()))).unwrap().is_none());
    assert!(m.get(&encode(&Value::Str("aa".into()))).unwrap().is_none());

    let mut it = m.entries();
    let mut keys = Vec::new();
    while let Some((k, _)) = it.next_entry().unwrap() {
        keys.push(str_of(k));
    }
    assert_eq!(keys, vec!["a", "b", "c"]);
}
