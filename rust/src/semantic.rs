//! Semantic (value-based) ordering — a port of the Zig reference's semantic.zig.
//!
//! `compare` gives the raw byte order (type codes dominate). `semantic_order`
//! compares by *value*: int, big-int, float32 and float64 all compare by their
//! exact mathematical value, so `int 5 == float 5.0` and large integers compare
//! against floats with no precision loss. NaN sorts greatest; `-0.0 == 0`.

use crate::codec::{Element, Error, Reader};
use std::cmp::Ordering;

/// Compare two encoded streams element-by-element by semantic value.
pub fn semantic_order(a: &[u8], b: &[u8]) -> Result<Ordering, Error> {
    let mut ra = Reader::new(a);
    let mut rb = Reader::new(b);
    loop {
        let ea = ra.next()?;
        let eb = rb.next()?;
        match (&ea, &eb) {
            (None, None) => return Ok(Ordering::Equal),
            (None, Some(_)) => return Ok(Ordering::Less),
            (Some(_), None) => return Ok(Ordering::Greater),
            (Some(x), Some(y)) => {
                let c = compare_elements(x, y)?;
                if c != Ordering::Equal {
                    return Ok(c);
                }
            }
        }
    }
}

/// Semantic equality — `semantic_order(..) == Equal`.
pub fn semantic_eq(a: &[u8], b: &[u8]) -> Result<bool, Error> {
    Ok(semantic_order(a, b)? == Ordering::Equal)
}

fn class_rank(e: &Element) -> u8 {
    match e {
        Element::Nil => 0,
        Element::Undefined => 1,
        Element::Bool(_) => 2,
        Element::Int(_) | Element::BigInt { .. } | Element::F32(_) | Element::F64(_) | Element::Decimal(_) => 3,
        Element::Timestamp(_) => 4,
        Element::Uuid(_) => 5,
        Element::Str(_) => 6,
        Element::Bytes(_) => 7,
        Element::Array(_) => 8,
        Element::Map(_) => 9,
        Element::Set(_) => 10,
    }
}

fn compare_elements(a: &Element, b: &Element) -> Result<Ordering, Error> {
    let (ra, rb) = (class_rank(a), class_rank(b));
    if ra != rb {
        return Ok(ra.cmp(&rb));
    }
    Ok(match (a, b) {
        (Element::Nil, _) | (Element::Undefined, _) => Ordering::Equal,
        (Element::Bool(x), Element::Bool(y)) => x.cmp(y),
        (Element::Timestamp(x), Element::Timestamp(y)) => x.cmp(y),
        (Element::Uuid(x), Element::Uuid(y)) => x.cmp(y),
        (Element::Str(x), Element::Str(y)) => x.as_bytes().cmp(y.as_bytes()),
        (Element::Bytes(x), Element::Bytes(y)) => x.cmp(y),
        (Element::Array(x), Element::Array(y))
        | (Element::Set(x), Element::Set(y))
        | (Element::Map(x), Element::Map(y)) => semantic_order(x, y)?,
        // remaining same-class case: numbers (Int / BigInt / F32 / F64)
        _ => compare_numbers(a, b),
    })
}

// ----------------------------------------------------------------- numbers

// Rank within the number class: -inf < finite < +inf < NaN.
fn num_class(e: &Element) -> u8 {
    let f = match e {
        Element::Int(_) | Element::BigInt { .. } | Element::Decimal(_) => return 1,
        Element::F32(x) => *x as f64,
        Element::F64(x) => *x,
        _ => unreachable!(),
    };
    if f.is_nan() {
        3
    } else if f == f64::INFINITY {
        2
    } else if f == f64::NEG_INFINITY {
        0
    } else {
        1
    }
}

fn float_val(e: &Element) -> f64 {
    match e {
        Element::F32(x) => *x as f64,
        Element::F64(x) => *x,
        _ => unreachable!(),
    }
}

fn is_int(e: &Element) -> bool {
    matches!(e, Element::Int(_) | Element::BigInt { .. })
}

fn compare_numbers(a: &Element, b: &Element) -> Ordering {
    let (ca, cb) = (num_class(a), num_class(b));
    if ca != cb {
        return ca.cmp(&cb);
    }
    if ca != 1 {
        return Ordering::Equal; // both -inf, both +inf, or both NaN
    }
    // Both finite. A decimal on either side routes through the base-10 path.
    if is_decimal(a) || is_decimal(b) {
        return compare_with_decimal(a, b);
    }
    let (ai, bi) = (is_int(a), is_int(b));
    if ai && bi {
        compare_int_int(a, b)
    } else if !ai && !bi {
        float_val(a).partial_cmp(&float_val(b)).unwrap() // both finite
    } else if ai {
        compare_int_finite(a, float_val(b))
    } else {
        compare_int_finite(b, float_val(a)).reverse()
    }
}

fn is_decimal(e: &Element) -> bool {
    matches!(e, Element::Decimal(_))
}

fn sign_rank(f: f64) -> i8 {
    if f > 0.0 {
        1
    } else if f < 0.0 {
        -1
    } else {
        0
    }
}

fn int_sign(e: &Element) -> i8 {
    match e {
        Element::Int(v) => (*v > 0) as i8 - (*v < 0) as i8,
        Element::BigInt { negative, .. } => {
            if *negative {
                -1
            } else {
                1
            }
        }
        _ => unreachable!(),
    }
}

fn compare_int_int(a: &Element, b: &Element) -> Ordering {
    if let (Element::Int(x), Element::Int(y)) = (a, b) {
        return x.cmp(y);
    }
    let (sa, sb) = (int_sign(a), int_sign(b));
    if sa != sb {
        return sa.cmp(&sb);
    }
    let ab = matches!(a, Element::BigInt { .. });
    let bb = matches!(b, Element::BigInt { .. });
    if ab != bb {
        // The big-int always has the larger magnitude than the fixed int.
        return if sa > 0 {
            if ab {
                Ordering::Greater
            } else {
                Ordering::Less
            }
        } else if ab {
            Ordering::Less
        } else {
            Ordering::Greater
        };
    }
    // Both big-ints, same sign: compare true (un-complemented) magnitudes.
    let (ma, mb) = match (a, b) {
        (Element::BigInt { magnitude: x, .. }, Element::BigInt { magnitude: y, .. }) => (x, y),
        _ => unreachable!(),
    };
    let c = cmp_mag(ma, mb);
    if sa < 0 {
        c.reverse()
    } else {
        c
    }
}

fn compare_int_finite(e: &Element, f: f64) -> Ordering {
    match e {
        Element::Int(v) => compare_i128_finite(*v, f),
        Element::BigInt { negative, magnitude } => compare_bigint_finite(*negative, magnitude, f),
        _ => unreachable!(),
    }
}

fn compare_i128_finite(value: i128, f: f64) -> Ordering {
    if value == 0 {
        return 0i8.cmp(&sign_rank(f));
    }
    // Fast path: integers that round-trip through f64 exactly.
    if (-(1i128 << 53)..=(1i128 << 53)).contains(&value) {
        return (value as f64).partial_cmp(&f).unwrap();
    }
    let sign_i: i8 = if value > 0 { 1 } else { -1 };
    let sign_f = sign_rank(f);
    if sign_i != sign_f {
        return sign_i.cmp(&sign_f);
    }
    let (mant, exp) = decompose(f.abs());
    let c = compare_u128_to_scaled(value.unsigned_abs(), mant, exp);
    if sign_i < 0 {
        c.reverse()
    } else {
        c
    }
}

fn compare_bigint_finite(negative: bool, mag: &[u8], f: f64) -> Ordering {
    let sign_i: i8 = if negative { -1 } else { 1 };
    let sign_f = sign_rank(f);
    if sign_i != sign_f {
        return sign_i.cmp(&sign_f);
    }
    let (mant, exp) = decompose(f.abs());
    let c = compare_mag_to_scaled(mag, mant, exp);
    if sign_i < 0 {
        c.reverse()
    } else {
        c
    }
}

// Decompose a finite, nonzero magnitude `g = |f|` into `mant * 2^exp`.
fn decompose(g: f64) -> (u64, i32) {
    let bits = g.to_bits();
    let raw_exp = ((bits >> 52) & 0x7ff) as i32;
    let frac = bits & 0x000f_ffff_ffff_ffff;
    if raw_exp == 0 {
        (frac, -1074) // subnormal
    } else {
        ((1u64 << 52) | frac, raw_exp - 1075)
    }
}

// Compare a u128 `n` to `mant * 2^exp` (both non-negative), exactly.
fn compare_u128_to_scaled(n: u128, mant: u64, exp: i32) -> Ordering {
    if exp >= 0 {
        let sh = exp as u32;
        if sh >= 128 || mant as u128 > (u128::MAX >> sh) {
            return Ordering::Less; // mant<<exp overflows u128, so it exceeds n
        }
        n.cmp(&((mant as u128) << sh))
    } else {
        let sh = (-exp) as u32;
        if sh >= 128 || n > (u128::MAX >> sh) {
            return Ordering::Greater; // n<<sh overflows u128, so n exceeds mant
        }
        (n << sh).cmp(&(mant as u128))
    }
}

// Compare a big-endian magnitude to `mant * 2^exp`, exactly (arbitrary size).
fn compare_mag_to_scaled(mag: &[u8], mant: u64, exp: i32) -> Ordering {
    let mant_be = mant.to_be_bytes();
    let mant_bytes = trim(&mant_be);
    if exp >= 0 {
        cmp_mag(mag, &shift_left(mant_bytes, exp as usize))
    } else {
        cmp_mag(&shift_left(mag, (-exp) as usize), mant_bytes)
    }
}

// ---------------------------------------------------------------------------
// Decimal vs the rest of the number class
// ---------------------------------------------------------------------------

// An exact base-10 value `sign · mag · 10^exp10` (mag big-endian; empty mag == 0).
struct B10 {
    sign: i8,
    mag: Vec<u8>,
    exp10: i64,
}

/// Decompose an int / big-int / decimal into its exact base-10 value.
fn num_to_b10(e: &Element) -> B10 {
    match e {
        Element::Int(v) => {
            if *v == 0 {
                return B10 { sign: 0, mag: Vec::new(), exp10: 0 };
            }
            let mag = trim(&v.unsigned_abs().to_be_bytes()).to_vec();
            B10 { sign: if *v < 0 { -1 } else { 1 }, mag, exp10: 0 }
        }
        Element::BigInt { negative, magnitude } => {
            B10 { sign: if *negative { -1 } else { 1 }, mag: trim(magnitude).to_vec(), exp10: 0 }
        }
        Element::Decimal(d) => {
            if d.is_zero() {
                return B10 { sign: 0, mag: Vec::new(), exp10: 0 };
            }
            let mag = dec_digits_to_mag(&d.coefficient_digits());
            B10 { sign: if d.negative { -1 } else { 1 }, mag, exp10: d.exponent() }
        }
        _ => unreachable!(),
    }
}

fn is_exact_kind(e: &Element) -> bool {
    matches!(e, Element::Int(_) | Element::BigInt { .. } | Element::Decimal(_))
}

fn compare_with_decimal(a: &Element, b: &Element) -> Ordering {
    if is_exact_kind(a) && is_exact_kind(b) {
        let va = num_to_b10(a);
        let vb = num_to_b10(b);
        if va.sign != vb.sign {
            return va.sign.cmp(&vb.sign);
        }
        if va.sign == 0 {
            return Ordering::Equal;
        }
        let c = compare_b10_mag(&va, &vb);
        return if va.sign < 0 { c.reverse() } else { c };
    }
    // exactly one side is a finite float
    if is_exact_kind(a) {
        compare_b10_float(&num_to_b10(a), float_val(b))
    } else {
        compare_b10_float(&num_to_b10(b), float_val(a)).reverse()
    }
}

/// Compare two same-sign, nonzero base-10 magnitudes (`mag · 10^exp10`), exactly.
fn compare_b10_mag(a: &B10, b: &B10) -> Ordering {
    let e = a.exp10.min(b.exp10);
    let sa = mul_pow10(&a.mag, (a.exp10 - e) as usize);
    let sb = mul_pow10(&b.mag, (b.exp10 - e) as usize);
    cmp_mag(&sa, &sb)
}

fn compare_b10_float(v: &B10, f: f64) -> Ordering {
    let sf = sign_rank(f);
    if v.sign != sf {
        return v.sign.cmp(&sf);
    }
    if v.sign == 0 {
        return Ordering::Equal; // both zero
    }
    let (mant, exp) = decompose(f.abs());
    let c = compare_b10_mag_to_float(&v.mag, v.exp10, mant, exp);
    if v.sign < 0 {
        c.reverse()
    } else {
        c
    }
}

/// Compare `mag · 10^exp10` to `mant · 2^e2` (both > 0), exactly. Splits `10^exp10`
/// into `2^exp10 · 5^exp10` and scales both sides up to integers before comparing.
fn compare_b10_mag_to_float(mag: &[u8], exp10: i64, mant: u64, e2: i32) -> Ordering {
    let a_pow2: i64 = 0.max((-exp10).max(-(e2 as i64))); // common 2^ multiplier
    let b_pow5: i64 = 0.max(-exp10); // common 5^ multiplier

    // LHS' = mag · 5^(exp10 + b_pow5) · 2^(exp10 + a_pow2)
    let lhs = mul_pow5(mag, (exp10 + b_pow5) as usize);
    let lhs = shift_left(&lhs, (exp10 + a_pow2) as usize);

    // RHS' = mant · 5^(b_pow5) · 2^(e2 + a_pow2)
    let mant_be = mant.to_be_bytes();
    let rhs = mul_pow5(trim(&mant_be), b_pow5 as usize);
    let rhs = shift_left(&rhs, (e2 as i64 + a_pow2) as usize);

    cmp_mag(&lhs, &rhs)
}

// ------------------------------------------------------------ magnitude helpers

/// Decimal digits (each 0–9, most-significant first) -> big-endian base-256 magnitude.
fn dec_digits_to_mag(digits: &[u8]) -> Vec<u8> {
    let mut bytes: Vec<u8> = Vec::new();
    for &dch in digits {
        let mut carry = dch as u16; // already 0–9
        for b in bytes.iter_mut().rev() {
            let v = *b as u16 * 10 + carry;
            *b = (v & 0xff) as u8;
            carry = v >> 8;
        }
        while carry > 0 {
            bytes.insert(0, (carry & 0xff) as u8);
            carry >>= 8;
        }
    }
    bytes
}

/// `mag · m` (small `m`) as new big-endian bytes, trimmed.
fn mul_small(mag: &[u8], m: u16) -> Vec<u8> {
    let mut bytes = mag.to_vec();
    let mut carry: u32 = 0;
    for b in bytes.iter_mut().rev() {
        let v = *b as u32 * m as u32 + carry;
        *b = (v & 0xff) as u8;
        carry = v >> 8;
    }
    while carry > 0 {
        bytes.insert(0, (carry & 0xff) as u8);
        carry >>= 8;
    }
    bytes
}

fn mul_pow(mag: &[u8], base: u16, k: usize) -> Vec<u8> {
    let mut cur = mag.to_vec();
    for _ in 0..k {
        cur = mul_small(&cur, base);
    }
    cur
}

fn mul_pow10(mag: &[u8], k: usize) -> Vec<u8> {
    mul_pow(mag, 10, k)
}

fn mul_pow5(mag: &[u8], k: usize) -> Vec<u8> {
    mul_pow(mag, 5, k)
}

fn trim(b: &[u8]) -> &[u8] {
    let mut s = 0;
    while s < b.len() && b[s] == 0 {
        s += 1;
    }
    &b[s..]
}

fn cmp_mag(a: &[u8], b: &[u8]) -> Ordering {
    let (a, b) = (trim(a), trim(b));
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

/// `src << bits` as new big-endian bytes (may carry leading zeros).
fn shift_left(src: &[u8], bits: usize) -> Vec<u8> {
    let byte_shift = bits / 8;
    let bit_shift = (bits % 8) as u32;
    let mut tmp = vec![0u8; src.len() + 1];
    let mut carry: u16 = 0;
    for i in (0..src.len()).rev() {
        let cur = ((src[i] as u16) << bit_shift) | carry;
        tmp[i + 1] = cur as u8;
        carry = cur >> 8;
    }
    tmp[0] = carry as u8;
    tmp.resize(tmp.len() + byte_shift, 0); // append byte_shift zeros at the LSB end
    tmp
}
