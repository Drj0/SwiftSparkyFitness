#!/usr/bin/env python3
"""USDA FNDDS survey foods -> SwiftSparkyFitness/Resources/fndds.json.

Source: https://fdc.nal.usda.gov/download-datasets (FoodData Central, "Survey
(FNDDS)" JSON, FoodData_Central_survey_food_json_2024-10-31.zip). Public
domain (CC0) — USDA asks that FoodData Central be credited as the source.
Usage:  python3 tools/fndds_to_json.py surveyDownload.json

FNDDS is what people in the US survey actually eat, with household portions
("1 medium or regular slice: 28 g", "1 banana: 126 g") — the everyday basics
INDB (cooked Indian recipes only) doesn't have: bread, fruit, milk, eggs,
chicken breast, burgers. Bundled so they're found offline in both modes; on
this phone the USDA API isn't reachable at all (it needs a per-account key).

Each food keeps ONE household portion, like INDB rows: a "1 <something>"
portion near FNDDS's own typical amount ("Quantity not specified"), a
countable one (an egg, a slice) before a cup, with values for that portion.
Where no portion is near it (a "cup" of paneer is twice the usual amount),
the food is in grams, starting at the typical amount ("size").

Dropped: baby food and formula, "as ingredient in" rows (parts of a recipe,
not a food), dry mixes "not reconstituted", and the US versions of Indian
dishes INDB already has (its recipes are the Indian ones).
"""
import json, re, sys

EXCLUDED_CATEGORIES = ("Baby ", "Formula", "Human milk")
# INDB has these dishes; FNDDS's are US recipes of them.
INDB_HAS = {
    "Dal", "Lentil curry", "Lentil curry with rice", "Chicken curry", "Chicken curry with rice",
    "Fish curry", "Fish curry with rice", "Beef curry", "Beef curry with rice", "Biryani with meat",
    "Biryani with chicken", "Biryani with vegetables", "Idli", "Dosa, plain", "Dosa, with filling",
    "Bread, chappatti or roti", "Bread, paratha", "Bread, naan", "Palak Paneer", "Pakora",
    "Vegetable curry", "Vegetable curry with rice", "Chutney", "Samosa", "Curry sauce",
}
SKIP_PORTION = re.compile(
    r"quantity not specified|guideline|\boz\b|cubic inch|linear inch|surface inch|school|yield|package|"
    r"packet|\bpot\b|crust not eaten|snack-size|container|\bcan\b|bottle|\bjar\b|\bbox\b|\bbag\b|\blb\b|"
    r"\bdrop\b|\bdash\b|\bpinch\b|sharing|movie|\bany\b|calorie",
    re.I)
VOLUME = {"cup", "tablespoon", "teaspoon"}
SIZE_WORDS = {"small", "medium", "large", "extra", "regular", "thick", "thin", "whole", "half", "miniature",
              "slider", "jumbo", "mini", "item", "serving", "individual", "size", "or", "very", "standard",
              "single"}
SHORT = {"tablespoon": "tbsp", "teaspoon": "tsp"}
MEATS = {"beef", "pork", "lamb", "veal", "goat", "chicken", "turkey", "fish", "ham", "meat"}
ENERGY, PROTEIN, CARBS, FAT = 1008, 1003, 1005, 1004


def head_noun(description):
    """'Corned beef sandwich on white' -> sandwich; 'Apple, raw' -> apple."""
    first = description.split(",")[0].lower()
    first = re.split(r" (?:on|with|in|and|or|from) ", first)[0]
    noun = first.split()[-1]
    return noun[:-1] if noun.endswith("s") and not noun.endswith("ss") and len(noun) > 3 else noun


def unit_label(description, portion):
    """'1 medium or regular slice' -> slice; '1 medium' (Apple, raw) ->
    medium apple; '1 cup (8 fl oz)' -> cup; '1 tablespoon' -> tbsp;
    '1 egg white' -> egg white; '1 pouch/regular size' -> pouch."""
    text = re.sub(r"^1\s+", "", portion)
    text = re.sub(r"\s*\(.*?\)", "", text).split(",")[0].strip().lower()
    text = re.split(r" (?:with|of) ", text)[0]
    alternatives = [alt.split() for alt in text.split("/")]
    words = next((alt for alt in alternatives if any(w not in SIZE_WORDS for w in alt)), alternatives[0])
    nouns = [w for w in words if w not in SIZE_WORDS]
    if not nouns:
        if "serving" in words:
            return "serving"
        head = head_noun(description)
        size = next((w for w in ("small", "medium", "large", "half", "whole") if w in words), "")
        if not size and head in MEATS:
            return "piece"  # "Beef, steak, NFS": a regular *piece*, not "1 beef"
        return f"{size} {head}".strip()
    if nouns[-1] in SHORT:
        return SHORT[nouns[-1]]
    noun = " ".join(nouns) if len(nouns) <= 2 else nouns[-1]
    size = next((w for w in ("small", "large", "half") if w in words and "or" not in words), "")
    return f"{size} {noun}".strip()


def pick_portion(food):
    """The household portion near FNDDS's typical amount, preferring a
    countable one (an egg, a slice) over a cup; None means use grams."""
    portions = food.get("foodPortions") or []
    typical = next((p["gramWeight"] for p in portions if p.get("portionDescription") == "Quantity not specified"), None)
    usable = [p for p in portions
              if p.get("gramWeight") and p.get("portionDescription", "").startswith("1 ")
              and not SKIP_PORTION.search(p["portionDescription"])]
    if typical:
        usable = [p for p in usable if 0.5 <= p["gramWeight"] / typical < 2]
    if not usable:
        return None
    def is_volume(p):
        return any(v in p["portionDescription"] for v in VOLUME)
    key = lambda p: (is_volume(p), abs(p["gramWeight"] - (typical or p["gramWeight"])), p.get("sequenceNumber", 99))
    return min(usable, key=key)


def main(path):
    foods = json.load(open(path))["SurveyFoods"]
    out, dropped = [], 0
    for food in foods:
        name = " ".join(food["description"].split())
        category = food.get("wweiaFoodCategory", {}).get("wweiaFoodCategoryDescription", "")
        if (category.startswith(EXCLUDED_CATEGORIES) or "as ingredient" in name or "not reconstituted" in name
                or name in INDB_HAS):
            dropped += 1
            continue
        n = {f["nutrient"]["id"]: f.get("amount") for f in food.get("foodNutrients", [])}
        kcal = n.get(ENERGY)
        if kcal is None:
            dropped += 1
            continue
        portion = pick_portion(food)
        if portion:
            grams, size, unit = portion["gramWeight"], 1, unit_label(name, portion["portionDescription"])
        else:
            typical = next((p["gramWeight"] for p in food.get("foodPortions") or []
                            if p.get("portionDescription") == "Quantity not specified"), 100)
            grams = size = round(typical)
            unit = "g"
        scale = grams / 100
        r1 = lambda v: round((v or 0) * scale, 1)
        out.append({
            "id": str(food["fdcId"]),
            "name": name,
            "unit": unit,
            **({"size": size} if size != 1 else {}),
            "kcal": r1(kcal),
            "protein": r1(n.get(PROTEIN)),
            "carbs": r1(n.get(CARBS)),
            "fat": r1(n.get(FAT)),
        })
    json.dump(out, open("SwiftSparkyFitness/Resources/fndds.json", "w"), ensure_ascii=False, separators=(",", ":"))
    print(len(out), "foods;", dropped, "dropped")


main(sys.argv[1])
