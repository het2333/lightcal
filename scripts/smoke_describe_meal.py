import base64
import json
import sys
import time
import urllib.request


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: smoke_describe_meal.py IMAGE_PATH [URL]")
        return 2
    image_path = sys.argv[1]
    url = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8001/v6/describeMeal"
    with open(image_path, "rb") as file:
        image_base64 = base64.b64encode(file.read()).decode()
    payload = json.dumps({"source": "image_scan", "image_base64": image_base64}).encode()
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            data = json.loads(response.read().decode())
    except Exception as exc:
        print(f"status=error elapsed={time.time() - started:.2f}s error={exc!r}")
        body_reader = getattr(exc, "read", None)
        if callable(body_reader):
            try:
                print(body_reader().decode()[:1000])
            except Exception:
                pass
        return 1

    foods = data.get("foods") or []
    print(
        "status=ok elapsed=%.2fs foods=%s desc=%s"
        % (time.time() - started, len(foods), str(data.get("description") or "")[:80])
    )
    for food in foods[:10]:
        print("-", food.get("name"), food.get("calories"), food.get("serving_size"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
