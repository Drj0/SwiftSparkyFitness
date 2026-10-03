#!/usr/bin/env python3
"""Anuvaad INDB spreadsheet -> SwiftSparkyFitness/Resources/indb.json.

Source: https://www.anuvaad.org.in/indian-nutrient-databank/ (Anuvaad_INDB_2024.11.xlsx)
Usage:  python3 tools/indb_to_json.py Anuvaad_INDB_2024.11.xlsx   (needs openpyxl)

Keeps per-household-unit values only ("1 chapati", "1 bowl"). INDB's per-100g
figures are computed on raw-ingredient weight with no cooking yield factor, so
grams of the *cooked* dish would be wrong. Rows without a per-unit value (82,
mostly infant premixes) are dropped.

INDB derives a unit as recipe total / (servings x units per serving). Where the
source recipe's serving count is wrong, every unit is several times too big
("1 poori 921 kcal", "1 plate paneer pulao 4876 kcal"). The true yield can't be
recovered, so rows past a plausible ceiling for their unit are dropped rather
than shown wrong. ponytail: a flat ceiling per unit kind; per-dish review (or
INDB fixing its serving counts) would rescue the dropped rows.

Rows whose macros can't make their energy (4 kcal/g protein and carbs, 9 fat)
are dropped too: 33 of them, mostly soups, are wrong in the source itself —
"Egg drop soup" is 85 kcal with 41 g protein and 43 g fat.

A few everyday dishes are replaced outright (OVERRIDES): INDB's recipe totals
keep all of the frying oil, so 1 samosa read 447 kcal with 42 g fat and 13 g
carbs, and a plain omelette 389 kcal. Their values come from USDA FNDDS
2021-2023 (fdcId noted), at the portion INDB names.
"""
import json, sys, openpyxl

rows = list(openpyxl.load_workbook(sys.argv[1], read_only=True).worksheets[0].iter_rows(values_only=True))
h = rows[0]
col = {name: h.index(name) for name in h}
r1 = lambda v: round(float(v or 0), 1)
# A whole serving vessel vs. a single piece or spoonful.
PORTION_UNITS = {"plate", "bowl", "soup bowl", "glass", "tall glass", "cup", "tea cup", "serving",
                 "dish", "shallow dish", "souffle dish", "katori", "large bowl", "mug"}
MAX_KCAL_PORTION, MAX_KCAL_PIECE = 900, 450
MAX_ATWATER_GAP = 0.25
# name -> (unit, kcal, protein, carbs, fat), per that one unit.
OVERRIDES = {
    "Vegetable samosa": ("samosa", 310, 5.1, 33.2, 17.5),       # 2708730 Samosa, 1 regular (100 g)
    "Plain omelette": ("omelette", 211.2, 12.8, 1.0, 17.4),     # 2707200 omelet made with oil, 2 eggs (110 g)
    "French omelette": ("egg", 105.6, 6.4, 0.5, 8.7),           # 2707200, 1 egg (55 g)
    "Puffy omelette": ("egg", 105.6, 6.4, 0.5, 8.7),            # 2707200, 1 egg (55 g)
    "Fried Egg": ("egg", 105.6, 6.4, 0.5, 8.7),                 # 2707158 egg fried with oil, 1 egg (55 g)
}
out, implausible, inconsistent = [], [], []
for r in rows[1:]:
    kcal = r[col["unit_serving_energy_kcal"]]
    if not kcal:
        continue
    unit = (r[col["servings_unit"]] or "").strip() or "serving"
    if kcal > (MAX_KCAL_PORTION if unit.lower() in PORTION_UNITS else MAX_KCAL_PIECE):
        implausible.append(f"{round(kcal)} kcal / 1 {unit}: {r[col['food_name']]}")
        continue
    # "Plain omelette/omlet" listed "Plain omlet" for "omlet"; the app's
    # synonyms already take every spelling to the omelettes.
    name = " ".join(r[col["food_name"]].split()).replace("omelette/omlet", "omelette")
    protein, carbs, fat = (r1(r[col[f"unit_serving_{k}_g"]]) for k in ("protein", "carb", "fat"))
    if name in OVERRIDES:
        unit, kcal, protein, carbs, fat = OVERRIDES.pop(name)
    elif abs(4 * protein + 4 * carbs + 9 * fat - kcal) > MAX_ATWATER_GAP * kcal:
        inconsistent.append(f"{round(kcal)} kcal, P{protein} C{carbs} F{fat}: {name}")
        continue
    out.append({
        "id": r[col["food_code"]],
        "name": name,
        "unit": unit,
        "kcal": r1(kcal),
        "protein": protein,
        "carbs": carbs,
        "fat": fat,
    })
assert not OVERRIDES, f"overrides matched no row: {list(OVERRIDES)}"
json.dump(out, open("SwiftSparkyFitness/Resources/indb.json", "w"), ensure_ascii=False, separators=(",", ":"))
print(len(out), "foods;", len(implausible), "dropped as implausible per unit;",
      len(inconsistent), "dropped as macros that can't make their energy")
