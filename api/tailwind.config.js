/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./web/**/*.html', './web/**/*.js'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', 'ui-sans-serif', 'system-ui', 'sans-serif'],
      },
    },
  },
  plugins: [],
};
