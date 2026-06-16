#!/usr/bin/env python3
"""
struple — global serialization energy/carbon scale model.

Turns *measured* per-operation struple-vs-JSON deltas (from this repo's
benchmarks) into a global, civilization-scale estimate of the energy and carbon
currently spent on the serialization "tax", and how much of it is reclaimable.

IT IS A MODEL, NOT A MEASUREMENT. The per-operation inputs are real (measured
here with RAPL); the macro inputs (global volumes, fractions) are cited
estimates with wide uncertainty, so everything is reported as a low/mid/high
range. The point is not a single number — it is to show that even *conservative*
assumptions land in climate-relevant territory, and to let anyone plug in their
own numbers.

Run: python3 rfc/scale_model.py
"""

# ---------------------------------------------------------------------------
# MEASURED in this project (real, reproducible) — see BENCHMARKS.md and the
# vectordb end-to-end energy bench.
# ---------------------------------------------------------------------------
MEASURED = {
    # Wire/storage size per record, "quote" workload (bytes).
    "struple_bytes_per_record": 21,
    "json_bytes_per_record": 63,            # JSON ≈ 3.0x struple on the wire
    # End-to-end CPU energy ratio, ordered-store workload (RAPL package-0):
    # JSON used ~10x the CPU energy of struple (incl. its mandatory struple key).
    "json_vs_struple_cpu_energy_ratio": 10.0,
}
SIZE_RATIO_JSON = MEASURED["json_bytes_per_record"] / MEASURED["struple_bytes_per_record"]

# ---------------------------------------------------------------------------
# MACRO inputs — cited estimates, each as (low, mid, high). Sources in NOTES.
# ---------------------------------------------------------------------------
SCEN = ("low", "mid", "high")

# [1] Global data-centre electricity, TWh/yr (IEA ~240–340 TWh in 2022, rising
#     fast with AI; ~415+ TWh by 2024). We bracket the operational range.
DC_TWH = {"low": 300, "mid": 415, "high": 550}

# [2] Fraction of data-centre energy spent on the "data-centre tax" addressable
#     by a better wire format — (de)serialization, data movement/memcpy, RPC
#     framing, compression. Kanev et al. (ISCA 2015) found low-level common
#     functions up to ~30% of WSC cycles; serialization/data-movement is a
#     large slice. We take a deliberately conservative addressable fraction.
SER_FRACTION = {"low": 0.02, "mid": 0.05, "high": 0.10}

# [3] Fraction of that serialization work done in text/schema-free-but-bloated
#     formats (JSON dominates web/microservice/API/log traffic; much config and
#     inter-service messaging is JSON).
JSON_SHARE = {"low": 0.30, "mid": 0.50, "high": 0.70}

# [4] Fraction of the JSON serialization energy that struple eliminates — from
#     size (≈3x smaller → less transfer + storage + cache), compute (~10x less
#     CPU energy measured here), and ordering (no separate comparator/index
#     layer). Capped well below the measured 90% to stay conservative.
STRUPLE_REDUCTION = {"low": 0.40, "mid": 0.60, "high": 0.80}

# [5] Grid carbon intensity, gCO2e/kWh (global avg ~480; greener grids lower).
GRID_GCO2_PER_KWH = 480.0

# Relatable equivalents (rough, for intuition only).
HOME_KWH_PER_YR = 3500.0          # ~ EU household electricity / yr
CAR_TCO2_PER_YR = 4.6             # ~ avg passenger car / yr


def reclaimable_twh(scn):
    """Reclaimable serialization energy, TWh/yr, for a scenario."""
    return DC_TWH[scn] * SER_FRACTION[scn] * JSON_SHARE[scn] * STRUPLE_REDUCTION[scn]


def report():
    print("=" * 74)
    print(" struple — global serialization energy/carbon scale model")
    print("=" * 74)
    print(f" Measured here: JSON ≈ {SIZE_RATIO_JSON:.1f}x struple on the wire, "
          f"~{MEASURED['json_vs_struple_cpu_energy_ratio']:.0f}x the CPU energy end-to-end.")
    print(" Macro inputs are cited estimates (see NOTES); results are a RANGE,")
    print(" not a single figure. Even the LOW column is climate-relevant.\n")

    print(f"  {'parameter':<42}{'low':>9}{'mid':>9}{'high':>9}")
    print("  " + "-" * 69)
    rows = [
        ("data-centre electricity (TWh/yr) [1]", DC_TWH, "{:.0f}"),
        ("× addressable 'serialization tax' [2]", SER_FRACTION, "{:.0%}"),
        ("× share in JSON/text formats [3]", JSON_SHARE, "{:.0%}"),
        ("× fraction struple reclaims [4]", STRUPLE_REDUCTION, "{:.0%}"),
    ]
    for label, d, fmt in rows:
        print(f"  {label:<42}" + "".join(fmt.format(d[s]).rjust(9) for s in SCEN))
    print("  " + "-" * 69)

    twh = {s: reclaimable_twh(s) for s in SCEN}
    mtco2 = {s: twh[s] * 1e9 * GRID_GCO2_PER_KWH / 1e12 for s in SCEN}  # kWh*g → t→Mt
    homes = {s: twh[s] * 1e9 / HOME_KWH_PER_YR for s in SCEN}
    cars = {s: mtco2[s] * 1e6 / CAR_TCO2_PER_YR for s in SCEN}

    print(f"  {'RECLAIMABLE ENERGY (TWh/yr)':<42}" + "".join(f"{twh[s]:.1f}".rjust(9) for s in SCEN))
    print(f"  {'RECLAIMABLE CARBON (MtCO2e/yr)':<42}" + "".join(f"{mtco2[s]:.2f}".rjust(9) for s in SCEN))
    print()
    print(f"  ≈ electricity of {homes['low']/1e6:.1f}–{homes['high']/1e6:.1f} million homes/yr")
    print(f"  ≈ taking {cars['low']/1e6:.1f}–{cars['high']/1e6:.1f} million cars off the road/yr")
    print(f"  (grid: {GRID_GCO2_PER_KWH:.0f} gCO2e/kWh)\n")

    print(" Headline (mid): reclaiming ~{:.0f} TWh/yr (~{:.1f} MtCO2e/yr) — and that is the".format(twh["mid"], mtco2["mid"]))
    print(" SERVER side only. It ignores the ~{:.1f}x wire-size reduction's network".format(SIZE_RATIO_JSON))
    print(" energy across billions of client devices, and the super-linear network")
    print(" effect of a more sympathetic protocol across the whole fabric.\n")

    print(" NOTES / SOURCES (all approximate; dial them to your own assumptions):")
    print("  [1] IEA, data-centre electricity ~240–340 TWh (2022), rising with AI.")
    print("  [2] Kanev et al., 'Profiling a Warehouse-Scale Computer' (ISCA 2015):")
    print("      the 'data-centre tax' (ser/deser, memcpy, RPC, compression) is a")
    print("      large share of cycles; we take a conservative addressable slice.")
    print("  [3] JSON's dominance of web/API/microservice/log traffic (industry).")
    print("  [4] This repo's measured size (~3x) + CPU-energy (~10x) deltas, capped.")
    print("  [5] Global avg grid intensity ~480 gCO2e/kWh (IEA / Our World in Data).")
    print("=" * 74)


if __name__ == "__main__":
    report()
