# Skia-GPU-Liquid v0.2

Real-time 2D compute shader GPU liquid & particle simulation rendered directly
inside an FMX Skia4Delphi control (TSkiaCustomThreadedBase derivative).

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/Skia-GPU-Liquid)

https://github.com/user-attachments/assets/42b0b8cb-2e8a-43d0-ac6e-8cec31928021
     
<img width="802" height="633" alt="1" src="https://github.com/user-attachments/assets/a146d1e8-ccb4-483e-9f18-0dd7e4620baf" />
       
https://youtu.be/Gqev1AHYT6Y

After building Yutani GPU Particles, I wondered if I could pull off the exact same
OpenGL 4.3 compute shader trick inside Skia4Delphi — and well, turns out you can
push a billion liquid particles right onto a 2D Skia canvas.

Instead of drawing particles via CPU canvas calls or traditional vertex pipelines,
this component spins up a dedicated offscreen OpenGL 4.3 Core context inside the
background render thread. Three compute shaders run per frame:

1. **Trail-Fade Pass** — Decays the previous RGBA8 image buffer via `imageLoad` /
   `imageStore` to produce smooth, glowing ink-like fluid trails.
2. **Curl-Field Precompute Pass** — Writes the per-frame 2D flow vector field into
   a 256×256 RG16F texture so the particle shader can sample it via `texture()`
   with hardware bilinear filtering, instead of evaluating `sin()`/`cos()` per
   particle.
3. **Particle Simulation Pass** — Evolves up to 1,000,000,000 particles stored in
   a half-float packed SSBO using 2D Curl-Noise turbulence and interactive mouse
   forces, writing velocity-mapped colors directly into the output `image2D`.

The resulting frame is wrapped zero-overhead via `TSkImage.MakeFromRaster` and
composited onto the Skia canvas with crisp vector HUD overlays.

## Performance

| Particles | Ryzen 4500U iGPU | RTX 2060 Super 8 GB |
|-----------|------------------|---------------------|
| 7M        | 60 FPS           | 60 FPS              |
| 125M      | —                | 60 FPS              |
| 1B        | 1 FPS            | 8 FPS               |

1 billion particles on a 8 FPS floor — without crashing, without a bluescreen,
without VRAM allocation failure. The APU's shared-memory architecture (system
RAM acting as VRAM) is what makes the 1B run on the Ryzen survive at all.

## Key Features

- **Up to 1,000,000,000 particles** in a single SSBO (7M @ 60 FPS on Ryzen 4500U
  iGPU, 1250M @ 60 FPS on RTX 2060 Super, 1B @ 8 FPS on RTX 2060 Super)
- Dedicated offscreen OpenGL 4.3 context running asynchronously in a `TThread`
- Three compute passes per frame: trail-fade, curl-field precompute, particle sim
- Half-float packed SSBO (`uvec2` = 8 bytes/particle) — 1B particles fit in 8 GB VRAM
- 2D workgroup dispatch — bypasses the 67M `GL_MAX_COMPUTE_WORK_GROUP_COUNT` ceiling
- Zero-CPU GPU-side seeding via `glClearBufferData` + lazy `pcgHash` initialization
- Async PBO ping-pong readback — `glGetTexImage` DMA overlaps with next frame's compute
- 2D Curl-Noise fluid field precomputed into an RG16F texture + PCG uint hashing
  (no float precision artifacts)
- Interactive mouse vortex & repulsion (Left-Drag = push/swirl, Right-Drag = black hole)
- Automatic half-resolution simulation scaling for smooth fullscreen playback
- Accurate GPU compute-thread RealFPS measurement
- Zero external dependencies (pure Windows `opengl32.dll` + Skia4Delphi)

## Requirements

- Delphi 12+ (or any version with FMX + Skia4Delphi support)
- **Win64 target** — required because the SSBO size exceeds 2 GB at 250M+ particles
  and `NativeInt` is 32-bit on Win32, which overflows the `glBufferData` size argument
- OpenGL 4.3+ capable GPU (any discrete NVIDIA/AMD since ~2012, Intel Skylake iGPU or newer)

## Sample project and zipped exe included

Includes
https://github.com/LaMitaOne/SkiaCustomThreadedBase

1B at rtx2060s:      
<img width="802" height="629" alt="2" src="https://github.com/user-attachments/assets/69d29fa1-3089-489e-9130-0a02416b1c99" />
