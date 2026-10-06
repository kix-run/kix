// Expressive Code settings. They live here rather than in astro.config.mjs
// because Starlight's <Code> component (used by Snippet.astro) needs them in
// a JSON-serialisable config file.
import { defineEcConfig } from '@astrojs/starlight/expressive-code';
import { pluginLineNumbers } from '@expressive-code/plugin-line-numbers';
import kixNight from './src/lib/kix-night.theme.json' with { type: 'json' };

// Code is a night panel in both light and dark mode, so one dark
// theme serves both and Starlight's light/dark switch is ignored.
export default defineEcConfig({
  themes: [kixNight],
  useStarlightUiThemeColors: false,
  useStarlightDarkModeSwitch: false,
  plugins: [pluginLineNumbers()],
  defaultProps: { showLineNumbers: true },
  styleOverrides: {
    borderRadius: '10px',
    borderColor: 'var(--kix-code-line)',
    codeBackground: 'var(--kix-code-bg)',
    codeForeground: 'var(--kix-on-night)',
    codeFontFamily: "'JetBrains Mono Variable', ui-monospace, monospace",
    codeFontSize: '13.5px',
    codeLineHeight: '1.6',
    codePaddingBlock: '14px',
    codePaddingInline: '18px',
    gutterBorderWidth: '0px',
    uiFontFamily: "'JetBrains Mono Variable', ui-monospace, monospace",
    uiFontSize: '12px',
    frames: {
      shadowColor: 'transparent',
      editorTabBarBackground: 'var(--kix-code-chrome)',
      editorTabBarBorderBottomColor: 'var(--kix-code-line)',
      editorActiveTabBackground: 'var(--kix-code-chrome)',
      editorActiveTabForeground: 'var(--kix-on-night)',
      editorActiveTabIndicatorTopColor: 'transparent',
      editorActiveTabIndicatorBottomColor: '#F2542D',
      editorActiveTabIndicatorHeight: '2px',
      editorActiveTabBorderColor: 'transparent',
      editorBackground: 'var(--kix-code-bg)',
      terminalBackground: 'var(--kix-code-bg)',
      terminalTitlebarBackground: 'var(--kix-code-chrome)',
      terminalTitlebarForeground: 'var(--kix-on-night-2)',
      terminalTitlebarBorderBottomColor: 'var(--kix-code-line)',
      terminalTitlebarDotsOpacity: '0',
      inlineButtonForeground: 'var(--kix-on-night-2)',
      inlineButtonBorder: 'var(--kix-code-line)',
      tooltipSuccessBackground: '#F2542D',
      tooltipSuccessForeground: '#15171C',
    },
    textMarkers: {
      markBackground: '#F2542D1A',
      markBorderColor: '#F2542D',
      insBackground: '#8BD49A1A',
      insBorderColor: '#8BD49A',
      delBackground: '#FF7A6B1A',
      delBorderColor: '#FF7A6B',
    },
    lineNumbers: {
      foreground: '#3E434C',
      highlightForeground: '#80858F',
    },
  },
});
