package struple

// Navigation / query over an encoded struple buffer.
//
// A buffer is a stream of elements; these helpers slice and inspect it without
// decoding values. Everything is zero-copy — results are sub-slices of the
// input, each itself a valid struple buffer, so it all composes and recurses.
//
// Stream ops (Count, At, Head, Tail, NthRest, Take) operate on the buffer's
// top-level element stream. To descend into an array/map/set, use ContainedItems
// to get its inner stream, then view that.

// View is a zero-copy inspector over an encoded struple buffer.
type View struct {
	Bytes []byte
}

// NewView returns a View over bytes.
func NewView(bytes []byte) View { return View{Bytes: bytes} }

func (v View) reader() *Reader { return NewReader(v.Bytes) }

// Count returns the number of top-level elements.
func (v View) Count() (int, error) {
	r := v.reader()
	n := 0
	for {
		ok, err := r.Skip()
		if err != nil {
			return 0, err
		}
		if !ok {
			break
		}
		n++
	}
	return n, nil
}

// At returns the element at index as a zero-copy sub-view. ok is false if out of
// range.
func (v View) At(index int) (view []byte, ok bool, err error) {
	r := v.reader()
	for i := 0; ; i++ {
		view, ok, err = r.NextView()
		if err != nil || !ok {
			return nil, false, err
		}
		if i == index {
			return view, true, nil
		}
	}
}

// Head returns the first element. ok is false if empty.
func (v View) Head() (view []byte, ok bool, err error) { return v.At(0) }

// Tail returns everything after the first element (empty if 0 or 1 elements).
func (v View) Tail() ([]byte, error) {
	r := v.reader()
	if _, _, err := r.NextView(); err != nil {
		return nil, err
	}
	return r.Rest(), nil
}

// NthRest drops n elements and returns the remaining stream.
func (v View) NthRest(n int) ([]byte, error) {
	r := v.reader()
	for i := 0; i < n; i++ {
		ok, err := r.Skip()
		if err != nil {
			return nil, err
		}
		if !ok {
			break
		}
	}
	return r.Rest(), nil
}

// Take returns the first n elements as a contiguous sub-view.
func (v View) Take(n int) ([]byte, error) {
	r := v.reader()
	for i := 0; i < n; i++ {
		ok, err := r.Skip()
		if err != nil {
			return nil, err
		}
		if !ok {
			break
		}
	}
	return v.Bytes[:len(v.Bytes)-len(r.Rest())], nil
}

// HeadType returns the type code of the first element. ok is false if empty.
func (v View) HeadType() (byte, bool) {
	if len(v.Bytes) > 0 {
		return v.Bytes[0], true
	}
	return 0, false
}

func (v View) IsNil() bool       { t, ok := v.HeadType(); return ok && t == tcNil }
func (v View) IsUndefined() bool { t, ok := v.HeadType(); return ok && t == tcUndef }

func (v View) IsBool() bool {
	t, ok := v.HeadType()
	return ok && (t == tcBoolFalse || t == tcBoolTrue)
}

func (v View) IsInt() bool {
	t, ok := v.HeadType()
	if !ok {
		return false
	}
	return t == tcIntZero || t == tcIntNegBig || t == tcIntPosBig ||
		(t >= tcIntNegMin && t <= tcIntNegMax) ||
		(t >= tcIntPosMin && t <= tcIntPosMax)
}

func (v View) IsFloat() bool {
	t, ok := v.HeadType()
	return ok && (t == tcFloat32 || t == tcFloat64)
}

func (v View) IsDecimal() bool { t, ok := v.HeadType(); return ok && t == tcDecimal }

func (v View) IsNumber() bool { return v.IsInt() || v.IsFloat() || v.IsDecimal() }

func (v View) IsTimestamp() bool { t, ok := v.HeadType(); return ok && t == tcTimestamp }
func (v View) IsUUID() bool      { t, ok := v.HeadType(); return ok && t == tcUUID }
func (v View) IsString() bool    { t, ok := v.HeadType(); return ok && t == tcString }
func (v View) IsBytes() bool     { t, ok := v.HeadType(); return ok && t == tcBytes }
func (v View) IsArray() bool     { t, ok := v.HeadType(); return ok && t == tcArray }
func (v View) IsMap() bool       { t, ok := v.HeadType(); return ok && t == tcMap }
func (v View) IsSet() bool       { t, ok := v.HeadType(); return ok && t == tcSet }

func (v View) IsContainer() bool {
	t, ok := v.HeadType()
	return ok && (t == tcArray || t == tcMap || t == tcSet)
}

// ContainerBody returns the first element's framed body when it is a container
// (escapes intact, zero-copy). ok is false if the head isn't a container.
func (v View) ContainerBody() (body []byte, ok bool, err error) {
	if !v.IsContainer() {
		return nil, false, nil
	}
	r := v.reader()
	e, has, err := r.Next()
	if err != nil || !has {
		return nil, false, err
	}
	switch e.Kind {
	case KindArray, KindMap, KindSet:
		return e.Body, true, nil
	default:
		return nil, false, nil
	}
}

// ContainedItems returns the container's inner element stream, un-escaped (a
// fresh slice owned by the caller). View it with NewView, or a map with
// NewMapView. ok is false if the head isn't a container.
func (v View) ContainedItems() (inner []byte, ok bool, err error) {
	body, ok, err := v.ContainerBody()
	if err != nil || !ok {
		return nil, ok, err
	}
	return Unescape(body), true, nil
}

// ---------------------------------------------------------------------------
// MapView — reads key/value pairs from a map's inner stream
// ---------------------------------------------------------------------------

// MapEntry is a key/value pair of encoded element views.
type MapEntry struct {
	Key   []byte
	Value []byte
}

// MapView reads key/value pairs from a map's inner stream (the un-escaped body
// from View.ContainedItems). Keys are in canonical (sorted) order, so Get
// early-exits.
type MapView struct {
	Inner []byte
}

// NewMapView returns a MapView over a map's inner stream.
func NewMapView(inner []byte) MapView { return MapView{Inner: inner} }

// Count returns the number of entries.
func (m MapView) Count() (int, error) {
	n, err := NewView(m.Inner).Count()
	return n / 2, err
}

// MapIterator yields entries of a MapView in canonical order.
type MapIterator struct {
	r *Reader
}

// Next returns the next entry. ok is false at end of stream.
func (it *MapIterator) Next() (e MapEntry, ok bool, err error) {
	k, ok, err := it.r.NextView()
	if err != nil || !ok {
		return MapEntry{}, false, err
	}
	val, ok, err := it.r.NextView()
	if err != nil {
		return MapEntry{}, false, err
	}
	if !ok {
		return MapEntry{}, false, ErrTruncated
	}
	return MapEntry{Key: k, Value: val}, true, nil
}

// Iterator returns an iterator over the map's entries in canonical order.
func (m MapView) Iterator() *MapIterator { return &MapIterator{r: NewReader(m.Inner)} }

// Get looks up key (the encoded bytes of a key element). It returns the value's
// encoded bytes; ok is false if absent. Ordered scan with early exit.
func (m MapView) Get(key []byte) (value []byte, ok bool, err error) {
	it := m.Iterator()
	for {
		e, has, err := it.Next()
		if err != nil || !has {
			return nil, false, err
		}
		switch bytesCompare(e.Key, key) {
		case 0:
			return e.Value, true, nil
		case 1:
			return nil, false, nil
		}
	}
}

// Indexed materializes a random-access index for O(log n) Get and O(1) At.
func (m MapView) Indexed() (*IndexedMap, error) { return NewIndexedMap(m.Inner) }

// ---------------------------------------------------------------------------
// IndexedMap — random-access index over a map's entries
// ---------------------------------------------------------------------------

// IndexedMap materializes a map's entries into a random-access index. Building it
// is one O(n) pass over the inner stream; thereafter Get is an O(log n) binary
// search (canonical key order means a key compare is the sort order) and At is
// O(1). The entry slices borrow the inner stream, so keep it alive.
type IndexedMap struct {
	Entries []MapEntry
}

// NewIndexedMap builds an index from a map's inner stream (the un-escaped body
// from View.ContainedItems).
func NewIndexedMap(inner []byte) (*IndexedMap, error) {
	var entries []MapEntry
	r := NewReader(inner)
	for {
		k, ok, err := r.NextView()
		if err != nil {
			return nil, err
		}
		if !ok {
			break
		}
		val, ok, err := r.NextView()
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, ErrTruncated
		}
		entries = append(entries, MapEntry{Key: k, Value: val})
	}
	return &IndexedMap{Entries: entries}, nil
}

// Count returns the number of entries — O(1).
func (im *IndexedMap) Count() int { return len(im.Entries) }

// At returns the entry at index in canonical order — O(1). ok is false if out of
// range.
func (im *IndexedMap) At(index int) (e MapEntry, ok bool) {
	if index < 0 || index >= len(im.Entries) {
		return MapEntry{}, false
	}
	return im.Entries[index], true
}

// Get looks up key (an encoded key element) — O(log n). ok is false if absent.
func (im *IndexedMap) Get(key []byte) (value []byte, ok bool) {
	if i, found := im.Find(key); found {
		return im.Entries[i].Value, true
	}
	return nil, false
}

// Find returns the index of key in canonical order — O(log n). found is false if
// absent.
func (im *IndexedMap) Find(key []byte) (index int, found bool) {
	lo, hi := 0, len(im.Entries)
	for lo < hi {
		mid := lo + (hi-lo)/2
		switch bytesCompare(im.Entries[mid].Key, key) {
		case 0:
			return mid, true
		case -1:
			lo = mid + 1
		default:
			hi = mid
		}
	}
	return 0, false
}

// IndexedMapIterator yields entries of an IndexedMap in canonical order.
type IndexedMapIterator struct {
	entries []MapEntry
	i       int
}

// Next returns the next entry. ok is false at end.
func (it *IndexedMapIterator) Next() (e MapEntry, ok bool) {
	if it.i >= len(it.entries) {
		return MapEntry{}, false
	}
	e = it.entries[it.i]
	it.i++
	return e, true
}

// Iterator returns the entries in canonical (sorted) order.
func (im *IndexedMap) Iterator() *IndexedMapIterator {
	return &IndexedMapIterator{entries: im.Entries}
}
