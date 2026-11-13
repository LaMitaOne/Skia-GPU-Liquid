# Skia-GPU-Liquid
  Real-time 2D compute shader GPU liquid & particle simulation rendered directly
  inside an FMX Skia4Delphi control (TSkiaCustomThreadedBase derivative).
    
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/Skia-GPU-Liquid)    
     
  <img width="799" height="628" alt="Unbenannt" src="https://github.com/user-attachments/assets/e5feb6b1-aa75-40b7-a357-5c6eab5f9233" />
     
After building Yutani GPU Particles, I wondered if I could pull off the exact same OpenGL 4.3 compute shader trick inside Skia4Delphi—and well, turns out you can push a million liquid particles right onto a 2D Skia canvas.     
       
  Instead of drawing particles via CPU canvas calls or traditional vertex
  pipelines, this component spins up a dedicated offscreen OpenGL 4.3 Core
  context inside the background render thread. Two compute shaders run per
  frame:     
       
    1. Trail-Fade Pass: Decays the previous RGBA8 image buffer via imageLoad /
       imageStore to produce smooth, glowing ink-like fluid trails.     
    2. Particle Simulation Pass: Evolves 1,000,000+ particles stored in an
       SSBO using 2D Curl-Noise turbulence and interactive mouse forces,
       writing velocity-mapped colors directly into the output image2D.     

  The resulting frame is wrapped zero-overhead via TSkImage.MakeFromRaster
  and composited onto the Skia canvas with crisp vector HUD overlays.     
     
  Key Features:     
    - 1M+ particles simulated at 60 FPS on ryzen4500u     
    - Dedicated offscreen OpenGL 4.3 context running asynchronously in a TThread          
    - Zero external dependencies (pure Windows OpenGL32 + Skia4Delphi)     
    - 2D Curl-Noise fluid field + PCG uint hashing (no float precision artifacts)     
    - Interactive mouse vortex & repulsion (Left-Drag = push/swirl, Right-Drag = black hole)     
    - Automatic half-resolution simulation scaling for smooth fullscreen playback     
    - Accurate GPU compute-thread RealFPS measurement     

Sample project and zipped exe included     

includes     
https://github.com/LaMitaOne/SkiaCustomThreadedBase    
