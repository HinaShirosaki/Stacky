import json, os, uuid
d = os.path.expanduser("~/Documents/Thesis")
def win(bundle, title): return {"id": str(uuid.uuid4()).upper(), "fingerprint": {"bundleID": bundle, "title": title, "index": 0}}
def doc(name, app): return {"folder": {"_0": f"file://{d}/{name}", "app": app}}
items = [
  {"id": str(uuid.uuid4()).upper(), "name": "Thesis", "state": {"released": {}},
   "windows": [win("com.apple.Safari", "Reading list"), win("com.apple.Preview", "figure-1.png"), win("com.apple.TextEdit", "thesis-draft.rtf")],
   "payloads": [doc("thesis-draft.rtf", "com.apple.TextEdit"), doc("figure-1.png", "com.apple.Preview")]},
  {"id": str(uuid.uuid4()).upper(), "name": "Trip planning", "state": {"released": {}},
   "windows": [win("com.apple.Maps", "Maps"), win("com.apple.Notes", "Packing list")], "payloads": []},
]
p = os.path.expanduser("~/Library/Application Support/Stacky")
os.makedirs(p, exist_ok=True)
json.dump(items, open(p + "/items.json", "w"))
