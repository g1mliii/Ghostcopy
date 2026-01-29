/** @type {import('tailwindcss').Config} */
module.exports = {
  darkMode: 'class',
  content: [
    './**/*.html',
  ],
  theme: {
    extend: {
      colors: {
        // Primary colors used across pages
        'primary': '#ff8c00',
        'primary-dark': '#b54e35',
        'primary-burnt': '#e77255',

        // Gold/Weathered tones (index.html)
        'gold-weathered': '#e6c288',
        'sand-dark': '#1a120f',
        'sand-medium': '#462c25',
        'bronze': '#8c6b5d',
        'slate-deep': '#0c0c0e',

        // Download/other pages colors
        'stone-dark': '#211f1e',
        'stone-heavy': '#151413',
        'stone-light': '#2d2a28',
        'gold-light': '#C5A059',
        'gold-dark': '#9A7B4F',

        // Docs page colors
        'background-light': '#f8f6f6',
        'background-dark': '#211411',
        'sidebar-bg': '#1a2332',
        'parchment': '#fdfbf7',
        'parchment-dark': '#eaddcf',
        'sienna': '#8a3324',
        'sienna-light': '#c69f95',
      },
      fontFamily: {
        'display': ['Cinzel', 'Noto Serif', 'serif'],
        'serif': ['Noto Serif', 'serif'],
        'sans': ['Noto Sans', 'sans-serif'],
        'heading': ['Cinzel', 'serif'],
        'mono': ['JetBrains Mono', 'monospace'],
      },
      backgroundImage: {
        'film-grain': "url('data:image/svg+xml,%3Csvg viewBox=%220 0 200 200%22 xmlns=%22http://www.w3.org/2000/svg%22%3E%3Cfilter id=%22noise%22%3E%3CfeTurbulence type=%22fractalNoise%22 baseFrequency=%220.65%22 numOctaves=%223%22 stitchTiles=%22stitch%22/%3E%3C/filter%3E%3Crect width=%22100%25%22 height=%22100%25%22 filter=%22url(%23noise)%22 opacity=%220.08%22/%3E%3C/svg%3E')",
        'parchment-texture': "url('data:image/svg+xml,%3Csvg width=%27100%25%27 height=%27100%25%27 viewBox=%270 0 100 100%27 xmlns=%27http://www.w3.org/2000/svg%27%3E%3Cfilter id=%27noiseFilter%27%3E%3CfeTurbulence type=%27fractalNoise%27 baseFrequency=%270.8%27 numOctaves=%273%27 stitchTiles=%27stitch%27/%3E%3C/filter%3E%3Crect width=%27100%25%27 height=%27100%25%27 filter=%27url(%23noiseFilter)%27 opacity=%270.05%27/%3E%3C/svg%3E')",
        'weathered-gold': 'linear-gradient(180deg, #b08d55 0%, #8a6d45 100%)',
        'weathered-gold-hover': 'linear-gradient(180deg, #c5a059 0%, #9a7b4f 100%)',
        'heat-haze': 'linear-gradient(to top, rgba(231, 114, 85, 0.05), transparent 40%)',
      },
      animation: {
        'heat-haze': 'heatHaze 8s infinite linear',
      },
      keyframes: {
        heatHaze: {
          '0%': { transform: 'translateY(0) skewX(0)' },
          '25%': { transform: 'translateY(-2px) skewX(1deg)' },
          '50%': { transform: 'translateY(-4px) skewX(-1deg)' },
          '75%': { transform: 'translateY(-2px) skewX(0.5deg)' },
          '100%': { transform: 'translateY(0) skewX(0)' },
        },
      },
      boxShadow: {
        'glow': '0 0 20px rgba(231, 114, 85, 0.1)',
        'stone': '0 10px 15px -3px rgba(0, 0, 0, 0.5), 0 4px 6px -2px rgba(0, 0, 0, 0.3)',
        'decree': 'inset 0 0 40px rgba(0,0,0,0.8), 0 0 0 1px rgba(255,255,255,0.05)',
      },
      borderRadius: {
        'DEFAULT': '0.125rem',
        'lg': '0.25rem',
        'xl': '0.5rem',
        'full': '0.75rem',
      }
    },
  },
  plugins: [],
}
