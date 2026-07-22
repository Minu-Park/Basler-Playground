/* ==========================================================================
   Basler Playground - Real WebP Image Binary Threshold Engine
   ========================================================================== */

document.addEventListener('DOMContentLoaded', () => {
  initHeroViewportCanvas();
  initInteractiveDemo();
  initArchitectureTabs();
  initScrollEffects();
});

/* --------------------------------------------------------------------------
   1. Live Industrial Camera Viewport (Hero Window Overlay)
   -------------------------------------------------------------------------- */
function initHeroViewportCanvas() {
  const canvas = document.getElementById('heroCanvas');
  const slider = document.getElementById('heroParamSlider');
  const input = document.getElementById('heroParamInput');
  const codeValText = document.getElementById('heroRangeValueText');

  if (!canvas) return;
  const ctx = canvas.getContext('2d');

  // Load the user's real vision WebP image
  const sampleImage = new Image();
  sampleImage.src = 'assets/sample_vision.webp';
  let imageLoaded = false;

  sampleImage.onload = () => {
    imageLoaded = true;
  };

  function resize() {
    canvas.width = canvas.parentElement.clientWidth || 680;
    canvas.height = canvas.parentElement.clientHeight || 450;
  }
  resize();
  window.addEventListener('resize', resize);

  let currentThreshold = 127;

  function updateThreshold(val) {
    currentThreshold = parseInt(val, 10);
    if (slider) slider.value = currentThreshold;
    if (input) input.value = currentThreshold;
    if (codeValText) codeValText.textContent = currentThreshold;
  }

  if (slider) slider.addEventListener('input', (e) => updateThreshold(e.target.value));
  if (input) input.addEventListener('change', (e) => updateThreshold(e.target.value));

  function render() {
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    if (imageLoaded) {
      const offCanvas = document.createElement('canvas');
      offCanvas.width = canvas.width;
      offCanvas.height = canvas.height;
      const offCtx = offCanvas.getContext('2d');

      // Draw the real vision webp image fitted to canvas
      offCtx.drawImage(sampleImage, 0, 0, canvas.width, canvas.height);

      // Extract pixel buffer
      const imgData = offCtx.getImageData(0, 0, canvas.width, canvas.height);
      const data = imgData.data;

      // Real-time threshold simulation
      for (let i = 0; i < data.length; i += 4) {
        const gray = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
        const val = gray >= currentThreshold ? 255 : 0;
        data[i] = val;
        data[i + 1] = val;
        data[i + 2] = val;
      }

      ctx.putImageData(imgData, 0, 0);
    }

    requestAnimationFrame(render);
  }

  render();
}

/* --------------------------------------------------------------------------
   2. Dedicated Interactive Parameter Showcase Demo Section
   -------------------------------------------------------------------------- */
function initInteractiveDemo() {
  const canvas = document.getElementById('demoCanvas');
  const slider = document.getElementById('demoInteractiveSlider');
  const codeValText = document.getElementById('demoParamValText');
  const badgeValText = document.getElementById('demoSliderBadge');
  const presetBtns = document.querySelectorAll('.preset-btn');

  if (!canvas || !slider) return;
  const ctx = canvas.getContext('2d');

  const sampleImage = new Image();
  sampleImage.src = 'assets/sample_vision.webp';
  let imageLoaded = false;

  sampleImage.onload = () => {
    imageLoaded = true;
  };

  function resize() {
    canvas.width = canvas.parentElement.clientWidth || 440;
    canvas.height = canvas.parentElement.clientHeight || 240;
  }
  resize();
  window.addEventListener('resize', resize);

  let demoThreshold = 127;

  function setDemoVal(val) {
    demoThreshold = parseInt(val, 10);
    slider.value = demoThreshold;
    if (codeValText) codeValText.textContent = demoThreshold;
    if (badgeValText) badgeValText.textContent = `Value: ${demoThreshold}`;

    presetBtns.forEach(btn => {
      if (parseInt(btn.getAttribute('data-val'), 10) === demoThreshold) {
        btn.classList.add('active');
      } else {
        btn.classList.remove('active');
      }
    });
  }

  slider.addEventListener('input', (e) => setDemoVal(e.target.value));

  presetBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      setDemoVal(btn.getAttribute('data-val'));
    });
  });

  function renderDemo() {
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    if (imageLoaded) {
      const offCanvas = document.createElement('canvas');
      offCanvas.width = canvas.width;
      offCanvas.height = canvas.height;
      const offCtx = offCanvas.getContext('2d');

      offCtx.drawImage(sampleImage, 0, 0, canvas.width, canvas.height);

      const imgData = offCtx.getImageData(0, 0, canvas.width, canvas.height);
      const data = imgData.data;

      for (let i = 0; i < data.length; i += 4) {
        const gray = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
        const val = gray >= demoThreshold ? 255 : 0;
        data[i] = val;
        data[i + 1] = val;
        data[i + 2] = val;
      }

      ctx.putImageData(imgData, 0, 0);
    }

    requestAnimationFrame(renderDemo);
  }

  renderDemo();
}

/* --------------------------------------------------------------------------
   3. Submodule Ecosystem (Basler Korea Inc. Open Source)
   -------------------------------------------------------------------------- */
const moduleData = {
  camera: {
    title: 'BaslerKR / Camera',
    role: 'Basler Korea Inc. — 2D & 3D Camera Module',
    repo: 'https://github.com/BaslerKR/Camera',
    repoText: 'github.com/BaslerKR/Camera ↗',
    desc: 'Hardware driver & acquisition interface for Basler 2D and 3D vision cameras. Maintained by Basler Korea Inc.'
  },
  framegrabber: {
    title: 'BaslerKR / Framegrabber',
    role: 'Basler Korea Inc. — CoaXPress Framegrabber Module',
    repo: 'https://github.com/BaslerKR/Framegrabber',
    repoText: 'github.com/BaslerKR/Framegrabber ↗',
    desc: 'High-throughput hardware interface for Basler CoaXPress framegrabbers. Maintained by Basler Korea Inc.'
  },
  gocator: {
    title: 'BaslerKR / Gocator',
    role: 'Basler Korea Inc. — LMI GoPxL 3D Sensor Module',
    repo: 'https://github.com/BaslerKR/Gocator',
    repoText: 'github.com/BaslerKR/Gocator ↗',
    desc: '3D sensor integration module for LMI Gocator devices running on GoPxL SDK. Maintained by Basler Korea Inc.'
  }
};

function initArchitectureTabs() {
  const buttons = document.querySelectorAll('.module-nav-btn');
  const titleEl = document.getElementById('modTitle');
  const roleEl = document.getElementById('modRole');
  const repoLinkEl = document.getElementById('modRepoLink');
  const descEl = document.getElementById('modDesc');

  if (!buttons.length || !titleEl) return;

  buttons.forEach(btn => {
    btn.addEventListener('click', () => {
      const key = btn.getAttribute('data-module');
      const data = moduleData[key];
      if (!data) return;

      buttons.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');

      titleEl.textContent = data.title;
      roleEl.textContent = data.role;
      if (repoLinkEl) {
        repoLinkEl.href = data.repo;
        repoLinkEl.textContent = data.repoText;
      }
      descEl.textContent = data.desc;
    });
  });
}

/* --------------------------------------------------------------------------
   4. Intersection Animations
   -------------------------------------------------------------------------- */
function initScrollEffects() {
  const observerOptions = {
    threshold: 0.1
  };

  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.style.opacity = '1';
        entry.target.style.transform = 'translateY(0)';
      }
    });
  }, observerOptions);

  document.querySelectorAll('.feature-card, .architecture-container, .interactive-demo-container').forEach(el => {
    el.style.opacity = '0';
    el.style.transform = 'translateY(20px)';
    el.style.transition = 'opacity 0.6s ease-out, transform 0.6s ease-out';
    observer.observe(el);
  });
}
