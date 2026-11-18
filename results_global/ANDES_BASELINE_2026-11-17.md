# Andes concentration against a chance baseline

**Added 17 Nov 2026, after the submission deadline.** This note analyses the frozen results that were submitted (`web/app_bundle.json`, run created 2026-11-15T11:50Z). It uses no new data and nothing was re-run. Reproduce it with `python3 engine/andes_baseline.py`.

## Question

The search was never told where analog testing already happens. Many of its terrain matches landed in the Andes. Is that more than chance, given where the search could look?

## Method

- **Region:** a fixed box over western South America, latitude 56°S to 12°N and longitude 82°W to 62°W. It is cruder than a geological definition of the Andes, which is why it counts 168 records rather than the 143 quoted in the submission.
- **Baseline:** the box's share of all windows the search evaluated (after water, ice, forest, cropland and built-up land were masked). If candidates landed in proportion to the area searched, that is the share expected.
- **Reported at three levels:** records, distinct places, and 1° tiles. Neighbouring windows are not independent, so the binomial p-values are optimistic. The enrichment ratios are the robust result.

## Result

| Unit | In box | Expected by chance | Enrichment | P(at least this many) |
|---|---|---|---|---|
| Records (all 400) | 168 (42.0%) | 19.2 (4.8%) | 8.8× | 1.7 × 10⁻¹¹⁰ |
| Distinct places (342) | 133 (38.9%) | 16.4 (4.8%) | 8.1× | 1.0 × 10⁻⁸² |
| 1° tiles with a candidate (229) | 51 (22.3%) | 9.5 (4.1%) | 5.4× | 7.0 × 10⁻²³ |

By reference (records in the box, out of 50 each; about 2.4 expected by chance):

| Reference | In box |
|---|---|
| Moon: Connecting Ridge (M-CR) | 25 |
| Moon: de Gerlache rim (M-DG) | 28 |
| Moon: Malapert massif (M-MA) | 27 |
| Moon: Shackleton rim (M-SR) | 24 |
| Moon: flat-terrain zone (MZ-FLAT) | 24 |
| Moon: steep-terrain zone (MZ-STEEP) | 26 |
| Mars: Jezero (R-JZ) | 14 |
| Mars: InSight, flat plains (R-IS) | **0** |

## Reading

- The concentration is 5 to 9 times what the area searched would give by chance, at every level of counting.
- It is specific to rugged references. The flat InSight plains reference puts **none** of its 50 matches in the box. The method is not simply drawn to the Andes; it sends rugged lunar terrain there and flat Martian plains elsewhere.
- The Andes, including the Puna–Atacama region around the closest Moon match (Volcán Aracar, W1 = 0.80°), already host planetary analog work. Recovering that region without being told it is evidence the measure picks up planetary-relevant terrain.
- Caveat: masking removes vegetated land, so the remaining search area favours dry, bare terrain. The baseline already accounts for this, because it is computed on the masked area actually searched.
