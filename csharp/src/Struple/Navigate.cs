using System;
using System.Collections;
using System.Collections.Generic;

namespace Struple;

/// <summary>
/// Navigation / query over an encoded struple buffer.
///
/// <para>A buffer is a stream of elements; these helpers slice and inspect it without decoding
/// values. Every result is itself a valid struple buffer, so it composes and recurses.</para>
///
/// <para>Stream ops (<c>Count</c>, <c>At</c>, <c>Head</c>, <c>Tail</c>, <c>NthRest</c>, <c>Take</c>)
/// operate on the top-level element stream. To descend into an array/map/set, use
/// <c>ContainedItems</c> to get its inner stream, then view that.</para>
/// </summary>
public static class Navigate
{
    public static View NewView(byte[] bytes) => new View(bytes);

    public sealed class View
    {
        public readonly byte[] Bytes;

        public View(byte[] bytes)
        {
            Bytes = bytes;
        }

        public Struple.Reader Reader() => new Struple.Reader(Bytes);

        /// <summary>Number of top-level elements.</summary>
        public int Count()
        {
            var r = Reader();
            int n = 0;
            while (r.Skip()) n++;
            return n;
        }

        /// <summary>The element at <c>index</c>, as a zero-copy sub-view (null if out of range).</summary>
        public byte[]? At(int index)
        {
            var r = Reader();
            int i = 0;
            byte[]? v;
            while ((v = r.NextView()) != null)
            {
                if (i == index) return v;
                i++;
            }
            return null;
        }

        /// <summary>The first element (null if empty).</summary>
        public byte[]? Head() => At(0);

        /// <summary>Everything after the first element (empty if 0 or 1 elements).</summary>
        public byte[] Tail()
        {
            var r = Reader();
            r.NextView();
            return r.Rest();
        }

        /// <summary>Drop <c>n</c> elements; return the remaining stream.</summary>
        public byte[] NthRest(int n)
        {
            var r = Reader();
            for (int i = 0; i < n; i++)
            {
                if (!r.Skip()) break;
            }
            return r.Rest();
        }

        /// <summary>The first <c>n</c> elements, as a contiguous sub-view.</summary>
        public byte[] Take(int n)
        {
            var r = Reader();
            for (int i = 0; i < n; i++)
            {
                if (!r.Skip()) break;
            }
            int consumed = Bytes.Length - r.Rest().Length;
            var outBuf = new byte[consumed];
            System.Array.Copy(Bytes, outBuf, consumed);
            return outBuf;
        }

        /// <summary>The type code of the first element (-1 if empty).</summary>
        public int HeadType() => Bytes.Length > 0 ? (Bytes[0] & 0xFF) : -1;

        public bool IsNil() => HeadType() == Struple.Nil;
        public bool IsUndefined() => HeadType() == Struple.Undef;

        public bool IsBool()
        {
            int t = HeadType();
            return t == Struple.BoolFalse || t == Struple.BoolTrue;
        }

        public bool IsInt()
        {
            int t = HeadType();
            if (t < 0) return false;
            return t == Struple.IntZero || t == Struple.IntNegBig || t == Struple.IntPosBig
                || (t >= Struple.IntNegMin && t <= Struple.IntNegMax)
                || (t >= Struple.IntPosMin && t <= Struple.IntPosMax);
        }

        public bool IsFloat()
        {
            int t = HeadType();
            return t == Struple.Float32 || t == Struple.Float64;
        }

        public bool IsDecimal() => HeadType() == Struple.DecimalCode;

        public bool IsNumber() => IsInt() || IsFloat() || IsDecimal();

        public bool IsTimestamp() => HeadType() == Struple.Timestamp;
        public bool IsUuid() => HeadType() == Struple.Uuid;
        public bool IsString() => HeadType() == Struple.String;
        public bool IsBytes() => HeadType() == Struple.Bytes;
        public bool IsArray() => HeadType() == Struple.Array;
        public bool IsMap() => HeadType() == Struple.Map;
        public bool IsSet() => HeadType() == Struple.Set;

        public bool IsContainer()
        {
            int t = HeadType();
            return t == Struple.Array || t == Struple.Map || t == Struple.Set;
        }

        /// <summary>
        /// The first element's framed body when it is a container (escapes intact). Null if the head
        /// isn't a container.
        /// </summary>
        public byte[]? ContainerBody()
        {
            if (!IsContainer()) return null;
            // Re-scan the framed body without un-escaping (mirror of zero-copy containerBody).
            int start = 1;
            int i = 1;
            while (i < Bytes.Length)
            {
                if ((Bytes[i] & 0xFF) == 0x00)
                {
                    if (i + 1 < Bytes.Length && (Bytes[i + 1] & 0xFF) == Struple.EscapeByte)
                    {
                        i += 2;
                        continue;
                    }
                    var outBuf = new byte[i - start];
                    System.Array.Copy(Bytes, start, outBuf, 0, outBuf.Length);
                    return outBuf;
                }
                i++;
            }
            return null;
        }

        /// <summary>The container's inner element stream, un-escaped. View it with a child View/MapView.</summary>
        public byte[]? ContainedItems()
        {
            if (!IsContainer()) return null;
            var e = Reader().Next();
            if (e == null) return null;
            switch (e.Kind)
            {
                case Struple.Kind.Array:
                case Struple.Kind.Map:
                case Struple.Kind.Set:
                    return e.Inner;
                default:
                    return null;
            }
        }
    }

    /// <summary>A (key, value) entry of a map's inner stream (raw element byte slices).</summary>
    public sealed class Entry
    {
        public readonly byte[] Key;
        public readonly byte[] Value;

        public Entry(byte[] key, byte[] value)
        {
            Key = key;
            Value = value;
        }
    }

    /// <summary>
    /// Reads key/value pairs from a map's inner stream (the un-escaped body from
    /// <see cref="View.ContainedItems"/>). Keys are in canonical (sorted) order, so <c>Get</c>
    /// early-exits.
    /// </summary>
    public sealed class MapView
    {
        public readonly byte[] Inner;

        public MapView(byte[] inner)
        {
            Inner = inner;
        }

        public int Count() => new View(Inner).Count() / 2;

        public List<Entry> Entries()
        {
            var list = new List<Entry>();
            var r = new Struple.Reader(Inner);
            byte[]? k;
            while ((k = r.NextView()) != null)
            {
                byte[]? v = r.NextView();
                if (v == null) throw new Struple.StrupleException("malformed map");
                list.Add(new Entry(k, v));
            }
            return list;
        }

        /// <summary>Look up the value bytes for an encoded key. Ordered scan with early exit.</summary>
        public byte[]? Get(byte[] key)
        {
            var r = new Struple.Reader(Inner);
            byte[]? k;
            while ((k = r.NextView()) != null)
            {
                byte[]? v = r.NextView();
                if (v == null) throw new Struple.StrupleException("malformed map");
                int c = Struple.Compare(k, key);
                if (c == 0) return v;
                if (c > 0) return null;
            }
            return null;
        }

        /// <summary>Materialize a random-access index for O(log n) <c>Get</c> and O(1) <c>At</c>.</summary>
        public IndexedMap Indexed() => new IndexedMap(Inner);
    }

    /// <summary>
    /// A map's entries materialized into a random-access index. Building it is one O(n) pass over the
    /// inner stream; thereafter <c>Get</c> is an O(log n) binary search (canonical key order means a
    /// key byte compare <em>is</em> the sort order) and <c>At</c> is O(1).
    /// </summary>
    public sealed class IndexedMap : IEnumerable<Entry>
    {
        private readonly Entry[] _entries;

        public IndexedMap(byte[] inner)
        {
            var list = new List<Entry>();
            var r = new Struple.Reader(inner);
            byte[]? k;
            while ((k = r.NextView()) != null)
            {
                byte[]? v = r.NextView();
                if (v == null) throw new Struple.StrupleException("malformed map");
                list.Add(new Entry(k, v));
            }
            _entries = list.ToArray();
        }

        /// <summary>Number of entries — O(1).</summary>
        public int Count() => _entries.Length;

        /// <summary>The entry at <c>index</c> in canonical (sorted) order — O(1); null if out of range.</summary>
        public Entry? At(int index) => (index >= 0 && index < _entries.Length) ? _entries[index] : null;

        /// <summary>Look up the value bytes for an encoded key — O(log n) binary search.</summary>
        public byte[]? Get(byte[] key)
        {
            int? i = Find(key);
            return i.HasValue ? _entries[i.Value].Value : null;
        }

        /// <summary>The index of <c>key</c> in canonical order, or null — O(log n).</summary>
        public int? Find(byte[] key)
        {
            int lo = 0;
            int hi = _entries.Length;
            while (lo < hi)
            {
                int mid = lo + (hi - lo) / 2;
                int c = Struple.Compare(_entries[mid].Key, key);
                if (c == 0) return mid;
                if (c < 0) lo = mid + 1;
                else hi = mid;
            }
            return null;
        }

        public IEnumerator<Entry> GetEnumerator()
        {
            foreach (var e in _entries) yield return e;
        }

        IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
    }
}
