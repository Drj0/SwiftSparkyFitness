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
out, implausible = [], []
for r in rows[1:]:
    kcal = r[col["unit_serving_energy_kcal"]]
    if not kcal:
        continue
    unit = (r[col["servings_unit"]] or "").strip() or "serving"
    if kcal > (MAX_KCAL_PORTION if unit.lower() in PORTION_UNITS else MAX_KCAL_PIECE):
        implausible.append(f"{round(kcal)} kcal / 1 {unit}: {r[col['food_name']]}")
        continue
    out.append({
        "id": r[col["food_code"]],
        "name": " ".join(r[col["food_name"]].split()),
        "unit": unit,
        "kcal": r1(kcal),
        "protein": r1(r[col["unit_serving_protein_g"]]),
        "carbs": r1(r[col["unit_serving_carb_g"]]),
        "fat": r1(r[col["unit_serving_fat_g"]]),
    })
json.dump(out, open("SwiftSparkyFitness/Resources/indb.json", "w"), ensure_ascii=False, separators=(",", ":"))
print(len(out), "foods;", len(implausible), "dropped as implausible per unit")
