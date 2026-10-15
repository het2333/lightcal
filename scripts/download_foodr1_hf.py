from pathlib import Path
import time

from huggingface_hub import snapshot_download


out = Path("/root/autodl-tmp/modelscope-cache-ms/zy12123/Food-R1")
out.mkdir(parents=True, exist_ok=True)

print(f"start {time.strftime('%F %T')} -> {out}", flush=True)
path = snapshot_download(
    repo_id="zy12123/Food-R1",
    local_dir=str(out),
    resume_download=True,
    max_workers=4,
)
print(f"done {time.strftime('%F %T')} {path}", flush=True)
