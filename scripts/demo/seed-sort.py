import json, os, uuid
d = os.path.expanduser("~/Documents")
def win(bundle, title): return {"id": str(uuid.uuid4()).upper(), "fingerprint": {"bundleID": bundle, "title": title, "index": 0}}
def doc(path, app): return {"folder": {"_0": f"file://{d}/{path}", "app": app}}
items = [
  {"id": str(uuid.uuid4()).upper(), "name": "Thesis", "state": {"released": {}},
   "windows": [win("com.apple.TextEdit", "thesis-draft.rtf"), win("com.apple.TextEdit", "outline.rtf"),
               win("com.apple.Preview", "figure-1.png"), win("com.apple.Dictionary", "Dictionary")],
   "payloads": [doc("Thesis/thesis-draft.rtf", "com.apple.TextEdit"), doc("Thesis/outline.rtf", "com.apple.TextEdit"), doc("Thesis/figure-1.png", "com.apple.Preview")]},
  {"id": str(uuid.uuid4()).upper(), "name": "Trip planning", "state": {"released": {}},
   "windows": [win("com.apple.Safari", "Trip itinerary"), win("com.apple.iCal", "Calendar"), win("com.apple.calculator", "Calculator")],
   "payloads": []},
]
p = os.path.expanduser("~/Library/Application Support/Stacky")
os.makedirs(p, exist_ok=True)
json.dump(items, open(p + "/items.json", "w"))
