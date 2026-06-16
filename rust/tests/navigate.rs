use struple::{encode, pack, view, IndexedMap, MapView, Reader, Value, View};

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

#[test]
fn indexed_map() {
    // eight entries "a".."h" -> 1..8, fed out of order so canonicalization sorts them
    let order = ["h", "c", "a", "g", "d", "f", "b", "e"];
    let entries: Vec<(Value, Value)> = order
        .iter()
        .enumerate()
        .map(|(i, &k)| (Value::Str(k.into()), Value::Int((i + 1) as i128)))
        .collect();
    let buf = pack(&[Value::Map(entries)]);

    let v = view(&buf);
    assert!(v.is_map());
    let inner = v.contained_items().unwrap().unwrap();
    let im = IndexedMap::new(&inner).unwrap();

    assert_eq!(im.count(), 8);
    assert_eq!(im.len(), 8);

    // at() walks canonical (sorted) order: a,b,c,...,h
    for (i, ch) in "abcdefgh".chars().enumerate() {
        let (k, _) = im.at(i).unwrap();
        assert_eq!(str_of(k), ch.to_string());
    }
    assert!(im.at(8).is_none());

    // get() binary-searches; agrees with the linear MapView.get on every key
    let m = MapView::new(&inner);
    for ch in "abcdefgh".chars() {
        let key = encode(&Value::Str(ch.to_string()));
        let want = m.get(&key).unwrap().unwrap();
        assert_eq!(want, im.get(&key).unwrap());
    }

    // "e" was inserted 8th (value 8) but sits at sorted position 4 — get still finds it
    let ke = encode(&Value::Str("e".into()));
    assert_eq!(im.find(&ke), Some(4));
    assert_eq!(int_of(im.get(&ke).unwrap()), 8);

    // misses: before, between, and after the key range
    assert!(im.get(&encode(&Value::Str("A".into()))).is_none()); // below "a"
    assert!(im.get(&encode(&Value::Str("cc".into()))).is_none()); // between "c" and "d"
    assert!(im.get(&encode(&Value::Str("z".into()))).is_none()); // above "h"
    assert_eq!(im.find(&encode(&Value::Str("a".into()))), Some(0));
    assert_eq!(im.find(&encode(&Value::Str("h".into()))), Some(7));

    // iterator yields the same canonical order
    let collected: Vec<String> = im.iter().map(|(k, _)| str_of(k)).collect();
    assert_eq!(collected, vec!["a", "b", "c", "d", "e", "f", "g", "h"]);

    // MapView::indexed shortcut builds an equivalent index
    let im2 = m.indexed().unwrap();
    assert_eq!(im2.count(), 8);
    assert_eq!(im2.get(&ke).map(int_of), Some(8));
}
