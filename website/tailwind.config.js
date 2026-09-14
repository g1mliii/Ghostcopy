/** @type {import('tailwindcss').Config} */
//
// Tokens are lifted from the Flutter app (lib/ui/theme/colors.dart) so the site
// and the product cannot drift apart. The only additions are the `ink` ramp and
// the marketing type scale, neither of which the app needs.
module.exports = {
  content: ['./*.html'],
  theme: {
    extend: {
      colors: {
        // Surfaces - GhostColors.background / surface / surfaceLight
        bg: '#0F0F13',
        surface: '#19191F',
        elevated: '#23232B',

        // Hairlines. `line` is the quiet divider, `line-strong` the structural
        // one (GhostColors.border).
        line: '#23232B',
        'line-strong': '#32323C',

        // Accent - GhostColors.primary and its companions. Used about four
        // times a page; if it starts appearing more, something is wrong.
        accent: '#6670FF',
        'accent-hover': '#4752C4',
        'accent-soft': '#292D55',
        'accent-text': '#AEB4FF',
        'accent-border': '#555EA6',

        success: '#3BA55C',
        warning: '#FFB020',
        danger: '#EF5350',

        // The presence ramp. These carry meaning rather than just contrast:
        // headlines resolve along it from ink-0 to ink-4, and the download page
        // uses it to encode how ready a platform is. ink-3 and ink-4 are the
        // app's textSecondary and textPrimary; the two dim steps are new,
        // because the app never needs to render something as barely-there.
        'ink-0': '#2A2A33',
        'ink-1': '#55565F',
        'ink-2': '#8E9099',
        'ink-3': '#B9BBBE',
        'ink-4': '#F5F6FA',
      },
      fontFamily: {
        sans: ['Inter', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'sans-serif'],
        mono: ['JetBrains Mono', 'Menlo', 'Consolas', 'monospace'],
      },
      fontSize: {
        // Mono eyebrow labels: always uppercase, always tracked out.
        label: ['11px', { lineHeight: '1.4', letterSpacing: '0.16em' }],
      },
      letterSpacing: {
        display: '-0.05em',
        heading: '-0.04em',
      },
      maxWidth: {
        // Outer page column. Wide enough to feel full on a 16:9 monitor without
        // letting anything stretch to an unreadable line length - text blocks
        // cap themselves well below this.
        page: '1512px',
        prose: '640px',
        'prose-wide': '800px',
      },
      spacing: {
        gutter: '88px',
      },
    },
  },
  plugins: [],
};
