# 2026-09-20 · The shared button export fails the web lint check.

`npm run lint` reports `react-refresh/only-export-components` at
`web/src/components/ui/button.tsx:67` because the file exports a non-component.
The file was unchanged during the homepage copy update. The production build
and lint checks for the edited landing-page components pass.
