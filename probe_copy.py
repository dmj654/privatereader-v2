import base64
import hashlib
import hmac
import json
import random
import string
import time

import requests

BASE = "https://api.copy2000.online"
SECRET = "M2FmMDg1OTAzMTEwMzJlZmUwNjYwNTUwYTA1NjNhNTM="
UA = "COPY/3.0.6"


def headers():
    ts = str(int(time.time()))
    sig = hmac.new(base64.b64decode(SECRET), ts.encode(), hashlib.sha256).hexdigest()
    now = time.gmtime()
    return {
        "User-Agent": UA,
        "source": "copyApp",
        "deviceinfo": "".join(random.choices(string.ascii_lowercase + string.digits, k=20)),
        "dt": time.strftime("%Y.%m.%d", now),
        "platform": "3",
        "referer": "com.copymanga.app-3.0.6",
        "version": "3.0.6",
        "device": "phone",
        "pseudoid": "".join(random.choices(string.ascii_lowercase + string.digits, k=16)),
        "Accept": "application/json",
        "region": "0",
        "authorization": "Token ",
        "umstring": "b4c89ca4104ea9a97750314d791520ac",
        "x-auth-timestamp": ts,
        "x-auth-signature": sig,
    }


r = requests.get(
    f"{BASE}/api/v3/search/comic",
    params={"limit": 30, "offset": 0, "q": "海贼", "q_type": ""},
    headers=headers(),
    timeout=20,
)
print("search", r.status_code)
data = r.json()
print(json.dumps(data, ensure_ascii=False)[:400])
first = data["results"]["list"][0]
print("first", first.get("name"), first.get("path_word"), first.get("uuid"))

comic_id = first["path_word"]
r = requests.get(
    f"{BASE}/api/v3/comic2/{comic_id}",
    params={"in_mainland": "true", "platform": "3"},
    headers=headers(),
    timeout=20,
)
print("detail", r.status_code)
d = r.json()["results"]
print("groups:", json.dumps(d.get("groups"), ensure_ascii=False)[:800])
print("comic keys:", list(d.get("comic", {}).keys()))
print("group keys:", list((d.get("groups") or {}).keys()))
for g, v in (d.get("groups") or {}).items():
    print("group", g, v)
    path = v.get("path_word")
    rr = requests.get(
        f"{BASE}/api/v3/comic/{comic_id}/group/{path}/chapters",
        params={"limit": 100, "offset": 0, "in_mainland": "true", "request_id": ""},
        headers=headers(),
        timeout=20,
    )
    print("chapters", rr.status_code, json.dumps(rr.json(), ensure_ascii=False)[:500])
    break
