# 3D models for monuments

`build_models.py` turns one Commons photo of each monument into a USDZ with
[TripoSR](https://github.com/VAST-AI-Research/TripoSR) (MIT). It needs an NVIDIA GPU with 8 GB or more.

One-time setup (PowerShell). TripoSR's `torchmcubes` is swapped for PyMCubes in
`tsr/models/isosurface.py`, so nothing has to be compiled:

```powershell
git clone https://github.com/VAST-AI-Research/TripoSR.git D:\daldal-tools\TripoSR
cd D:\daldal-tools\TripoSR
C:\Users\MK\Python311\python.exe -m venv --system-site-packages .venv
.\.venv\Scripts\python.exe -m pip install omegaconf==2.3.0 einops==0.7.0 transformers==4.35.0 "trimesh>=4.5" fast-simplification rembg huggingface-hub xatlas==0.0.9 moderngl==5.10.0 PyMCubes usd-core
```

Build (the first run downloads the TripoSR weights, about 1.7 GB):

```powershell
D:\daldal-tools\TripoSR\.venv\Scripts\python.exe -X utf8 scripts\models\build_models.py out\models
```

Check `out/models/review/*-render.png` and list bad results in `SKIP_IDS` before publishing.
